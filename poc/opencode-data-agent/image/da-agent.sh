#!/bin/sh
# 数据 Agent 的确定性部分（不依赖模型，可重复验证）：
#   临时配置(ConfigMap) + 管理密码(Vault→PVC) → psql 查库 → 结果写共享 PVC
# 每次运行都重读配置和密码文件 —— 所以轮转/改配置后无需重启 sandbox。
set -e
. /etc/da-config/config.env
PW=$(cat /vault/da-secrets/db-admin-password)
USER=$(cat /vault/da-secrets/db-admin-username)
OUT=/data/output/result-$(date +%s).csv
PGPASSWORD="$PW" psql -h "$DB_HOST" -p "$DB_PORT" -U "$USER" -d "$DB_NAME" -At -F',' \
  -c "SELECT region, amount FROM $TARGET_TABLE ORDER BY amount DESC LIMIT $ROW_LIMIT" > "$OUT"
echo "[da-agent] config: table=$TARGET_TABLE limit=$ROW_LIMIT db=$DB_HOST/$DB_NAME"
echo "[da-agent] wrote $OUT ($(wc -l < "$OUT") rows)"
cat "$OUT"