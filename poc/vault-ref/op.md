终端 A(保持开着):
kubectl --context k8s-221 -n openshell port-forward pod/openshell-0 18443:8080

终端 B:



# 0. 重跑时先清旧资源(首次可跳过)
openshell --gateway k8s-221 --workspace tenant-b-runtime sandbox delete refdemo
openshell --gateway k8s-221 --workspace tenant-b-runtime provider delete corp-ref
openshell --gateway k8s-221 --workspace tenant-b-runtime profile delete vaultprobe

# 1. 确认 profile 在(应列出 vaultprobe)
cat > /tmp/vaultprobe-profile.yaml <<'EOF'
id: vaultprobe
display_name: Vault prefix probe
description: Minimal provider for Vault credential driver experiments
category: other
credentials:
  - name: api_token
    description: API token stored server-side in Vault
    env_vars: [VAULTPROBE_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization
    query_param: ""
endpoints: []
binaries: []
inference_capable: false
discovery:
  credentials: [api_token]
source: user
scope: workspace
EOF

openshell --gateway k8s-221 --workspace tenant-b-runtime provider profile import \
  --file /tmp/vaultprobe-profile.yaml

## 确认(应列出 vaultprobe)
openshell --gateway k8s-221 --workspace tenant-b-runtime provider profile list

# 2. Vault 设值(模拟外部发布系统)
kubectl --context k8s-221 -n vault-demo exec -it deploy/vault -- sh -c \
  'VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault kv put secret/myapp/token value=ref-demo-v1'

# 3. 创建只读引用 provider
openshell --gateway k8s-221 --workspace tenant-b-runtime provider create \
  --name corp-ref --type vaultprobe \
  --credential VAULTPROBE_TOKEN=vault://secret/myapp/token#value

# 4. 看引用(应显示 VAULTPROBE_TOKEN=vault://secret/myapp/token#value)
openshell --gateway k8s-221 --workspace tenant-b-runtime provider get corp-ref

# 5. 写策略文件
cat > /tmp/ref-policy.yaml <<'EOF'
version: 1
network_policies:
  ref_echo:
    endpoints:
      - host: vault-echo.openshell.svc.cluster.local
        port: 80
        protocol: rest
        enforcement: enforce
        access: full
        credential_binding:
          provider: corp-ref
    binaries:
      - path: /usr/bin/wget
EOF

# 6. 创建沙箱(等它 provisioning 完成)
openshell --gateway k8s-221 --workspace tenant-b-runtime sandbox create \
  --name refdemo --provider corp-ref --policy /tmp/ref-policy.yaml \
  --from nvcr.io/nvidia/base/ubuntu:24.04 --no-tty --detach -- sleep 900

# 7. 验证注入 → 预期 AUTH=[Bearer ref-demo-v1]
openshell --gateway k8s-221 --workspace tenant-b-runtime sandbox exec refdemo --no-tty -- sh -c \
  'echo "ENV=${VAULTPROBE_TOKEN:-<not-injected>}"; wget -qO- --header="Authorization: Bearer ${VAULTPROBE_TOKEN}" http://vault-echo.openshell.svc.cluster.local/'

# 8. 外部轮换
kubectl --context k8s-221 -n vault-demo exec -it deploy/vault -- sh -c \
  'VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault kv put secret/myapp/token value=ref-demo-v2'

# 9. 等一个轮询周期,再验证 → 预期 AUTH=[Bearer ref-demo-v2]
sleep 15
openshell --gateway k8s-221 --workspace tenant-b-runtime sandbox exec refdemo --no-tty -- sh -c \
  'wget -qO- --header="Authorization: Bearer ${VAULTPROBE_TOKEN}" http://vault-echo.openshell.svc.cluster.local/'

# 10. 删 provider,确认外部密钥完好 → 预期仍输出 ref-demo-v2
openshell --gateway k8s-221 --workspace tenant-b-runtime sandbox delete refdemo
openshell --gateway k8s-221 --workspace tenant-b-runtime provider delete corp-ref
kubectl --context k8s-221 -n vault-demo exec -it deploy/vault -- sh -c \
  'VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault kv get -field=value secret/myapp/token'