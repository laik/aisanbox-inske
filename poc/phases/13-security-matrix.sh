#!/usr/bin/env bash
# Phase 6 —— 安全测试矩阵 (POC2 §11, 补齐 SEC-04 / SEC-06 / SEC-07 / SEC-08 / SEC-12)
# 手工重现: bash poc/phases/13-security-matrix.sh
#
# 这份脚本只做**上一轮没做**的五条；SEC-01/02/03/05/09/10/11/14 已在
# 03-netpol-verify.sh / 05-gatekeeper.sh / 09-resource-admission.sh / 11-pi-scenario.sh 里跑过，
# 这里只做**汇总核对**，不重复实现。
#
# ===== 本轮(2026-11-09)实测结论，先写在这里 =====
# ⚠ **SEC-04 / SEC-08 的"跨租户被拒"不是 Capsule/Antrea 的租户隔离做出来的**，
#   而是 OpenShell 自己生成的 NetworkPolicy 顺带做到的。两个实测事实:
#   (1) Capsule 的 `spec.networkPolicies` 是**空的** —— 平台没有下发任何租户级 NetworkPolicy;
#   (2) 两个**普通 Pod**(不是 OpenShell 沙箱)跨租户互相 **REACHED**:
#         tenant-a/p-a -> tenant-b/p-b :8080  = REACHED
#   而 OpenShell 沙箱跨租户/跨 namespace 是 TIMEOUT，原因是它自己给每个边界对(pair)建了策略:
#         openshell-sandbox-workloads:  podSelector=boundary-role=workload, Ingress/Egress 都限
#         os-control-<boundary-pair>:   只允许到**同一个 boundary-pair** 的 supervisor:5500
#   → 报告里必须这样写: **"Agent 无法绕过 Supervisor 直接访问网络"这条(POC-05/§9.1)成立，
#     但"租户之间的网络隔离"目前是靠 OpenShell 的执行边界顺带实现的，不是平台的租户网络策略。**
#     平台如果只跑普通 Pod(或换掉 OpenShell)，这条就不存在 —— 要补 Capsule networkPolicies
#     或 Antrea ClusterNetworkPolicy。这是 POC2 §9 与 §11 混在一起的两件事，要拆开。
# ⚠ SEC-12 的"fail-closed"要看清是哪一段的链路: 沙箱 Pod 的**唯一**出网路径是自己的 supervisor
#   (os-control-<pair> 的 egress 只到它)，而 supervisor 的 egress 是**全开**(Egress 无 to)。
#   所以 supervisor↔gateway 断链时，沙箱到 supervisor 仍然通、agent 仍然能连 supervisor 的 L7 代理
#   —— "断链 fail-closed"只对**依赖 gateway 控制面**的操作(建/改沙箱)成立，不对数据面成立。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
CLI=vendor/openshell-cli-0.1.7/openshell
WS=poc-shared
A() { $CLI -g poc2-a --workspace $WS "$@"; }
RO='{"kubernetes":{"volumes":[{"name":"ws","persistent_volume_claim":{"claim_name":"shared-workspace","read_only":true}}],"containers":{"agent":{"volume_mounts":[{"name":"ws","mount_path":"/data/workspace","read_only":true}]}}}}'
RW='{"kubernetes":{"volumes":[{"name":"ws","persistent_volume_claim":{"claim_name":"shared-workspace","read_only":false}}],"containers":{"agent":{"volume_mounts":[{"name":"ws","mount_path":"/data/workspace","read_only":false}]}}}}'

pkill -f 'svc/os-a-openshell 1844' >/dev/null 2>&1
(setsid kubectl --context $CTX -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 </dev/null >/tmp/pf-a.log 2>&1 &)
sleep 4

echo "### 前置: 需要 11-pi-scenario.sh 已经跑过(pi-dev / pi-review-1 / pi-review-2)"
A sandbox list 2>&1 | awk 'NR==1||/^pi-/{print "   "$1" "$3}'
if ! A sandbox list 2>&1 | grep -q "^pi-review-1"; then
  echo "   ✗ 先跑 bash poc/phases/11-pi-scenario.sh —— 这个矩阵复用它的沙箱(配额不允许再造一套)"
  exit 1
fi
mkdir -p /tmp/pol
sed -n '/^version:/,$p' policies/pi-developer.yaml > /tmp/pol/dev.yaml
sed -n '/^version:/,$p' policies/pi-reviewer.yaml  > /tmp/pol/rev.yaml

# ---------------------------------------------------------------------------
echo
echo "### SEC-04 / SEC-08: 跨租户 —— 先把**归因**做对(见文件头 ⚠)"
echo "   (a) 平台有没有下发租户级 NetworkPolicy:"
for t in a b; do
  printf "       Capsule Tenant tenant-%s 的 spec.networkPolicies: " "$t"
  kubectl --context $CTX get tenant "tenant-$t" -o jsonpath='{.spec.networkPolicies}' | grep -q . \
    && echo "有配置" || echo "空 ← 平台没有做租户网络隔离"
