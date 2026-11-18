#!/usr/bin/env bash
# 渲染器专用 Vault role：绑定 SA vault-renderer（tenant-a-runtime），
# 与 sandbox 的 gateway SA 分开 —— 渲染器在沙箱边界外跑，持有自己的凭据。
set -euo pipefail
CTX=kind-agent-runtime-poc
VT="kubectl --context $CTX -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token"
$VT vault write auth/kubernetes/role/tenant-a-renderer \
  bound_service_account_names=vault-renderer \
  bound_service_account_namespaces=tenant-a-runtime \
  policies=tenant-a-read \
  token_ttl=15m \
  audience="https://kubernetes.default.svc.cluster.local"
echo DONE