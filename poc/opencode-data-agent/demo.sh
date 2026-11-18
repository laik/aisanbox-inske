#!/usr/bin/env bash
# opencode 数据 Agent · OpenShell 全流程 demo（0.1.7 实测版）
#
# 在 192.168.5.190 上：
#   bash /root/poc2/opencode-data-agent/demo.sh          # 交互，每拍回车（录屏）
#   FAST=1 bash /root/poc2/opencode-data-agent/demo.sh   # 连跑回归
#   bash demo.sh --cleanup                               # 清场
#
# 故事：一个数据 Agent 跑在 OpenShell sandbox 里 ——
#   临时配置在 ConfigMap，管理密码在 Vault（渲染进 PVC），静态报表 token
#   在 K8s Secret，查询结果写共享 PVC；模型凭据走 OpenShell profile/provider
#   （sandbox 里只有占位 key）。确定性验证不依赖模型输出。
#
# 前置（一次）：../vault 的 Vault 安装 + 10/15 脚本；bash build-image.sh
set -uo pipefail
CTX=kind-agent-runtime-poc
C=/root/poc2/vendor/openshell-cli-0.1.7/openshell
G="-g poc2-a --workspace poc-shared"
NS=tenant-a-runtime
K="kubectl --context $CTX"
D="$(cd "$(dirname "$0")" && pwd)"
FAST=${FAST:-0}
FAIL=0
DB_IP=""

pause() { [ "$FAST" = "1" ] || read -rp "── 回车继续 ── " _; }
step()  { echo; echo "════════ 第 $1 拍：$2 ════════"; echo "证明：$3"; }
check() {
  if printf '%s' "$3" | grep -qF "$2"; then echo "✅ $1"
  else echo "❌ $1（期望含 [$2]，实际：$(printf '%s' "$3" | head -2)）"; FAIL=1; fi
}
sb_delete() {
  local out; out=$($C $G sandbox delete "$1" 2>&1)
  case "$out" in *"✓"*|*"not found"*|*"No sandbox"*) ;; *) echo "  (delete $1: $out)";; esac
}
sb_wait_gone() {
  for _ in $(seq 1 20); do $C $G sandbox list 2>/dev/null | grep -q "$1" || return 0; sleep 2; done
}
da_run() { $C $G sandbox exec da-agent -- sh /usr/local/bin/da-agent.sh 2>&1; }

if [ "${1:-}" = "--cleanup" ]; then
  sb_delete da-agent
  $K delete -f "$D/30-assigns.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'
  $K -n $NS delete job da-render cm da-config secret da-report-token pvc da-output \
    deploy da-db svc da-db cm da-db-init secret da-db-server --ignore-not-found 2>&1 | sed 's/^/  /'
  $C $G provider delete da-model 2>&1 | sed 's/^/  /'
  $C $G profile delete da-model 2>&1 | sed 's/^/  /'
  echo "已清场（Vault KV 与镜像保留）"
  exit 0
fi

echo "═══ 第 0 拍：自检 ═══"
$K -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token vault status >/dev/null 2>&1 \
  || { echo "❌ Vault 不在（先装 ../vault，见其 README §5）"; exit 1; }
if ! ss -ltn | grep -q ":18441 "; then
  setsid nohup $K -n tenant-a-gateway port-forward svc/os-a-openshell \
    18441:8080 --address 127.0.0.1 >/tmp/pf-os-a.log 2>&1 &
  sleep 4
fi
$C $G whoami >/dev/null 2>&1 || { echo "❌ gateway 通道不通"; exit 1; }
IMG_OK=0
for _ in 1 2 3; do
  if docker exec agent-runtime-poc-control-plane crictl images 2>/dev/null | grep -q opencode-agent; then
    IMG_OK=1; break
  fi
  sleep 2
done
[ "$IMG_OK" = "1" ] || { echo "❌ kind 里没有 opencode-agent:poc，先跑 bash $D/build-image.sh"; exit 1; }
echo "✅ Vault / gateway / 镜像"
echo "  配额：$(kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 \
  -o jsonpath='services {.status.used.count/services}/{.spec.hard.count/services}  pvc {.status.used.persistentvolumeclaims}/{.spec.hard.persistentvolumeclaims}')"