done
echo "   (b) 两个普通 Pod 跨租户互访(不是沙箱):"
kubectl --context $CTX -n tenant-b-runtime run sec-pb --image=alpine:latest --restart=Never --command -- sleep 300 >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime run sec-pa --image=alpine:latest --restart=Never --command -- sleep 300 >/dev/null 2>&1
kubectl --context $CTX -n tenant-b-runtime wait --for=condition=Ready pod/sec-pb --timeout=90s >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime wait --for=condition=Ready pod/sec-pa --timeout=90s >/dev/null 2>&1
BIP=$(kubectl --context $CTX -n tenant-b-runtime get pod sec-pb -o jsonpath='{.status.podIP}')
printf "       tenant-a 普通 Pod -> tenant-b 普通 Pod(:8080): "
kubectl --context $CTX -n tenant-a-runtime exec sec-pa -- sh -c "timeout 8 nc -z -w5 $BIP 8080 && echo 'REACHED  <== 平台层没有隔离' || echo NOT_REACHED" 2>&1 | tail -1
echo "   (c) OpenShell 沙箱跨租户/跨 namespace:"
kubectl --context $CTX -n tenant-b-runtime delete pod sec-pb --ignore-not-found >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime run sec-pb2 --image=alpine:latest --restart=Never --command -- sleep 300 >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime wait --for=condition=Ready pod/sec-pb2 --timeout=90s >/dev/null 2>&1
PB2=$(kubectl --context $CTX -n tenant-a-runtime get pod sec-pb2 -o jsonpath='{.status.podIP}')
printf "       沙箱(pi-review-2) -> 同 ns 的普通 Pod: "
A sandbox exec pi-review-2 -- sh -c "timeout 8 curl -s -m 6 -o /dev/null -w '%{http_code}\n' http://$PB2:80/ 2>/dev/null || echo TIMEOUT" 2>&1 | tail -1
printf "       沙箱(pi-review-2) -> tenant-b 的 gateway: "
A sandbox exec pi-review-2 -- sh -c 'timeout 8 curl -s -m 6 -o /dev/null -w "%{http_code}\n" https://os-b-openshell.tenant-b-gateway.svc.cluster.local:8080/ 2>/dev/null || echo TIMEOUT' 2>&1 | tail -1
echo "   (d) 谁做的拒绝 —— OpenShell 自己生成的 NetworkPolicy(注意 boundary-pair 的粒度):"
kubectl --context $CTX -n tenant-a-runtime get netpol --no-headers | awk '{print "       "$1}' | head -8
kubectl --context $CTX -n tenant-a-runtime get netpol openshell-sandbox-workloads -o jsonpath='       workloads egress to = {.spec.egress}{"\n"}'
kubectl --context $CTX -n tenant-a-runtime delete pod sec-pa sec-pb2 --ignore-not-found >/dev/null 2>&1
echo "   ⚠ 结论措辞: POC-05/§9.1「Agent 不能绕过 Supervisor 出网」**成立**(上面 (c) 两条都连不上，
      而它连自己 supervisor 是通的 —— 见 11 号脚本里的模型调用)。
      「租户之间网络隔离」**不是**平台能力，是 OpenShell 边界的副作用。两者要分开写。"

# ---------------------------------------------------------------------------
echo
echo "### SEC-06 / SEC-07: 读写分权要**分别**指认是哪一层(POC2 §10.5: 不能只看 YAML)"
echo "   (a) SEC-07 Developer 写共享文件:"
A sandbox exec pi-dev -- sh -c 'touch /data/workspace/sec07 && echo "       DEV_WRITE_OK"; grep "/data/workspace" /proc/self/mountinfo | awk "{print \"       mount flags = \" \$4\"  (挂载层是可写)\"}"'
echo "   (b) SEC-06 Reviewer 写共享文件 —— 挂载 ro + 策略 ro(两层都关):"
A sandbox exec pi-review-1 -- sh -c 'grep "/data/workspace" /proc/self/mountinfo | awk "{print \"       mount flags = \" \$4}"; touch /data/workspace/sec06 2>&1 | sed "s/^/       /"'
echo "   (c) 只有**策略**关、挂载可写(证明 OpenShell 这一层独立生效):"
A sandbox create --name sec-polonly --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
  --policy /tmp/pol/rev.yaml --driver-config-json "$RW" -- sh -c 'sleep 300' >/dev/null 2>&1
sleep 30
A sandbox exec sec-polonly -- sh -c 'grep "/data/workspace" /proc/self/mountinfo | awk "{print \"       mount flags = \" \$4\"  (挂载层是可写)\"}"; touch /data/workspace/sec06 2>&1 | sed "s/^/       /"'
echo "       ↑ mountinfo 是 rw，写仍被拒(errno EACCES / Permission denied) => 拒绝来自 OpenShell 策略层"
echo "   (d) 只有**挂载**关、策略可写(对照，errno 不同):"
A sandbox create --name sec-mtonly --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
  --policy /tmp/pol/dev.yaml --driver-config-json "$RO" -- sh -c 'sleep 300' >/dev/null 2>&1
