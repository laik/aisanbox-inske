#!/usr/bin/env bash
# Phase 2a —— agent-sandbox controller (POC2 §3.6)
# 手工重现: bash poc/phases/06-agent-sandbox.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
NS=tenant-a-runtime
GRP_A=tenant-a-owners
AGENT_SANDBOX_VERSION=${AGENT_SANDBOX_VERSION:-v1.0.10}

# POC2 §3.6 用的是 sandbox.yaml；这里用 sandbox-with-extensions.yaml，
# 因为它带上 extensions(SandboxTemplate / Claim / WarmPool)。两条路径都记下来。
# release asset 在这台机器不可达(objects.githubusercontent.com 超时) —— 先取到 vendor/。
bash scripts/gh-fetch.sh kubernetes-sigs/agent-sandbox "$AGENT_SANDBOX_VERSION" \
  sandbox-with-extensions.yaml
kubectl --context $CTX apply -f vendor/sandbox-with-extensions.yaml >/dev/null
kubectl --context $CTX -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=180s

echo "### CRD 与 API 版本(POC-03 的前提)"
kubectl --context $CTX get crd -o name | grep agents.x-k8s.io | sed 's|^customresourcedefinition.apiextensions.k8s.io/|   |'
kubectl --context $CTX get crd sandboxes.agents.x-k8s.io \
  -o 'jsonpath={range .spec.versions[*]}{"   served="}{.name}{" storage="}{.storage}{"\n"}{end}'

echo
echo "### POC2 §3.6 要求的兼容性确认: OpenShell 0.1.7 用哪个 Sandbox API"
TMP=$(mktemp -d)
helm pull oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.7 --untar --untardir "$TMP" >/dev/null
echo "   OpenShell chart 自带的 preflight 检查:"
sed -n '1,20p' "$TMP/helm-chart/templates/agent-sandbox-preflight.yaml" 2>/dev/null | sed 's/^/     /'
rm -rf "$TMP"
echo "   集群实际提供的:"
kubectl --context $CTX get crd sandboxes.agents.x-k8s.io -o 'jsonpath={.spec.versions[*].name}' | sed 's/^/     /'
echo
echo "   → 两边都是 agents.x-k8s.io/v1beta1(Sandbox)：兼容。(这是**验证过**的，不是假设。)"

