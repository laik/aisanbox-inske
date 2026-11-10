#!/usr/bin/env bash
# POC3 §三 —— 部署**一台**走 OIDC 认证的 Gateway，两个 Workspace 共用它。
# 手工重现: bash poc/openshell3/60-gateway-oidc.sh
#
# 与 poc/phases/08-gateway.sh(POC2)的三处不同，都是有意为之:
#  1) 一台 Gateway、两个 Workspace —— 这样"看不到对方租户的资源"只能归因于 Workspace，
#     而不是"换了 Gateway/换了 namespace"。
#  2) 认证从 mTLS 客户端证书换成 OIDC JWT(server.oidc.*)。
#  3) ns 不属于任何 Capsule Tenant(不带 capsule.clastix.io/tenant，也不带
#     platform.example.com/tenant)—— 实测 Gatekeeper 的两个约束实例只匹配
#     platform.example.com/tenant=true 的 ns，所以这里不受它们影响。
#     这不是遗漏: K8s 侧隔离与 OpenShell 侧隔离必须**可分别归因**，否则 §四的
#     "两侧一致"就分不清是谁保证了它。
#
# ⚠ 顺序沿用 08 的实测结论: **先装 workspace chart(RBAC)，再装 gateway**。
#   反了的话 gateway CrashLoopBackOff，报错是
#     sandboxes.agents.x-k8s.io is forbidden: ... cannot list ... in the namespace
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
OS_VERSION=${OS_VERSION:-0.1.7}
GW_NS=poc3-gateway
RT_NS=poc3-runtime            # 两个 Workspace 的沙箱**共用**这一个 runtime ns
REL=p3
CLI=vendor/openshell-cli-0.1.7/openshell

# ---- 0. issuer 只从 kc-config 读，绝不在本文件硬编码 ----
ISSUER_PATH=$(kubectl --context $CTX -n identity get cm kc-config -o jsonpath='{.data.issuer_url}')
REALM=$(kubectl --context $CTX -n identity get cm kc-config -o jsonpath='{.data.realm}' 2>/dev/null)
REALM=${REALM:-aisanbox}
[ -n "$ISSUER_PATH" ] || { echo "✗ 读不到 identity/kc-config 的 issuer_url"; exit 1; }
ISSUER="$ISSUER_PATH/realms/$REALM"
echo "### 0. issuer(三处共用的同一个值): $ISSUER"

echo "### 1. namespace: 平台自有，不带任何租户标签"
kubectl --context $CTX create ns $GW_NS --dry-run=client -o yaml \
  | kubectl --context $CTX apply -f - >/dev/null
kubectl --context $CTX create ns $RT_NS --dry-run=client -o yaml \
  | python3 -c "
import sys,yaml
o=yaml.safe_load(sys.stdin)
o['metadata']['labels']={'app.kubernetes.io/part-of':'aisanbox-poc3','openshell.ai/sandbox-runtime':'true'}
print(yaml.safe_dump(o))" | kubectl --context $CTX apply -f - >/dev/null
echo "   标签(与租户 ns 对照):"
# ⚠ 这里**不用** custom-columns: 它带 `\.` 转义读不到 `capsule.clastix.io/tenant`
#   (实测三个 ns 全打印 <none>，包括真的有租户标签的 tenant-a-runtime —— 又是一次
#    "看着像没标签，其实是探针写错")。用 08 里验证过的 jsonpath 写法。
kubectl --context $CTX get ns $GW_NS $RT_NS tenant-a-runtime \
  -o "jsonpath={range .items[*]}{.metadata.name}{\" tenant=\"}{.metadata.labels.capsule\.clastix\.io/tenant}{\" gk-tenant=\"}{.metadata.labels.platform\.example\.com/tenant}{\"\n\"}{end}" | sed 's/^/   /'

