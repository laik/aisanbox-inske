#!/usr/bin/env bash
# Phase 1e —— OPA Gatekeeper 准入控制 (POC2 §3.5)
# 手工重现: bash poc/phases/05-gatekeeper.sh
#
# POC-06 要证明两件事:
#   (1) 不安全的 Kubernetes 资源**根本进不来**（不是进来之后再被 kill）；
#   (2) 规则只针对租户身份精确生效 —— OpenShell / 平台的 controller 仍要能管理自己的
#       资源，不能因为图省事把整个 Runtime Namespace 豁免掉。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
GK_VERSION=${GK_VERSION:-3.23.1}
GRP_A=tenant-a-owners
NS=tenant-a-runtime

helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts >/dev/null 2>&1 || true
kubectl --context $CTX create ns gatekeeper-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# -f gatekeeper/values.yaml: chart 默认 3 副本 × 512Mi = 2GiB，在 7GiB 的机器上会把
# kube-apiserver 压到丢 leader election(实测 Capsule 控制器随之 CrashLoopBackOff)。
helm --kube-context $CTX upgrade --install gatekeeper gatekeeper/gatekeeper --version $GK_VERSION \
  -n gatekeeper-system -f gatekeeper/values.yaml --wait --timeout 6m

echo "### 安装自检"
kubectl --context $CTX get pods -n gatekeeper-system --no-headers \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName | sed 's/^/   /'

kubectl --context $CTX apply -f gatekeeper/constraints.yaml
# 坑(实测): ConstraintTemplate 会**动态生成**它的 CRD(k8spocruntime.constraints.gatekeeper.sh)。
# 紧接着 apply 约束实例会报 "no matches for kind K8sPocRuntime"。必须等 CRD Established。
kubectl --context $CTX wait --for condition=established --timeout=180s \
  crd/k8spocruntime.constraints.gatekeeper.sh \
  crd/k8spocmanagedresources.constraints.gatekeeper.sh
kubectl --context $CTX apply -f gatekeeper/constraints.yaml

# 约束要被 controller 加载才生效；没加载时规则会**静默放行**，比报错更危险。
for i in $(seq 1 60); do
  ok=$(kubectl --context $CTX get k8spocruntime poc-tenant-pod-boundary -o 'jsonpath={.status.byPod[*].enforced}' 2>/dev/null)
  echo "$ok" | grep -q true && break
  sleep 2
done
echo "   约束加载状态:"
kubectl --context $CTX get k8spocruntime,k8spocmanagedresources --no-headers \
  -o 'jsonpath={range .items[*]}{.kind}{"/"}{.metadata.name}{"  enforcement="}{.spec.enforcementAction}{"  enforced="}{.status.byPod[*].enforced}{"\n"}{end}' \
  | sed 's/^/   /'

# ---------------------------------------------------------------------------
# 断言函数: 必须**指名**是哪条约束拒的。
# 踩过的坑: 只看 "Forbidden/admission" 会把 Kubernetes 自身的错误(比如
# "serviceaccount not found")当成约束生效 —— 那是假阳性。
GK_TAG() { grep -oE '\[poc-[a-z0-9-]+\]' | head -1; }
gk_deny() { # gk_deny <描述> <期望的约束名> <命令...>
  local label=$1 want=$2; shift 2
  local out tag; out=$("$@" 2>&1); tag=$(GK_TAG <<<"$out")
  if [ "$tag" = "[$want]" ]; then
    printf '   ✓ %-44s 被 %s 拒绝\n' "$label" "$tag"
    grep -oE 'denied the request: .*' <<<"$out" | head -1 | cut -c1-150 | sed 's/^/       /'
  elif [ -n "$tag" ]; then
    printf '   ✗ %-44s 被 %s 拒绝，期望 %s\n' "$label" "$tag" "[$want]"
  else
    printf '   ✗ %-44s 没有被任何约束拒绝 <== 规则没生效或作用域不对\n' "$label"
    echo "$out" | head -2 | cut -c1-150 | sed 's/^/       /'
  fi
}
gk_allow() { # gk_allow <描述> <命令...>
  local label=$1; shift
  local out tag; out=$("$@" 2>&1); tag=$(GK_TAG <<<"$out")
  if [ -n "$tag" ]; then
    printf '   ✗ %-44s 被 %s 拒绝 <== 误伤\n' "$label" "$tag"
    echo "$out" | head -1 | cut -c1-150 | sed 's/^/       /'
  else
    printf '   ✓ %-44s 未被约束拦截\n' "$label"
  fi
}
# --dry-run=server: 走完整 admission 链(webhook 真的执行)，但不落盘。
mkpod() { kubectl --context $CTX -n "$2" run "$1" --image=alpine:latest "${3:-}" \
  --dry-run=server -o name --overrides="$4"; }