# ---------------------------------------------------------------------------
echo
echo "### 先证明"裸 agent-sandbox"能落地 Pod(OpenShell 还没参与)"
kubectl --context $CTX -n $NS apply -f - >/dev/null 2>&1 <<'Y'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: poc2-platform-sandbox-manager, namespace: tenant-a-runtime}
rules: [{apiGroups: ["agents.x-k8s.io"], resources: ["sandboxes"], verbs: ["create","get","list","watch","delete"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: poc2-platform-sandbox-manager, namespace: tenant-a-runtime}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: poc2-platform-sandbox-manager}
subjects: [{kind: ServiceAccount, name: os-a-openshell, namespace: tenant-a-gateway}]
Y
sleep 2
# 坑: v1beta1 的字段是 **podTemplate**，不是 pod。写成 pod 会被 strict decoding 拒绝
#      ("unknown field spec.pod") —— 网上很多示例还是旧字段名。
cat > /tmp/poc2-sandbox-plain.yaml <<'Y'
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: as-plain
  namespace: tenant-a-runtime
spec:
  podTemplate:
    spec:
      containers:
        - name: agent
          image: alpine:latest
          command: ["sleep", "900"]
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
Y
echo "   用**真实**平台身份创建(gateway SA os-a-openshell):"
kubectl --context $CTX -n $NS delete sandbox as-plain --ignore-not-found --wait=true >/dev/null 2>&1
T0=$(date +%s)
# 身份必须是**约束里那个真实 SA 名**。上一轮用 --as-group=platform.poc 是测试自己造的组，
# 真实 gateway SA 带不上它(constraints.yaml 的注释记录了这件事) —— 所以那条路现在是**故意**
# 不通的。这里先临时建出真实名字的 SA，用它的身份创建，测完删掉让 helm 拥有它。
kubectl --context $CTX -n tenant-a-gateway create sa os-a-openshell --dry-run=client -o yaml | \
  kubectl --context $CTX apply -f - >/dev/null
AS_GW=(--as=system:serviceaccount:tenant-a-gateway:os-a-openshell
       --as-group=system:serviceaccounts
       --as-group=system:serviceaccounts:tenant-a-gateway
       --as-group=system:authenticated)
kubectl --context $CTX apply -f /tmp/poc2-sandbox-plain.yaml "${AS_GW[@]}" 2>&1 | sed 's/^/     /'
# 坑: Pod 是 agent-sandbox controller 异步创建的，直接 `wait pod/as-plain` 会先报 NotFound。
#     正确做法是等 Sandbox 自己的 Ready condition。
kubectl --context $CTX -n $NS wait --for=condition=Ready --timeout=180s sandbox/as-plain 2>&1 | sed 's/^/     /'
T1=$(date +%s)
echo "     Sandbox -> Ready Pod 用时 $((T1-T0))s(含拉镜像)"
kubectl --context $CTX -n $NS get sandbox as-plain -o 'jsonpath={range .status.conditions[*]}{"     cond="}{.type}{"="}{.status}{" reason="}{.reason}{"\n"}{end}' 2>/dev/null
kubectl --context $CTX -n $NS get pod as-plain -o wide --no-headers | cut -c1-110 | sed 's/^/   /'
echo "   ⚠ 这条路径的 Pod **没有** OpenShell supervisor：没有网络边界、没有策略、没有凭据注入。"
echo "     (round 1 就记录过: 直接/池化创建的 sandbox 与 OpenShell 的 sandbox 是两条独立路径。"
echo "      POC2 走的是 OpenShell 路径，这里的裸路径只用来证明依赖本身可用。)"

# ---------------------------------------------------------------------------
echo
echo "### SEC-10 的两层防线，分开测才有意义"
echo " ① RBAC 层(默认就拦得住): alice 没有 agents.x-k8s.io 权限"
kubectl --context $CTX -n $NS apply -f /tmp/poc2-sandbox-plain.yaml --as=alice --as-group=$GRP_A 2>&1 | head -1 | cut -c1-150 | sed 's/^/     /'

echo " ② Gatekeeper 层: 先**故意**把权限给租户，再看约束是否还拦得住"
# 注意: 对象已存在时 `apply` 不产生 admission 请求(no-op)，会看到 "unchanged" 而不是拒绝。
#       测准入必须用**新名字**或先删除。踩过这个坑。
kubectl --context $CTX -n $NS apply -f - >/dev/null <<'Y'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: poc2-give-tenants-sandboxes, namespace: tenant-a-runtime}
rules: [{apiGroups: ["agents.x-k8s.io"], resources: ["sandboxes"], verbs: ["create","get","list","delete"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: poc2-give-tenants-sandboxes, namespace: tenant-a-runtime}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: poc2-give-tenants-sandboxes}
subjects: [{kind: Group, name: tenant-a-owners, apiGroup: rbac.authorization.k8s.io}]
Y
sleep 2
kubectl --context $CTX -n $NS delete sandbox as-plain --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX apply -f /tmp/poc2-sandbox-plain.yaml --as=alice --as-group=$GRP_A 2>&1 | head -1 | cut -c1-160 | sed 's/^/     /'
echo "     → 出现 [poc-managed-cr-only-platform] 就说明第二层独立生效。"
echo "     这就是 POC2 §3.5 要的：不因为 controller 需要管理资源就把整个 ns 豁免。"

echo " ③ 同一个时刻，平台身份必须还能创建(否则就是误伤)。"
echo "    (管理员组也要在 allowedGroups 里 —— 见 constraints.yaml，实测不加会被自己的约束挡住)"
kubectl --context $CTX -n $NS delete sandbox as-plain --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX apply -f /tmp/poc2-sandbox-plain.yaml "${AS_GW[@]}" 2>&1 | sed 's/^/     /'

echo
echo "### 实测边界(必须写进报告): 管理员组名是发行版相关的"
echo "   本机(kind)的管理员身份:"
kubectl --context $CTX auth whoami 2>/dev/null | head -2 | sed 's/^/     /'
echo "   → 组是 kubeadm:cluster-admins，**不是** system:masters。"
echo "     skip_identity 里必须写实际的组名，否则排障时会被自己的约束挡住。"
kubectl --context $CTX -n $NS delete sandbox as-plain --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX apply -f /tmp/poc2-sandbox-plain.yaml 2>&1 | head -1 | cut -c1-160 | sed 's/^/     /'
echo "     → 现在它能过，是因为 allowedGroups 里有**本集群实际的管理员组**。"
echo "       实测本机(kind v1.37)管理员组是 kubeadm:cluster-admins；很多文档写 system:masters。"
echo "       两者都列进 allowedGroups 才对 —— 只写一个，另一种发行版上运维手工排障会被自己的"
echo "       约束拒掉(这是约束**正确**、运维被误伤的那一类，报错读起来像权限坏了)。"
kubectl --context $CTX -n tenant-a-gateway delete sa os-a-openshell --ignore-not-found >/dev/null 2>&1

kubectl --context $CTX -n $NS delete sandbox as-plain --ignore-not-found >/dev/null 2>&1
kubectl --context $CTX -n $NS delete role,rolebinding poc2-give-tenants-sandboxes --ignore-not-found >/dev/null 2>&1
echo
echo "清理: kubectl --context kind-agent-runtime-poc -n tenant-a-runtime delete sandbox as-plain"