# 每个 sandbox 自带一个 workspace PVC；配额满时创建会卡在 Provisioning
# （实测：PVC 9/9 时 da-agent 的 workspace PVC 建不出来）。提前拦下。
PU=$(kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 -o jsonpath='{.status.used.persistentvolumeclaims}')
PH=$(kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 -o jsonpath='{.spec.hard.persistentvolumeclaims}')
# 本 demo 会先删后建 da-agent，它已占的 workspace PVC 会被释放，算可用
if kubectl --context $CTX -n $NS get pvc workspace-poc-shared--da-agent >/dev/null 2>&1; then
  PU=$((PU-1))
fi
if [ "$PU" -ge "$PH" ]; then
  echo "❌ PVC 配额已满（$PU/$PH）：每个 sandbox 占一个 workspace PVC。"
  echo "   先删一个不用的 sandbox（如 vault demo 的 v-nopol）再跑。"
  exit 1
fi
pause

step 1 "部署演示数据库，管理密码存进 Vault" \
     "密码权威来源是 Vault；服务端 Secret 只是平台侧同步副本"
OUT=$(bash "$D/10-vault-db-admin.sh" 2>&1); echo "$OUT" | sed 's/^/  /'
DB_IP=$(printf '%s' "$OUT" | sed -n 's/^DB_IP=//p')
[ -n "$DB_IP" ] || { echo "❌ 拿不到 DB ClusterIP"; exit 1; }
check "DB 就绪" "DB_IP=" "$OUT"
pause

step 2 "ConfigMap(临时配置) + Secret(静态token) + 输出PVC + Vault渲染Job" \
     "三类挂载源就位；管理密码渲染进 PVC，sandbox 侧不碰 Vault"
sed "s/__DB_IP__/$DB_IP/" "$D/20-config.yaml" > /tmp/da-20.yaml
$K apply -f /tmp/da-20.yaml >/dev/null
$K apply -f "$D/30-assigns.yaml" >/dev/null
$K -n $NS wait --for=condition=complete job/da-render --timeout=180s >/dev/null \
  || { echo "❌ 渲染失败：$($K -n $NS logs job/da-render --tail=3 2>&1)"; exit 1; }
echo "  ✅ da-render 完成（db-admin 文件已进 PVC）"
pause

step 3 "openshell profile import + provider create" \
     "平台声明'哪个二进制能去哪个端点'；真实 key 进 gateway 凭据存储，不进 sandbox"
KEY=$(python3 -c 'import json;print(json.load(open("/root/Strata/strata-iq3_s.json"))["api_key"])')
# 先删旧 sandbox：provider 被 sandbox 引用时删不掉，profile 连带删不掉，
# 重导会报 "provider already exists"（实测）。顺序不能反。
sb_delete da-agent; sb_wait_gone da-agent
$C $G provider delete da-model >/dev/null 2>&1
$C $G profile delete da-model >/dev/null 2>&1
OUT=$($C $G profile import --file "$D/providers/da-model.yaml" 2>&1); echo "  $OUT" | tail -1
# 实测：--credential 的 KEY 是 **env 变量名**（OPENAI_API_KEY），不是
# profile 里的 credential name（api_key）—— 后者报 "not declared by profile"
OUT=$($C $G provider create --name da-model --type da-model --credential "OPENAI_API_KEY=$KEY" 2>&1)
echo "  $OUT" | tail -1
check "provider 建成" "da-model" "$($C $G provider list 2>&1)"
pause

step 4 "openshell sandbox create：挂 provider + 自定义 policy" \
     "一个命令把凭据代理、文件挂载、网络/文件系统边界全部装好"
sed "s/__DB_IP__/$DB_IP/" "$D/da-policy.yaml.template" > /tmp/da-policy.yaml
sb_delete da-agent; sb_wait_gone da-agent
# workspace PVC 删除是异步的：等它真消失，否则新 sandbox 撞配额/撞名字
for _ in $(seq 1 30); do
  $K -n $NS get pvc workspace-poc-shared--da-agent >/dev/null 2>&1 || break
  sleep 2
done
$C $G sandbox create --name da-agent --from opencode-agent:poc \
  --cpu 500m --memory 1Gi --detach --restart-policy never \
  --policy /tmp/da-policy.yaml --provider da-model -- sh -c "sleep 3600" 2>&1 | tail -2
sleep 3
pause

step 5 "sandbox 里看三类文件" \
     "ConfigMap/Secret/PVC 各就各位；管理密码是 Vault 渲染的，不是 K8s Secret"