asalice=(--as=alice --as-group=$GRP_A)
# 平台身份要在租户 ns 里能建 Pod，否则决定结果的是 RBAC 而不是 Gatekeeper。
# 真实部署里这件事由 openshell-workspace chart 的 Role/RoleBinding 做(Phase 3 会装真的)。
# 坑: SA 在 **gateway** 的 ns 里，Role/RoleBinding 在**租户 runtime** ns 里，
#      RoleBinding 的 subject.namespace 必须写 SA 自己的 ns —— 写成本地 ns 会静默绑不上，
#      然后你会看到 RBAC 先拒，误以为是 Gatekeeper 的功劳。
# 关键: 这里用的 SA 名必须是**约束 allowedIdentities 里那个真实名字** os-a-openshell
# (helm release 前缀 + chart 里的 SA 名)。上一轮测试用的是占位名 openshell，
# 于是"平台身份应被放行"这一组被自己的约束拒了 —— 那是测试写错，不是规则写错。
# 真实约束的锚点是 **namespace 限定的 SA 名**(见 constraints.yaml 的说明)，
# 因为 Kubernetes 不给 SA 自定义组。所以这里连 --as-group 也用真实的三个组。
kubectl --context $CTX apply -f - >/dev/null <<'Y'
apiVersion: v1
kind: ServiceAccount
metadata: {name: os-a-openshell, namespace: tenant-a-gateway}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: poc2-platform-pod-writer, namespace: tenant-a-runtime}
rules: [{apiGroups: [""], resources: ["pods"], verbs: ["create","get","list","delete"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: poc2-platform-pod-writer, namespace: tenant-a-runtime}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: poc2-platform-pod-writer}
subjects: [{kind: ServiceAccount, name: os-a-openshell, namespace: tenant-a-gateway}]
Y
sleep 2
# 真实 SA 的组只有这三个(Kubernetes 固定生成，不能自定义)。
asplat=(--as=system:serviceaccount:tenant-a-gateway:os-a-openshell
        --as-group=system:serviceaccounts
        --as-group=system:serviceaccounts:tenant-a-gateway
        --as-group=system:authenticated)

echo
echo "### POC-06 / SEC-09: 租户用户 alice 在 tenant-a-runtime 里的不安全 Pod"
gk_deny "privileged 容器" poc-tenant-pod-boundary kubectl --context $CTX -n $NS run gp1 --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"gp1","image":"alpine","securityContext":{"privileged":true}}]}}'
gk_deny "hostNetwork: true" poc-tenant-pod-boundary kubectl --context $CTX -n $NS run gn1 --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"hostNetwork":true,"containers":[{"name":"gn1","image":"alpine"}]}}'
gk_deny "hostPID: true" poc-tenant-pod-boundary kubectl --context $CTX -n $NS run gp2 --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"hostPID":true,"containers":[{"name":"gp2","image":"alpine"}]}}'
gk_deny "不受控 hostPath 挂载" poc-tenant-pod-boundary kubectl --context $CTX -n $NS run gh1 --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"gh1","image":"alpine","volumeMounts":[{"name":"h","mountPath":"/host"}]}],"volumes":[{"name":"h","hostPath":{"path":"/"}}]}}'

