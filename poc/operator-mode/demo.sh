#!/usr/bin/env bash
# operator 模式多租户实跑（单 Gateway + 平台预置 Namespace）。
# 用法：bash demo.sh            # 完整验证，输出到 stdout（自行 tee 到 evidence 文件）
#       bash demo.sh down       # 只清理本次建的 sandbox / probe 负载（保留 ns、chart、workspace）
# 前置：agent-sandbox CRD/controller、openshell gateway（shared 或 operator 均可）、
#       gateway SA 的 ClusterRole 由 chart 管理、Vault 等 credential driver 可用（否则建沙箱会先报 credential 错）。
set -uo pipefail

CTX=${CTX:-k8s-221}
GNS=${GNS:-openshell}
GW="openshell"                       # helm release / gateway 名
CHART="oci://ghcr.io/nvidia/openshell/helm-chart"
WSCHART="oci://ghcr.io/nvidia/openshell/openshell-workspace"
VER=${VER:-0.1.7}
NSLAB="openshell.ai/workspace=true" # 发现用标签；与 operator_namespace_file 二选一
IMG="nvcr.io/nvidia/base/ubuntu:24.04"
K="kubectl --context $CTX"
OS="openshell"
HERE=$(cd "$(dirname "$0")" && pwd)

A=tenant-a-runtime; B=tenant-b-runtime; C=tenant-c-runtime; D=tenant-d-runtime; E=tenant-e-runtime
rollout() { $K -n "$GNS" rollout status "sts/$GW" --timeout=240s | tail -1 || { echo "!! gateway 未就绪，启动日志："; $K -n "$GNS" logs "$GW"-0 --tail=5; exit 1; }; }
sb() { $OS sandbox create --workspace "$1" --name "$2" --from "$IMG" --detach --restart-policy never -- sleep 3600 2>&1 | tail -4; }
tcp() { # 从 ns 里的 probe pod 探测：0=tcp 建立 / 124=被策略丢弃 / 其它=到达但对端拒绝
  local ns=$1 host=$2 port=$3
  $K -n "$ns" exec -i probe -- bash -s <<EOF
timeout 6 bash -c "exec 3<>/dev/tcp/$host/$port" 2>&1; rc=\$?
case \$rc in 0) echo "REACHED";; 124) echo "BLOCKED(dropped)";; *) echo "REACHED(refused/reset rc=\$rc)";; esac
EOF
}

if [ "${1:-up}" = down ]; then
  for s in "op-a $A" "op-b $B" "op-e $E"; do set -- $s; $OS sandbox delete --workspace "$2" "$1" >/dev/null 2>&1 && echo "deleted sandbox $1 ($2)"; done
  $K -n "$A" delete pod probe --ignore-not-found >/dev/null
  $K -n "$B" delete pod plain --ignore-not-found >/dev/null
  echo "down: 保留 5 个 runtime namespace、openshell-workspace release、workspace 记录"
  exit 0
fi

echo "########## 00 变更前状态 ##########"
date -u '+%Y-%m-%dT%H:%M:%SZ'
$K -n "$GNS" get cm openshell-config -o jsonpath='{.data.gateway\.toml}' | grep -E 'workspace_mode|operator_namespace'
$K get ns | grep -E 'tenant-[a-e]-runtime' || echo "(尚无 tenant runtime ns)"

echo; echo "########## 10 平台预置 namespace + 每 ns 装 openshell-workspace ##########"
# C: 打标签但不装 chart（验证 RBAC 只能来自 workspace chart）；D: 装 chart 但不打标签（验证发现只看标签）
$K apply -f "$HERE/namespaces.yaml"
# e 只在 file 模式那段用到；d 永远不带标签（namespaces.yaml 已经建好 a/b/c/d）
$K create ns "$E" >/dev/null 2>&1
$K label ns "$E" openshell.ai/workspace=true platform.io/tenant=tenant-e --overwrite >/dev/null
$K label ns "$D" openshell.ai/workspace- >/dev/null 2>&1
for t in a b d e; do helm upgrade --install openshell-workspace "$WSCHART" --version "$VER" -n "tenant-$t-runtime" >/dev/null 2>&1 && echo "installed openshell-workspace in tenant-$t-runtime"; done
$K get ns -L openshell.ai/workspace -L platform.io/tenant | grep tenant-
$K -n "$A" get sa,role,rolebinding,netpol