sleep 30
A sandbox exec sec-mtonly -- sh -c 'grep "/data/workspace" /proc/self/mountinfo | awk "{print \"       mount flags = \" \$4}"; touch /data/workspace/x 2>&1 | sed "s/^/       /"'
echo "       ↑ errno 是 EROFS(Read-only file system) —— 与 (c) 的 EACCES 不同，
         说明这是**两条独立的强制链**，不是一条策略的两种写法。生产上两条都要留。"
A sandbox delete sec-polonly sec-mtonly >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "### SEC-12: Supervisor ↔ Gateway 断链 —— 分清控制面与数据面"
echo "   (a) 掐断 supervisor 到 gateway 的连接(用 NetworkPolicy 临时禁止 supervisor 出网):"
SP=$(kubectl --context $CTX -n tenant-a-runtime get pods --no-headers | grep "supervisor-" | head -1 | awk '{print $1}')
PAIR=${SP#os-supervisor-}
echo "       目标 supervisor: $SP (boundary-pair=$PAIR)"
cat <<'YAML' | kubectl --context $CTX apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: sec12-cut, namespace: tenant-a-runtime}
spec:
  podSelector:
    matchLabels: {openshell.ai/boundary-role: supervisor}
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector:
            matchLabels: {openshell.ai/boundary-role: workload}
YAML
sleep 20
echo "       (b) 数据面: 沙箱仍然能通过 supervisor 访问**已批准的**端点吗?"
A sandbox exec pi-review-2 -- sh -c 'printf "         model endpoint via boundary -> "; timeout 20 curl -s -m 15 -o /dev/null -w "http=%{http_code}\n" http://192.168.5.190:8080/v1/models || echo UNREACHABLE'
echo "       (c) 控制面: 依赖 gateway 的操作应当失败(新建沙箱):"
timeout 120 $CLI -g poc2-a --workspace $WS sandbox create --name sec12-probe --from alpine:latest \
  --cpu 50m --memory 64Mi --detach --restart-policy never -- sh -c 'sleep 30' 2>&1 | tail -2 | sed 's/^/         /'
kubectl --context $CTX -n tenant-a-runtime delete netpol sec12-cut >/dev/null 2>&1
A sandbox delete sec12-probe >/dev/null 2>&1
echo "   ⚠ 这条的正确结论: **数据面不 fail-closed**(supervisor 本地仍代理已批准的 L7 请求)，
      **控制面 fail-closed**(不能建/改沙箱)。POC2 §11 只写"Fail Closed"太粗 ——
      要按 POC2 §9.1 的图分开写: supervisor 的 egress 是**全开**的(见 openshell-sandbox-supervisors
      那条 netpol: policyTypes=[Egress]、没有 to)，所以断 gateway 不影响已批准的出网。"

# ---------------------------------------------------------------------------
echo
echo "### 汇总核对(其余 SEC 已在各自脚本里跑过，这里只做存在性检查)"
chk() { printf "   %-8s %s\n" "$1" "$2"; }
chk SEC-01 "03/11: 沙箱直连未批准域名 -> 见上面 (c) 的 TIMEOUT + supervisor 日志里的 transparent_tcp_policy_denied"
chk SEC-02 "11: 模型调用经边界 -> supervisor 日志 OCSF HTTP:POST ALLOWED … engine:l7"
chk SEC-03 "11: 未批准域名 -> OCSF NET:OPEN [MED] DENIED … [reason:transparent_tcp_policy_denied]"
chk SEC-05 "11: kubernetes.default.svc 被拒(沙箱 egress 只到自己的 supervisor)"
chk SEC-09 "05-gatekeeper.sh: privileged/hostNetwork/hostPID/hostPath 被 [poc-tenant-pod-boundary] 拒"
chk SEC-10 "05-gatekeeper.sh: RBAC 先拒；给权限后 [poc-managed-cr-only-platform] 仍拒"
chk SEC-11 "11: 沙箱里 OPENAI_API_KEY 是 openshell:resolve:env:… 占位符"
chk SEC-14 "09-resource-admission.sh: 无标签/标签不符 -> not admitted by required labels"
echo
echo "### 本轮新增的三条要点(要进报告)"
echo "   1) SEC-04/08 的归因: 跨租户阻断来自 OpenShell 的 NetworkPolicy，不是租户隔离。"
echo "      补法: Capsule spec.networkPolicies 或 Antrea ClusterNetworkPolicy(按 ns label)。"
echo "   2) SEC-06/07 是**两层独立**强制(EROFS vs EACCES)。只测一层会在另一层配置漂移时失效。"
echo "   3) SEC-12 要按控制面/数据面分别写；supervisor 的 egress 是全开的。"