echo
echo "### 「禁止租户借用平台 ServiceAccount」—— 需要 SA 真实存在才是有效测试"
# 上一轮这条被拒是因为 SA 在该 ns 里不存在(Kubernetes 自己的错误)，不是约束生效。
# 修正: 先在租户 ns 里建一个同名 SA，这样唯一能拦住它的就只有约束本身。
kubectl --context $CTX -n $NS apply -f - >/dev/null <<'Y'
apiVersion: v1
kind: ServiceAccount
metadata: {name: openshell, namespace: tenant-a-runtime}
Y
sleep 2
gk_deny "借用名为 openshell 的 SA" poc-tenant-pod-boundary kubectl --context $CTX -n $NS run gsa --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"serviceAccountName":"openshell","containers":[{"name":"gsa","image":"alpine"}]}}'
gk_allow "用租户自己的 SA(default)" kubectl --context $CTX -n $NS run gsad --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"serviceAccountName":"default","containers":[{"name":"gsad","image":"alpine"}]}}'

echo
echo "### 「必须显式写 requests/limits」: 这条要看执行顺序(实测结论)"
echo "   (a) 不写 resources 的 Pod —— 会被拒吗?"
out=$(kubectl --context $CTX -n $NS run gq1 --image=alpine "${asalice[@]}" --dry-run=server -o json --overrides='{"spec":{"containers":[{"name":"gq1","image":"alpine","command":["sleep","1"]}]}}' 2>&1)
tag=$(GK_TAG <<<"$out")
if [ -n "$tag" ]; then echo "      被 $tag 拒绝"; else
  echo "      没被拒。它最终实际拿到的 resources:"
  python3 -Ic 'import sys,json
raw=sys.stdin.read()
try:
    o=json.loads(raw)
    print("        resources =", json.dumps(o["spec"]["containers"][0].get("resources"), ensure_ascii=False))
except Exception as e:
    print("        (解析失败)", e)' <<<"$out"
  echo "      → Capsule 的 LimitRange 是 **mutating** webhook，在 Gatekeeper(validating)之前"
  echo "        就把 default requests/limits 补上了。所以「必须显式声明」这条在带 LimitRange"
  echo "        default 的 ns 里永远不会触发 —— 不是规则写错，是 admission 顺序决定的。"
  echo "        要在 POC 里让它真的触发，只能去掉 LimitRange 的 default(见 README 的说明)。"
fi
echo "   (b) 把超出租户上限的资源请求交给配额，而不是 Gatekeeper:"
kubectl --context $CTX -n $NS run gbq --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"gbq","image":"alpine","command":["sleep","1"],"resources":{"requests":{"cpu":"50m","memory":"800Mi"},"limits":{"cpu":"100m","memory":"800Mi"}}}]}}' 2>&1 | sed 's/^/      /'
echo "   (c) 超过 LimitRange max 的容器:"
kubectl --context $CTX -n $NS run gdbig --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"gdbig","image":"alpine","command":["sleep","1"],"resources":{"requests":{"cpu":"2","memory":"2Gi"},"limits":{"cpu":"2","memory":"2Gi"}}}]}}' 2>&1 | sed 's/^/      /'

