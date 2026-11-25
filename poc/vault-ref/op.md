
kubectl --context k8s-221 -n openshell port-forward pod/openshell-0 18443:8080

# ① Vault 设值(模拟外部发布系统;Vault 在集群内,经 kubectl exec)
kubectl --context k8s-221 -n vault-demo exec -it deploy/vault -- sh -c \
  'VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault kv put secret/myapp/token value=ref-demo-v1'

# ② 创建只读引用 provider(不存值)
openshell --gateway k8s-221 --workspace tenant-b-runtime provider create \
  --name corp-ref --type vaultprobe \
  --credential VAULTPROBE_TOKEN=vault://secret/myapp/token#value

# ③ 凭据绑定策略
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

# ④ 创建沙箱
openshell --gateway k8s-221 --workspace tenant-b-runtime sandbox create \
  --name refdemo --provider corp-ref --policy /tmp/ref-policy.yaml \
  --from nvcr.io/nvidia/base/ubuntu:24.04 --no-tty --detach -- sleep 900

# ⑤ 沙箱内验证注入
openshell --gateway k8s-221 --workspace tenant-b-runtime sandbox exec refdemo --no-tty -- sh -c \
  'wget -qO- --header="Authorization: Bearer ${VAULTPROBE_TOKEN}" http://vault-echo.openshell.svc.cluster.local/'
# 预期:AUTH=[Bearer ref-demo-v1]

# ⑥ 轮换:重跑 ① 改 value=ref-demo-v2,~10s 后重跑 ⑤ → AUTH=[Bearer ref-demo-v2]