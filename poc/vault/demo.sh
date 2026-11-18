#!/usr/bin/env bash
# OpenShell 0.1.7 挂载验证 · 逐拍手工 demo
#
# 在 192.168.5.190 上跑：
#   bash /root/poc2/vault/demo.sh          # 交互模式：每拍回车继续（适合录屏）
#   FAST=1 bash /root/poc2/vault/demo.sh   # 连跑：无人值守回归
#
# 前置（README §5 步骤 0，装好一次即可）：
#   helm install vault + 10-vault-config.sh + 15-vault-renderer-role.sh
# 本脚本自带：port-forward 自检、Assign 应用、渲染器重跑、sandbox 重建。
#
# 每一拍都给出"证明什么"，判定用正向/负向对照，不靠退出码自证：
#   第 1 拍  Vault+injector 本身健康（普通 Pod，沙箱外）
#   第 2 拍  Vault 密钥经 边界外渲染→PVC→挂载 进 sandbox（策略放行）
#   第 3 拍  负对照：策略不放行 → Permission denied（Landlock，非 Unix 权限）
#   第 4 拍  ConfigMap 直挂（准入标签 + Assign）
#   第 5 拍  K8s Secret 直挂（同款）
#   第 6 拍  sandbox 内无 SA token（capability-free 隔离保住）
#   第 7 拍  轮转：改 KV → 重渲染 → 运行中 sandbox 立即读到新值
set -uo pipefail

CTX=kind-agent-runtime-poc
C=/root/poc2/vendor/openshell-cli-0.1.7/openshell
G="-g poc2-a --workspace poc-shared"
NS=tenant-a-runtime
D=/root/poc2/vault
K="kubectl --context $CTX"
FAST=${FAST:-0}
FAIL=0
ROT_MARKER="ROTATED-$(date +%s)"