echo
echo "### 作用域精确性(POC2 §3.5: 不要对整个 Runtime Namespace 做宽泛豁免)"
gk_allow "平台 ns(kube-system)里带 hostPath 的系统 Pod" kubectl --context $CTX -n kube-system run plat-ok --image=alpine --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"plat-ok","image":"alpine","command":["sleep","1"],"volumeMounts":[{"name":"h","mountPath":"/host"}]}],"volumes":[{"name":"h","hostPath":{"path":"/etc/hosts"}}]}}'
echo "   ↓ 关键一组: **同一个 namespace**，只有身份不同。"
echo "     实现方式: Rego 里读 input.review.userInfo.username，命中 allowedIdentities 的跳过规则。"
echo "     为什么不是组(实测): Gatekeeper 的 match 里**没有** users/groups；而真实 SA 的组"
echo "     只有 system:serviceaccounts{,:<ns>} / system:authenticated，**不能自定义**。"
echo "     用 --as-group=platform.poc 测通过是假象 —— 那个组是测试自己造的，"
echo "     真实 gateway SA 永远带不上，于是 gateway 会被自己的约束拒掉。"
gk_allow "平台身份 + 借用平台 SA" kubectl --context $CTX -n $NS run plat-sa --image=alpine "${asplat[@]}" --dry-run=server -o name --overrides='{"spec":{"serviceAccountName":"openshell","containers":[{"name":"plat-sa","image":"alpine","command":["sleep","1"]}]}}'
gk_allow "平台身份 + privileged(应被跳过)" kubectl --context $CTX -n $NS run plat-priv --image=alpine "${asplat[@]}" --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"plat-priv","image":"alpine","securityContext":{"privileged":true}}]}}'
gk_allow "平台身份 + hostPath(应被跳过)" kubectl --context $CTX -n $NS run plat-hp --image=alpine "${asplat[@]}" --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"plat-hp","image":"alpine","command":["sleep","1"],"volumeMounts":[{"name":"h","mountPath":"/host"}]}],"volumes":[{"name":"h","hostPath":{"path":"/"}}]}}'
echo "   ↑ 前提: 该身份在租户 ns 里有 RBAC(上面的 RoleBinding)。注意 subject.namespace 写的是"
echo "     SA 自己所在的 tenant-a-gateway —— 写成 runtime ns 会静默绑不上，然后你会把"
echo "     RBAC 的拒绝误当成 Gatekeeper 的效果(踩过)。"
echo "   对照: 同一个 ns、同一个 Pod，换成租户身份就被拒 ↓"
gk_deny "同一 Pod + 租户身份" poc-tenant-pod-boundary kubectl --context $CTX -n $NS run gsa2 --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"serviceAccountName":"openshell","containers":[{"name":"gsa2","image":"alpine","command":["sleep","1"]}]}}'
gk_deny "privileged + 租户身份" poc-tenant-pod-boundary kubectl --context $CTX -n $NS run apr2 --image=alpine "${asalice[@]}" --dry-run=server -o name --overrides='{"spec":{"containers":[{"name":"apr2","image":"alpine","securityContext":{"privileged":true}}]}}'
echo "   → 没有任何 ns 级豁免：差别**只**在身份。这正是 POC2 §3.5 要的形状。"

echo
echo "### 附带发现: 平台托管标签是在**写入时被改写**，不是事后被改回去"
before=$(kubectl --context $CTX get ns $NS -o jsonpath='{.metadata.labels.platform\.example\.com/tenant}')
# 关键探针: --dry-run=server 会走完整 admission 链(mutating + validating)但不落盘。
# 它返回的对象里标签已经是旧值 => 改写发生在 Capsule 的 **mutating webhook**，不是异步 reconcile。
dry=$(kubectl --context $CTX patch ns $NS -p '{"metadata":{"labels":{"platform.example.com/tenant":"tenant-b"}}}' "${asalice[@]}" --dry-run=server -o jsonpath='{.metadata.labels.platform\.example\.com/tenant}' 2>&1)
live=$(kubectl --context $CTX patch ns $NS -p '{"metadata":{"labels":{"platform.example.com/tenant":"tenant-b"}}}' "${asalice[@]}" -o jsonpath='{.metadata.labels.platform\.example\.com/tenant}' 2>&1)
sleep 3
after=$(kubectl --context $CTX get ns $NS -o jsonpath='{.metadata.labels.platform\.example\.com/tenant}')
echo "      写入前=$before"
echo "      alice 想写 tenant-b:"
echo "        dry-run=server 返回 = $dry   (admission 链走完、未落盘)"
echo "        真实 PATCH 返回     = $live"
echo "        3s 后再读           = $after"
if [ "$dry" = "$before" ] && [ "$live" = "$before" ]; then
  echo "      → 结论: Capsule 的 mutating webhook(capsule-dynamic-webhook)在写入瞬间就把托管标签改回。"
  echo "        API 返回 200，没有任何错误 —— 所以**审计里看不到 denial**，"
  echo "        想发现这种「租户试图改平台标签」的行为得靠审计日志里的 request 对象 diff，"
  echo "        不能靠 webhook 拒绝事件。这条和 Gatekeeper 的拒绝是两种不同的可观测路径。"
else
  echo "      → 与预期不符，需要再看(值没有被改回)。"
fi