echo "### 2. issuer 的 CA 必须是 **ConfigMap**(chart 的挂载条件写死在 _gateway-workload.tpl:131/195/306)"
# chart 注释: 'Name of a ConfigMap containing a CA certificate bundle (key: ca.crt)' ——
# 给 Secret 不生效，而且不报错，表现是 JWKS 拉取 TLS 失败。
kubectl --context $CTX -n $GW_NS create configmap oidc-issuer-ca \
  --from-file=ca.crt=identity/certs/issuer-ca.crt \
  --dry-run=client -o yaml | kubectl --context $CTX apply -f - >/dev/null
kubectl --context $CTX -n $GW_NS get cm oidc-issuer-ca -o jsonpath='{.data.ca\.crt}' | head -1 | sed 's/^/   cm\/oidc-issuer-ca: /'

echo "### 3. 先装 workspace chart(RBAC 要先到位)"
kubectl --context $CTX -n $RT_NS get sa ${REL}-openshell-sandbox >/dev/null 2>&1 \
  && echo "   已存在，跳过" || true
helm --kube-context $CTX upgrade --install "os-ws-p3" oci://ghcr.io/nvidia/openshell/openshell-workspace \
  --version "$OS_VERSION" --namespace $RT_NS \
  --set gateway.serviceAccount.name="${REL}-openshell" \
  --set gateway.serviceAccount.namespace="$GW_NS" \
  --set gateway.allowDriverConfig=true \
  --set sandboxServiceAccount.name="${REL}-openshell-sandbox" \
  --set networkPolicy.podSelector."app\\.kubernetes\\.io/instance"="$REL" \
  --timeout 3m --wait >/dev/null 2>&1
echo "   gateway SA 在共享 runtime ns 的权限:"
for verb in list create; do
  printf "   %-6s sandboxes: " $verb
  kubectl --context $CTX auth can-i $verb sandboxes.agents.x-k8s.io -n $RT_NS \
    --as=system:serviceaccount:$GW_NS:${REL}-openshell
done

echo "### 4. 装 Gateway(OIDC values 由脚本填 issuer，不硬编码)"
sed "s|__ISSUER__|$ISSUER|" openshell3/gateway-oidc-values.yaml > /tmp/gw-oidc-values.yaml
helm --kube-context $CTX upgrade --install "$REL" oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "$OS_VERSION" --namespace $GW_NS -f /tmp/gw-oidc-values.yaml \
  --set server.name="$GW_NS" --set server.sandboxNamespace="$RT_NS" \
  --set server.otlp.serviceName="$GW_NS" --timeout 8m --wait 2>&1 | tail -2 | sed 's/^/   /'

echo "### 5. 断言的是**跑着的东西**，不是 values 文件(values 写错键不报错，见 values.yaml 顶部 ⚠⚠)"
TOML=$(kubectl --context $CTX -n $GW_NS get cm -l app.kubernetes.io/name=openshell \
        -o 'jsonpath={.items[0].data.gateway\.toml}')
echo "$TOML" | awk '/^\[openshell.gateway.oidc\]/{f=1} f&&/^\[/&&!/oidc/{f=0} f' | sed 's/^/   /'
for kv in "issuer = \"$ISSUER\"" 'roles_claim = "groups"' 'admin_role = "os-admin"' 'user_role = "os-user"' 'audience = "openshell-cli"'; do
  printf "   %-40s " "$kv"
  echo "$TOML" | grep -qF "$kv" && echo "✓" || echo "✗ <== OIDC 没生效，后面所有用例都无意义"
done
printf "   %-40s " "没有 client_ca_path(mTLS 已关)"; echo "$TOML" | grep -q "client_ca_path" && echo "✗ 仍在要求客户端证书" || echo "✓"
printf "   %-40s " "没有 allow_unauthenticated_users=true"; echo "$TOML" | grep -q "allow_unauthenticated_users = true" && echo "✗ 隔离测试会全部假通过" || echo "✓"
# ⚠ issuer 的 CA **不会**出现在 gateway.toml 里，这不是漏配。chart 的注释
#   (templates/_gateway-workload.tpl:131)写得很明确: 它是给 rustls/reqwest 读的进程级
#   环境变量 `SSL_CERT_FILE`，"cannot be represented in the gateway TOML schema"。
#   所以正确的探针是 Pod 的 env + volumeMount，不是 TOML —— 按 TOML 查会得出
#   "没配 CA"这个**假结论**，而实际上 JWKS 是能拉通的。
kubectl --context $CTX -n $GW_NS get statefulset ${REL}-openshell \
  -o "jsonpath={range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}" \
  | grep -E "^SSL_CERT_FILE" | sed "s/^/   env   /"