pause() { [ "$FAST" = "1" ] || read -rp "── 回车继续 ── " _; }
step()  { echo; echo "════════ 第 $1 拍：$2 ════════"; echo "证明：$3"; }
# check <名称> <期望子串> <实际输出>
check() {
  if printf '%s' "$3" | grep -qF "$2"; then
    echo "✅ $1"
  else
    echo "❌ $1（期望含 [$2]，实际：$(printf '%s' "$3" | head -2)）"; FAIL=1
  fi
}
sb_delete() { # 删旧 demo sandbox（幂等；报错不吞，打出来）
  local out
  out=$($C $G sandbox delete "$1" 2>&1)
  case "$out" in *"✓"*|*"not found"*|*"No sandbox"*) ;; *) echo "  (delete $1: $out)";; esac
}
sb_wait_gone() {
  for _ in $(seq 1 20); do
    $C $G sandbox list 2>/dev/null | grep -q "$1" || return 0
    sleep 2
  done
  echo "  ⚠ sandbox $1 仍未消失，继续（可能撞名字）"
}
sb_create() { # name [policy]
  local pol=()
  [ $# -ge 2 ] && pol=(--policy "$2")
  $C $G sandbox create --name "$1" --from alpine:latest \
    --cpu 50m --memory 64Mi --detach --restart-policy never "${pol[@]}" 2>&1 | tail -2
  sleep 3
}
sb_cat() { # sandbox path —— 走 openshell exec（策略强制通道）
  $C $G sandbox exec "$1" -- cat "$2" 2>&1
}

# 清场入口（独立执行，不跑 demo）
if [ "${1:-}" = "--cleanup" ]; then
  for s in v-sec v-nopol v-cm v-ksec; do
    out=$($C $G sandbox delete "$s" 2>&1); echo "  $s: $out"
  done
  $K -n $NS delete pod vault-inject-control --ignore-not-found
  echo "已清场（Vault/Assign/PVC 保留，供下一轮）"
  exit 0
fi

echo "═══ 第 0 拍：开演前自检 ═══"
# Vault 活着且数据在（dev 模式 Pod 重建会丢数据）
if ! $K -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token \
     vault kv get secret/tenant-a/database >/dev/null 2>&1; then
  echo "❌ Vault KV 不可读。dev 模式数据可能丢了，先恢复："
  echo "   bash $D/10-vault-config.sh && bash $D/15-vault-renderer-role.sh"
  exit 1
fi
echo "✅ Vault KV 可读"
# gateway 通道：查监听，不查 CLI（避免用待测通道自证）
if ! ss -ltn | grep -q ":18441 "; then
  setsid nohup $K -n tenant-a-gateway port-forward svc/os-a-openshell \
    18441:8080 --address 127.0.0.1 >/tmp/pf-os-a.log 2>&1 &
  sleep 4
fi
ss -ltn | grep -q ":18441 " || { echo "❌ port-forward 没起来：$(tail -2 /tmp/pf-os-a.log)"; exit 1; }
$C $G whoami >/dev/null 2>&1 || { echo "❌ gateway whoami 失败（mTLS profile poc2-a？）"; exit 1; }
echo "✅ gateway 通道（poc2-a / poc-shared）"
# 挂载 glue + 渲染器（幂等）
$K apply -f "$D/110-gk-pvc-mount.yaml" -f "$D/120-gk-cm-mount.yaml" -f "$D/130-gk-ksec-mount.yaml" >/dev/null
$K apply -f "$D/30-configmap-secret.yaml" >/dev/null
$K -n $NS delete job vault-render --ignore-not-found >/dev/null
$K apply -f "$D/100-renderer.yaml" >/dev/null
$K -n $NS wait --for=condition=complete job/vault-render --timeout=180s >/dev/null \
  || { echo "❌ 渲染器 Job 未完成：$($K -n $NS logs job/vault-render --tail=3 2>&1)"; exit 1; }
echo "✅ Assign×6 + 渲染器 Job（PVC 文件已就位）"
pause

step 1 "正向对照：Vault+injector 在普通 Pod 上工作" \
     "Vault 侧健康；后面 sandbox 的任何失败都归因于 OpenShell 边界，不是 Vault"
$K -n $NS delete pod vault-inject-control --wait=true --timeout=90s 2>/dev/null
$K apply -f "$D/20-positive-control-pod.yaml" >/dev/null
$K -n $NS wait --for=condition=Ready pod/vault-inject-control --timeout=150s >/dev/null
OUT=$($K -n $NS exec vault-inject-control -c agent -- cat /vault/secrets/database-url 2>&1)
echo "  /vault/secrets/database-url = $OUT"
check "injector 渲染密钥" "postgres://" "$OUT"
pause

step 2 "Vault 密钥进 sandbox（边界外渲染 → 标签 PVC → Assign 挂载）" \
     "0.1.7 唯一可行的 Vault 文件路径；策略显式放行 /vault/secrets"
sb_delete v-sec; sb_wait_gone v-sec
sb_create v-sec "$D/policy-vault-secrets.yaml"
OUT=$(sb_cat v-sec /vault/secrets/database-url)
echo "  v-sec:/vault/secrets/database-url = $OUT"
check "sandbox 读到 Vault 密钥" "postgres://" "$OUT"
OUT=$(sb_cat v-sec /vault/secrets/api-token)
check "sandbox 读到 api-token" "demo-token-tenant-a" "$OUT"
pause

step 3 "负对照：同一个 PVC，策略不放行" \
     "拒绝来自 Landlock 策略基线（不含 /vault），与 Unix 权限无关"
sb_delete v-nopol; sb_wait_gone v-nopol
sb_create v-nopol
OUT=$(sb_cat v-nopol /vault/secrets/database-url)
echo "  v-nopol: $OUT"
check "策略外路径被拒" "Permission denied" "$OUT"
pause

step 4 "ConfigMap 直挂" \
     "准入标签 + Assign 补卷即可；/etc 在基线里，policy 不用改"
sb_delete v-cm; sb_wait_gone v-cm
sb_create v-cm
OUT=$(sb_cat v-cm /etc/agent-config/app.yaml)
echo "  v-cm:/etc/agent-config/app.yaml:"; printf '%s\n' "$OUT" | sed 's/^/    /'
check "ConfigMap 内容可读" "tenant: tenant-a" "$OUT"
pause

step 5 "K8s Secret 直挂" \
     "与 ConfigMap 同款机制（静态副本路线；要轮转/不落 etcd 用第 2 拍的 Vault 路线）"
sb_delete v-ksec; sb_wait_gone v-ksec
sb_create v-ksec
OUT=$(sb_cat v-ksec /etc/agent-secrets/database-url)
echo "  v-ksec:/etc/agent-secrets/database-url = $OUT"
check "Secret 内容可读" "static-copy" "$OUT"
pause

step 6 "隔离不变量：sandbox 里没有 SA token" \
     "capability-free isolation 保住 —— 这正是 injector 进不来的原因"
OUT=$($C $G sandbox exec v-sec -- sh -c \
  'ls /var/run/secrets/kubernetes.io/serviceaccount/token 2>&1 || echo NO-SA-TOKEN' 2>&1)
echo "  v-sec: $OUT"
check "无 SA token" "NO-SA-TOKEN" "$OUT"
pause

step 7 "轮转：不重启 sandbox" \
     "改 KV → 重跑渲染器 → 目录挂载（非 subPath）即时传播"
$K -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token \
  vault kv put secret/tenant-a/database \
  url="postgres://demo-app:${ROT_MARKER}@db.tenant-a.svc:5432/app" >/dev/null
$K -n $NS delete job vault-render >/dev/null
$K apply -f "$D/100-renderer.yaml" >/dev/null
$K -n $NS wait --for=condition=complete job/vault-render --timeout=120s >/dev/null
OUT=$(sb_cat v-sec /vault/secrets/database-url)
echo "  v-sec（运行中）= $OUT"
check "轮转即时可见（marker $ROT_MARKER）" "$ROT_MARKER" "$OUT"

echo
if [ "$FAIL" = "0" ]; then
  echo "════ 全部通过（7/7）。清场：bash $0 --cleanup ════"
else
  echo "════ 有失败项，见上方 ❌ ════"
fi

exit "$FAIL"