OUT=$($C $G sandbox exec da-agent -- cat /etc/da-config/config.env 2>&1)
echo "  /etc/da-config/config.env:"; printf '%s\n' "$OUT" | sed 's/^/    /'
check "临时配置可读" "TARGET_TABLE=sales" "$OUT"
OUT=$($C $G sandbox exec da-agent -- cat /etc/da-secret/report-token 2>&1)
check "静态 Secret 可读" "demo-static-report-token" "$OUT"
OUT=$($C $G sandbox exec da-agent -- sh -c 'ls /vault/da-secrets/ && echo "pw-length=$(wc -c < /vault/da-secrets/db-admin-password)"' 2>&1)
echo "  /vault/da-secrets: $OUT"
check "管理密码文件就位" "db-admin-password" "$OUT"
pause

step 6 "数据 Agent 干活：读配置 → 用管理密码查库 → 结果写共享 PVC" \
     "确定性验证：行数/内容可复现，不依赖模型"
OUT=$(da_run); printf '%s\n' "$OUT" | sed 's/^/  /'
check "查询成功（limit=5）" "limit=5" "$OUT"
check "结果 5 行" "(5 rows)" "$OUT"
pause

step 7 "模型凭据：sandbox 里只有占位 key" \
     "provider 机制：真实 key 在 gateway，supervisor 代理时替换"
OUT=$($C $G sandbox exec da-agent -- sh -c 'echo "OPENAI_API_KEY=$OPENAI_API_KEY"' 2>&1)
echo "  $OUT"
if printf '%s' "$OUT" | grep -q "Error"; then
  echo "❌ exec 失败，无法判定"; FAIL=1
elif printf '%s' "$OUT" | grep -qF "$KEY"; then
  echo "❌ 真实 key 泄露进了 sandbox！"; FAIL=1
elif printf '%s' "$OUT" | grep -q "OPENAI_API_KEY=."; then
  echo "✅ sandbox 内是占位 key，不是真实 key"
else
  echo "❌ OPENAI_API_KEY 未注入（provider 没挂上？）"; FAIL=1
fi
pause

step 8 "opencode 经 provider 代理调模型（软验证）" \
     "平台侧确定的是通道与凭据替换；模型输出本身不确定（本地模型可能返回空）"
OUT=$($C $G sandbox exec da-agent -- sh /usr/local/bin/da-ai.sh 2>&1)
printf '%s\n' "$OUT" | tail -6 | sed 's/^/  /'
echo "  （只观察字节数，不拿模型内容当结论）"
pause

step 9 "轮转管理密码：Vault 改密 → 改库 → 重渲染 → 不重启 sandbox" \
     "密码文件即时更新，agent 下次运行自动用新密码"
NEWPW=$(openssl rand -hex 12)
$K -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token \
  vault kv put secret/tenant-a/db-admin username=postgres password="$NEWPW" >/dev/null
$K -n $NS exec deploy/da-db -- sh -c "psql -U postgres -d appdb -c \"ALTER USER postgres PASSWORD '$NEWPW'\"" >/dev/null 2>&1
$K -n $NS delete job da-render >/dev/null
sed "s/__DB_IP__/$DB_IP/" "$D/20-config.yaml" > /tmp/da-20.yaml
$K apply -f /tmp/da-20.yaml >/dev/null
$K -n $NS wait --for=condition=complete job/da-render --timeout=120s >/dev/null
OUT=$(da_run); printf '%s\n' "$OUT" | tail -3 | sed 's/^/  /'
check "新密码查库成功" "(5 rows)" "$OUT"
pause

step 10 "改临时配置：ConfigMap patch → 运行中 sandbox 自动同步" \
     "kubelet 同步目录挂载的 CM（~60s）；agent 每次运行重读，无需重启"
$K -n $NS patch cm da-config --type merge \
  -p "{\"data\":{\"config.env\":\"DB_HOST=$DB_IP\nDB_PORT=5432\nDB_NAME=appdb\nTARGET_TABLE=sales\nROW_LIMIT=3\n\"}}" >/dev/null
echo "  ROW_LIMIT 5→3，等 kubelet 同步（70s）..."
sleep 70
OUT=$(da_run); printf '%s\n' "$OUT" | sed 's/^/  /'
check "新配置生效（limit=3）" "limit=3" "$OUT"
check "结果 3 行" "(3 rows)" "$OUT"

echo
if [ "$FAIL" = "0" ]; then echo "════ 全部通过。清场：bash $0 --cleanup ════"
else echo "════ 有失败项，见上方 ❌ ════"; fi
exit "$FAIL"