kubectl --context $CTX -n $GW_NS get statefulset ${REL}-openshell \
  -o "jsonpath={range .spec.template.spec.containers[0].volumeMounts[*]}{.name}={.mountPath}{"\n"}{end}" \
  | grep -E "oidc-ca" | sed "s/^/   mount /"
printf "   容器内该文件是否**真的**可读(不只是声明出来的): "
kubectl --context $CTX -n $GW_NS exec ${REL}-openshell-0 -- sh -c 'head -1 "$SSL_CERT_FILE"' 2>&1 | head -1 | sed "s/^/   /"
echo "   沙箱落到的 namespace(必须是共享的那个):"
echo "$TOML" | grep -E "^ *namespace = |^ *workspace_mode = |client_tls_secret_name" | sed 's/^/   /'

echo "### 6. 平台步骤: 把 client-TLS bundle 复制到共享 runtime ns(POC2 §1c 同一条实测坑)"
kubectl --context $CTX -n $RT_NS get secret openshell-client-tls >/dev/null 2>&1 || \
kubectl --context $CTX -n $GW_NS get secret openshell-client-tls -o yaml \
  | python3 -c "
import sys,yaml,json
o=yaml.safe_load(sys.stdin)
print(json.dumps({'apiVersion':'v1','kind':'Secret','metadata':{'name':'openshell-client-tls','namespace':'$RT_NS'},'type':o['type'],'data':o['data']}))" \
  | kubectl --context $CTX apply -f - >/dev/null
kubectl --context $CTX -n $RT_NS get secret openshell-client-tls >/dev/null 2>&1 && echo "   已存在 ✓" || echo "   ✗ 缺失 —— supervisor 会卡 ContainerCreating"

echo "### 7. 注册到 CLI(OIDC 模式，与 POC2 的 --local mTLS 不同)"
kubectl --context $CTX -n $GW_NS get pod -l app.kubernetes.io/instance=$REL \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount | sed 's/^/   /'
pkill -f "port-forward svc/${REL}-openshell" >/dev/null 2>&1
kubectl --context $CTX -n $GW_NS port-forward svc/${REL}-openshell 18443:8080 >/tmp/pf-p3.log 2>&1 &
sleep 4
rm -rf "$HOME/.config/openshell/gateways/poc3"
# ⚠ 两处实测坑: (1) --gateway-insecure **不是** `gateway add` 的 flag(它的 --help 里没有)，
#   只有**全局** flag / 环境变量 OPENSHELL_GATEWAY_INSECURE；写成 add 的 flag 会被 clap 拒掉。
#   (2) 那个环境变量的取值是 **true/false**，不是 1 —— 给 1 会得到 "[possible values: true, false]"。
OPENSHELL_GATEWAY_INSECURE=true $CLI gateway add https://127.0.0.1:18443 --name poc3 \
  --oidc-issuer "$ISSUER" --oidc-client-id openshell-cli 2>&1 | tail -3 | sed 's/^/   /'
echo "   ⚠ 代价写进结论: 跳过的只是**CLI 校验 gateway 的服务器证书**；POC3 要证的\"调用者是谁\"
#   来自客户端出示的 JWT，与被跳过的那一侧无关。生产上这里应该用 gateway 的真实 CA。"
echo "   未认证时 status 的说法(证明这台 Gateway 确实要求认证):"
$CLI -g poc3 status 2>&1 | grep -iE "auth|unauth|denied|error" | head -3 | sed 's/^/   /'
echo "### 完成"
