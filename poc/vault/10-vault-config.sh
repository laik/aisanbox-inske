#!/usr/bin/env bash
# Vault POC 配置：kubernetes auth + 租户 policy/role + 种子 KV。
# 前置：helm install vault（values-vault-poc.yaml，dev 模式）已 Ready。
# 在 192.168.5.190 上执行：bash /root/poc2/vault/10-vault-config.sh
#
# 绑定对象来自实测（不是假设）：os-a gateway 创建的 workload Pod 使用
# SA=os-a-openshell-sandbox、namespace=tenant-a-runtime。
# 注意：该 SA 是 **gateway 级** 的，os-a 的所有 sandbox 共用 —— 所以 Vault
# role 的隔离粒度是"每租户 gateway"，不是"每 sandbox"。
set -euo pipefail
CTX=kind-agent-runtime-poc
VT="kubectl --context $CTX -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token"

echo "== 0. injector SA 的 TokenReview 权限 =="
# 实测坑（vault chart 0.3x / vault 2.0.4）：chart 只给 vault-agent-injector
# 绑了 webhook 权限，auth-delegator 绑的是 server 的 SA（vault）。
# 而 token_reviewer_jwt 用的是 injector 的 SA token → login 403。
# 报错藏在 debug 日志里，审计日志只显示 "permission denied"。
kubectl --context $CTX create clusterrolebinding vault-agent-injector-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault-agent-injector 2>&1 | grep -v "already exists" || true

echo "== 1. kubernetes auth =="
$VT vault auth enable kubernetes 2>&1 | grep -v "already in use" || true

# injector 的 SA token 用于 TokenReview（chart 已建 system:auth-delegator 绑定）
REVIEWER_JWT=$(kubectl --context $CTX -n vault create token vault-agent-injector --duration=8760h)
$VT vault write auth/kubernetes/config \
  kubernetes_host="https://10.96.0.1:443" \
  token_reviewer_jwt="$REVIEWER_JWT"

echo "== 2. tenant-a policy（只读自己的 KV 子树）=="
$VT sh -c 'VAULT_TOKEN=poc-root-token vault policy write tenant-a-read - <<EOF
path "secret/data/tenant-a/*" { capabilities = ["read"] }
path "secret/metadata/tenant-a/*" { capabilities = ["list", "read"] }
EOF'

echo "== 3. role：绑定实测 SA + namespace =="
$VT vault write auth/kubernetes/role/tenant-a-agent \
  bound_service_account_names=os-a-openshell-sandbox \
  bound_service_account_namespaces=tenant-a-runtime \
  policies=tenant-a-read \
  token_ttl=1h \
  audience="https://kubernetes.default.svc.cluster.local"
# audience 实测链（vault 2.0.4 / vault-k8s 2.x）：
# 1) injector 不自建投影 token，直接用 Pod 标准路径的 SA token
#    （token_path=/var/run/secrets/kubernetes.io/serviceaccount/token）。
# 2) 该 token 的 aud 是 API server 默认值（create token 不带 --audience 解 JWT 确认）。
# 3) OpenShell workload Pod automount=false → injector 拒绝 Pod；
#    Kyverno 把 automount 翻回 true（60-kyverno-policy.yaml 方案 b），
#    所以 role audience 钉 API 默认值。换集群时先解 JWT 确认 aud 再写。

echo "== 4. 种子 KV（合成演示值，非真实凭据）=="
$VT vault kv put secret/tenant-a/database \
  url="postgres://demo-app:DEMO-ONLY-NOT-REAL@db.tenant-a.svc:5432/app"
$VT vault kv put secret/tenant-a/api \
  token="demo-token-tenant-a-12345"

echo "== 5. 自检 =="
$VT vault read auth/kubernetes/role/tenant-a-agent -format=json | head -20
$VT vault kv get secret/tenant-a/database
echo "DONE"