#!/usr/bin/env bash
# Phase 3b —— OpenShell Resource Admission: 外部 PVC 必须经过授权标签检查
# (POC2 §4.4 / SEC-14 / §13.2「外部 PVC 必须经过 OpenShell Resource Admission」)
# 手工重现: bash poc/phases/09-resource-admission.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
NS=tenant-a-runtime
CLI=vendor/openshell-cli-0.1.7/openshell
A() { $CLI -g poc2-a "$@"; }

echo "### 0. gateway 侧配置(POC2 §4.4)"
kubectl --context $CTX -n tenant-a-gateway get configmap -l app.kubernetes.io/name=openshell \
  -o 'jsonpath={.items[0].data.gateway\.toml}' | awk '/resource_admission/{f=1} f&&/^\[openshell.gateway\]/{exit} f' | sed 's/^/   /'
echo "   源码事实(v0.1.7 crates/openshell-core/src/resource_admission.rs):"
echo "     - \${workspace} 是**整值替换**，不支持 prefix-\${workspace} 这种拼接;"
echo "     - 保留键是 openshell.ai/{managed-by,gateway-id,sandbox-workspace}，"
echo "       而 sandbox-attachable* 不在保留键里 —— 所以 POC2 用它们是合法的;"
echo "     - required_labels 若**全部**是 \${workspace} 会被启动校验拒绝:"
echo "       'must include a shared approval label' —— 即必须同时有一个固定的批准标签。"

kubectl --context $CTX -n $NS apply -f storage/workspace-pvc.yaml >/dev/null
sleep 3
echo
echo "### 1. 三个 PVC 都建出来了(标签在 API 层不是限制条件)"
kubectl --context $CTX -n $NS get pvc -L openshell.ai/sandbox-attachable --no-headers \
  | awk '{print "   "$1" phase="$2" attachable="$5}'

DC() { printf '{"kubernetes":{"volumes":[{"name":"ws","persistent_volume_claim":{"claim_name":"%s","read_only":%s}}],"containers":{"agent":{"volume_mounts":[{"name":"ws","mount_path":"/data/workspace","read_only":%s}]}}}}' "$1" "$2" "$2"; }

try_sb() { # try_sb <描述> <pvc> <ro>
  local label=$1 pvc=$2 ro=$3
  local out; out=$(A --workspace poc-shared sandbox create --name "admit-$RANDOM" \
      --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
      --driver-config-json "$(DC "$pvc" "$ro")" -- sleep 5 2>&1)
  if grep -qiE "not admitted|admission" <<<"$out"; then
    printf '   ✓ %-46s 被 resource admission 拒绝\n' "$label"
    grep -iE "not admitted.*" <<<"$out" | head -1 | cut -c1-150 | sed 's/^/       /'
  elif grep -qiE "created|✓|Running" <<<"$out"; then
    printf '   ✓ %-46s 允许\n' "$label"
  else
    printf '   ? %-46s 结果需要看原文\n' "$label"
    echo "$out" | head -3 | cut -c1-160 | sed 's/^/       /'
  fi
}

echo
echo "### 2. SEC-14: 用未批准的 PVC 建 sandbox"
try_sb "无授权标签的 PVC (unapproved-workspace)" unapproved-workspace false
echo "### 3. 标签在但 workspace 不匹配(跨 workspace 借用)"
try_sb "workspace 标签值不对 (other-workspace)" other-workspace false
echo "### 4. 正例: 标签匹配的 PVC"
try_sb "匹配当前 workspace 的 PVC" shared-workspace false

echo
echo "### 5. 清理并留下真正要用的那个"
A --workspace poc-shared sandbox list 2>&1 | grep -E "^admit-" | awk '{print $1}' | while read -r n; do
  A --workspace poc-shared sandbox delete "$n" >/dev/null 2>&1
done
kubectl --context $CTX -n $NS delete pvc unapproved-workspace other-workspace --ignore-not-found >/dev/null 2>&1
sleep 5
kubectl --context $CTX -n $NS get pvc --no-headers 2>/dev/null | awk '{print "   剩余 PVC: "$1" "$2}'
echo "   ⚠ 注意 default workspace: OpenShell 每个 gateway 自带一个名为 default 的 workspace。"
echo "     POC2 §5.2 里的 workspace 名是 poc-code-review；本 POC 用 poc-shared，"
echo "     必须和 PVC 标签、sandbox create --workspace 三处一致，否则会被拒绝。"