echo "### 可观测: 拒绝在哪里能看到"
n=$(kubectl --context $CTX -n gatekeeper-system logs deploy/gatekeeper-controller-manager --all-containers --tail=4000 2>/dev/null | grep -ciE 'denied|violation' || true)
echo "   gatekeeper controller 日志里 denial/violation 行: $n"
kubectl --context $CTX -n gatekeeper-system logs deploy/gatekeeper-controller-manager --all-containers --tail=4000 2>/dev/null | grep -iE 'denied|violation' | tail -2 | cut -c1-190 | sed 's/^/      /'
echo "   审计角度: kind 默认不开 audit；要在生产验证这条链路需开 audit + Gatekeeper 的 ValidatingAdmissionPolicy 侧记录。"
echo
echo
echo "### 可观测(补): 拒绝计数的**唯一**默认出口是 metrics，不是日志"
# 默认 loglevel 下 controller 日志里**没有** denial 行(上面数到 0)。但指标里有:
kubectl --context $CTX -n gatekeeper-system get deploy -o custom-columns=N:.metadata.name --no-headers | awk '{print "   deploy="$1}'
# 实测两个坑:
#  * metrics 端口是 **8888**(containerPort name=metrics)，不是 8080 —— 写 8080 拿到空。
#  * 在 gatekeeper-system 里起 busybox 探针会被 PodSecurity "restricted:v1.24" 拒
#    (kind 1.37 对系统 namespace 开 enforce=restricted)；gatekeeper 镜像是 distroless，
#    也没有 shell 可 exec。最稳的取法是 port-forward 到宿主再 curl。
# 注意: svc/gatekeeper-webhook-service **没有** 8888 的 service port(只有 8443/9090)，
# 所以必须 port-forward 到 **pod**。指标名也随版本变过(v3.23 是
# gatekeeper_validation_request_count_total{admission_status="allow|deny"})。
POD=$(kubectl --context $CTX -n gatekeeper-system get pods \
  -o custom-columns=N:.metadata.name --no-headers | grep controller-manager | head -1 | awk '{print $1}')
pkill -f "port-forward" >/dev/null 2>&1
kubectl --context $CTX -n gatekeeper-system port-forward "pod/$POD" 18888:8888 >/tmp/pf-gk.log 2>&1 &
PF=$!; sleep 4
raw=$(curl -sS --max-time 10 http://127.0.0.1:18888/metrics 2>/dev/null || true)
kill $PF >/dev/null 2>&1
echo "$raw" | grep -E "^gatekeeper_validation_request_count_total" | sed 's/^/   /'
# 两个必须写进报告的实测事实:
#  1. **每个副本一套计数**。逐个 pod 看，可能有一个副本 deny=0、另一个副本 deny=38 ——
#     因为请求是按副本分配的。做告警/看板必须先对 Deployment 求和，
#     只看一个 pod 会**漏掉拒绝**(这类"部分可见"比完全看不见更危险)。
#  2. 本脚本用 `--dry-run=server` 测准入，它落在 **admission_dryrun="true"** 这条序列上。
#     也就是说: 测试产生的拒绝和生产的拒绝**不在同一个序列里**。
#     生产看板要按 admission_dryrun=false 过滤，否则会把测试流量算进真实拒绝率。
for POD in $(kubectl --context $CTX -n gatekeeper-system get pods \
    -o custom-columns=N:.metadata.name --no-headers | grep controller-manager); do
  kubectl --context $CTX -n gatekeeper-system port-forward "pod/$POD" 18889:8888 >/dev/null 2>&1 &
  PF2=$!; sleep 3
  printf '   %-46s ' "$POD"
  curl -sS --max-time 8 http://127.0.0.1:18889/metrics 2>/dev/null \
    | grep -E '^gatekeeper_validation_request_count_total' \
    | sed -E 's/gatekeeper_validation_request_count_total//; s/^/ /' | tr -d '\n'
  echo
  kill $PF2 >/dev/null 2>&1
done

echo "   → POC2 §12 的可观测设计要把这条算进去: 准入拒绝要在指标里取，"
echo "     想在日志里看到需要把 gatekeeper 的 log-level 调高(有性能代价)。"

# 测试用的 SA 用真实名字建(见上面注释)，用完删掉 —— 否则 08 阶段 helm 装 gateway 会报
# "existing resource conflict: ... serviceaccounts/os-a-openshell"，由 helm 拥有它才对。
kubectl --context $CTX -n tenant-a-gateway delete sa os-a-openshell --ignore-not-found >/dev/null 2>&1
echo "   已删除测试用的 SA os-a-openshell(让 helm 在 08 阶段自己创建/拥有)"
echo "清理测试对象: kubectl --context kind-agent-runtime-poc delete pods -n tenant-a-runtime --all"
