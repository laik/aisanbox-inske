# 0. 连接 gateway(保持运行)
kubectl -n openshell port-forward pod/openshell-0 18443:8080 &

# 1. 创建 profile(最小 endpointless)
cat > /tmp/vp.yaml <<'EOF'
id: vp
display_name: Vault probe
category: other
credentials:
  - name: token
    env_vars: [VP_TOKEN]
    auth_style: bearer
    header_name: authorization
endpoints: []
EOF
openshell profile import -f /tmp/vp.yaml

# 2. 创建 provider(值由 gateway 存入 Vault,自动走 /v1/bu-a/ 前缀)
openshell provider create --name vp --type vp --credential VP_TOKEN=sk-test-123

# 3. 创建 sandbox 引用 provider
openshell sandbox create --name s1 --provider vp \
  --from nvcr.io/nvidia/base/ubuntu:24.04 -- sleep 600

注意:endpointless profile 要让值真正注入出站请求,sandbox 还必须带绑定策略,否则 env 里连占位符都没有。第 3 步加 --policy:

cat > /tmp/pol.yaml <<'EOF'
version: 1
network_policies:
  echo:
    endpoints:
      - host: <你的目标host>
        port: 80
        protocol: rest
        enforcement: enforce
        access: full
        credential_binding: { provider: vp }
    binaries: [{ path: /usr/bin/wget }]
EOF
openshell sandbox create --name s1 --provider vp --policy /tmp/pol.yaml \
  --from nvcr.io/nvidia/base/ubuntu:24.04 -- sleep 600

沙箱内验证:wget -qO- --header="Authorization: Bearer $VP_TOKEN" http://<目标host>/ —— 进程拿到的 $VP_TOKEN 是占位符,代理替换成 Vault 真实值。