echo; echo "########## 20 Gateway 切到 operator（label 发现）##########"
helm get values "$GW" -n "$GNS" -o yaml > /tmp/os-user-values.yaml
helm upgrade "$GW" "$CHART" --version "$VER" -n "$GNS" \
  -f /tmp/os-user-values.yaml -f "$HERE/values-operator.yaml" \
  --set agentSandbox.preflight.enabled=false >/dev/null && echo "helm upgrade ok"
rollout
$K -n "$GNS" get cm openshell-config -o jsonpath='{.data.gateway\.toml}' | grep -E 'workspace_mode|operator_namespace'
$K -n "$GNS" logs "$GW"-0 --since=3m 2>&1 | grep -iE "operator namespace|allowlist" | head -3
# 标签即准入：凡带该标签的 ns 都会进 allowlist（含没有 workspace chart 的 $C）
$K get ns -l "openshell.ai/workspace=true"

echo; echo "########## 30 RBAC 边界（gateway SA 在集群/在各 ns 能做什么）##########"
SA=system:serviceaccount:$GNS:$GW
for v in "list namespaces" "create namespaces" "delete namespaces"; do printf 'cluster  %-20s => ' "$v"; $K auth can-i $v --as="$SA" 2>/dev/null; done
for ns in "$A" "$C"; do for v in "create secrets" "delete secrets" "create sandboxes.agents.x-k8s.io" "create services" "create networkpolicies"; do printf '%-18s %-31s => ' "$ns" "$v"; kubectl --context $CTX auth can-i $v -n "$ns" --as="$SA" 2>/dev/null; done; done

echo; echo "########## 40 Workspace = Namespace，一个 Gateway 两个租户 ##########"
for w in "$A" "$B" "$C" "$E"; do $OS workspace create --name "$w" 2>&1 | tail -1; done
$OS workspace list
sb "$A" op-a; sb "$B" op-b
echo "--- 资源落点（CR / Pod / Service / NetworkPolicy / Secret / SA 都在租户 ns 内）"
$K get sandboxes.agents.x-k8s.io -A | grep -E "NAMESPACE|op-a|op-b"
for ns in "$A" "$B"; do echo "--- $ns"; $K -n "$ns" get pod,svc,netpol,secret,sa 2>&1 | grep -vE "No resources|^$"; done
echo "--- 控制面隔离：每个 workspace 只看自己的 sandbox"
for w in "$A" "$B"; do echo "--- --workspace $w"; $OS sandbox list --workspace "$w"; done
echo "--- 数据面：跨 ns 的 sandbox 可 exec"
$OS sandbox exec --name op-a --workspace "$A" -- sh -c 'hostname'

echo; echo "########## 50 负例 ##########"
echo "--- 5a ns 打了标签但没装 openshell-workspace chart（${C}）"
sb "$C" op-c
echo "--- 5b ns 装了 chart 但没打标签（${D}）"
$OS workspace create --name "$D" 2>&1 | tail -1; sb "$D" op-d
echo "--- 5c workspace 名长度上限（operator 模式下 ns 名同受此限）"
$OS workspace create --name tenant-a-agent-runtime 2>&1 | tail -2
echo "--- 5d 切换模式不迁移旧沙箱（shared 期建的沙箱 CR 仍留在 ${GNS}）"
$K get sandboxes.agents.x-k8s.io -n "$GNS" | head -5

echo; echo "########## 60 namespace 生命周期由平台掌管 ##########"
$OS workspace delete "$D" 2>&1 | tail -1
$K get ns "$D" | tail -1

echo; echo "########## 70 网络隔离（Antrea 实跑，不是只看 API 对象）##########"
# probe 打上 boundary-role=supervisor，享受与真 supervisor pod 完全相同的策略（egress 不限）
$K apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: probe, namespace: $A, labels: {app: probe, openshell.ai/boundary-role: supervisor}}
spec: {containers: [{name: c, image: $IMG, args: ["sleep","1200"]}]}
---
apiVersion: v1
kind: Pod
metadata: {name: plain, namespace: $B, labels: {app: plain}}
spec: {containers: [{name: c, image: $IMG, args: ["sleep","1200"]}]}
EOF
$K -n "$A" wait --for=condition=Ready pod/probe --timeout=180s >/dev/null
$K -n "$B" wait --for=condition=Ready pod/plain --timeout=180s >/dev/null
PLAIN_IP=$($K -n "$B" get pod plain -o jsonpath='{.status.podIP}')
BOUNDA=$($K -n "$A" get svc -o name | grep os-boundary | head -1 | cut -d/ -f2)
BOUNDB=$($K -n "$B" get svc -o name | grep os-boundary | head -1 | cut -d/ -f2)
echo "正对照 本 ns boundary :5500        => $(tcp "$A" "$BOUNDA.$A.svc" 5500)"
echo "跨租户 对端 boundary :5500        => $(tcp "$A" "$BOUNDB.$B.svc" 5500)"
echo "无策略 对端普通 pod :80          => $(tcp "$A" "$PLAIN_IP" 80)  # OpenShell 的策略只管沙箱 pod，租户级隔离要平台补"
echo "--- 生成出的策略（跨 ns 的 podSelector 天然隔离）"
$K -n "$A" get netpol -o name | sed "s|.*/||"

