#!/usr/bin/env bash
# 数据库管理密码的权威来源 = Vault KV secret/data/tenant-a/db-admin。
# 幂等：已有则复用；没有则生成。服务端 Secret 从 Vault 同步（平台侧副本），
# 然后部署 DB、等 Ready、输出 ClusterIP（sandbox 内 DNS 不通，策略用 IP 字面量）。
set -euo pipefail
CTX=kind-agent-runtime-poc
NS=tenant-a-runtime
D="$(cd "$(dirname "$0")" && pwd)"
VT="kubectl --context $CTX -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token"

if $VT vault kv get secret/tenant-a/db-admin >/dev/null 2>&1; then
  PW=$($VT vault kv get -field=password secret/tenant-a/db-admin)
  echo "复用 Vault 中已有的 db-admin 密码"
else
  PW=$(openssl rand -hex 12)
  $VT vault kv put secret/tenant-a/db-admin username=postgres password="$PW" >/dev/null
  echo "已生成 db-admin 密码并存入 Vault（secret/tenant-a/db-admin）"
fi

sed "s|__DB_PW__|$PW|" "$D/00-db.yaml" | kubectl --context $CTX apply -f - >/dev/null
kubectl --context $CTX -n $NS wait --for=condition=Available deployment/da-db --timeout=180s
IP=$(kubectl --context $CTX -n $NS get svc da-db -o jsonpath='{.spec.clusterIP}')
echo "DB_IP=$IP"