echo; echo "########## 80 另一种发现机制：JSON allowlist + 热加载 ##########"
$K apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: openshell-workspace-namespaces, namespace: $GNS}
data:
  namespaces.json: |
    ["$A","$B","$C"]
EOF
helm upgrade "$GW" "$CHART" --version "$VER" -n "$GNS" \
  -f /tmp/os-user-values.yaml -f "$HERE/values-operator-file.yaml" \
  --set agentSandbox.preflight.enabled=false >/dev/null
rollout
$K -n "$GNS" logs "$GW"-0 2>&1 | grep -iE "allowlist (loaded|reloaded)|file watcher" | head -3
echo "--- 打了标签但不在清单里的 ns（${E}）在 file 模式下应被拒"
sb "$E" op-e-file
echo "--- 把 $E 加进 ConfigMap，不重启 pod 应热加载"
PODUID=$($K -n "$GNS" get pod "$GW"-0 -o jsonpath='{.metadata.uid}')
$K -n "$GNS" patch cm openshell-workspace-namespaces --type=merge \
  -p "{\"data\":{\"namespaces.json\":\"[\\\"$A\\\",\\\"$B\\\",\\\"$C\\\",\\\"$E\\\"]\"}}"
for i in $(seq 1 24); do sleep 5; $K -n "$GNS" logs "$GW"-0 --since=3m 2>&1 | grep -q "allowlist reloaded from file .* total=4" && break; done
$K -n "$GNS" logs "$GW"-0 --since=5m 2>&1 | grep -iE "allowlist" | tail -2
echo "pod uid 不变: $PODUID == $($K -n "$GNS" get pod "$GW"-0 -o jsonpath='{.metadata.uid}') / restarts=$($K -n "$GNS" get pod "$GW"-0 -o jsonpath='{.status.containerStatuses[0].restartCount}')"
sb "$E" op-e
$K get sandboxes.agents.x-k8s.io -A | grep -E "NAMESPACE|op-e"

echo; echo "########## 82 删 Workspace 会不会回收 ns 里的沙箱资源 ##########"
$OS workspace delete "$E" 2>&1 | tail -1
echo "--- 控制面"; $OS sandbox list --workspace "$E" 2>&1 | tail -3
echo "--- K8s 侧"; $K get sandboxes.agents.x-k8s.io -n "$E" 2>&1 | tail -3

echo; echo "########## 85 负例：两种发现机制同时配置（0.1.7 是硬错误）##########"
helm upgrade "$GW" "$CHART" --version "$VER" -n "$GNS" \
  -f /tmp/os-user-values.yaml -f "$HERE/values-operator-both.yaml" \
  --set agentSandbox.preflight.enabled=false >/dev/null
sleep 45
$K -n "$GNS" get pod "$GW"-0 | tail -1
$K -n "$GNS" logs "$GW"-0 --tail=4 2>&1 | tail -3

echo; echo "########## 90 收尾：回到 label 发现（推荐形态）##########"
helm upgrade "$GW" "$CHART" --version "$VER" -n "$GNS" \
  -f /tmp/os-user-values.yaml -f "$HERE/values-operator.yaml" \
  --set agentSandbox.preflight.enabled=false >/dev/null
rollout
$K -n "$GNS" get cm openshell-config -o jsonpath='{.data.gateway\.toml}' | grep -E 'workspace_mode|operator_namespace'
$K -n "$GNS" delete cm openshell-workspace-namespaces --ignore-not-found

echo "回退到 shared：helm rollback $GW -n $GNS  （或去掉 values-operator.yaml 重新 upgrade）"
date -u '+%Y-%m-%dT%H:%M:%SZ'
