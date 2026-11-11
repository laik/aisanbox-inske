#!/usr/bin/env bash
# POC4 —— 把 Gateway 从 StatefulSet+SQLite 换成 Deployment+PostgreSQL，
# 并起**两台共享同一台 PG**的 Gateway(p4a / p4b)，供 81 号脚本验证。
#
# 关键值(都在 openshell4/gateway-pg-values.yaml 里，这里只做注入):
#   workload.kind=deployment
#   server.externalDbSecret=p4-db-uri        (Secret key: uri)
#   server.credentialStorage.existingSecret=p4-credential-kek  (两台必须同一个 KEK)
#
# ⚠ 与 POC2/POC3 一样: **先装 workspace chart(RBAC)，再装 gateway**。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=${CTX:-kind-agent-runtime-poc}
K="kubectl --context $CTX"
OS_VERSION=${OS_VERSION:-0.1.7}
DB_NS=poc4-db
RT_NS=poc4-runtime
GWA=poc4-gw-a
GWB=poc4-gw-b
RA=p4a
RB=p4b
CA_SRC=identity/certs/issuer-ca.crt

ISSUER_PATH=$($K -n identity get cm kc-config -o jsonpath='{.data.issuer_url}')
REALM=$($K -n identity get cm kc-config -o jsonpath='{.data.realm}' 2>/dev/null); REALM=${REALM:-aisanbox}
[ -n "$ISSUER_PATH" ] || { echo "✗ 读不到 identity/kc-config 的 issuer_url(先跑 identity/30)"; exit 1; }
ISSUER="$ISSUER_PATH/realms/$REALM"
echo "### 0. issuer: $ISSUER"

echo "### 1. namespace: db / 两台 gateway / 共享 runtime"
for ns in $DB_NS $GWA $GWB; do
  $K create ns $ns --dry-run=client -o yaml | $K apply -f - >/dev/null
done
$K create ns $RT_NS --dry-run=client -o yaml | python3 -c "
import sys,yaml
o=yaml.safe_load(sys.stdin)
o['metadata']['labels']={'app.kubernetes.io/part-of':'aisanbox-poc4','openshell.ai/sandbox-runtime':'true'}
print(yaml.safe_dump(o))" | $K apply -f - >/dev/null

echo "### 2. PostgreSQL(单副本 + PVC)"
$K apply -f openshell4/postgres.yaml >/dev/null
$K -n $DB_NS rollout status deploy/postgres --timeout=180s | sed 's/^/   /' || {
  echo "   ✗ postgres 没起来, 最近事件:"; $K -n $DB_NS get pod,ev | tail -20; exit 1; }
POD=$($K -n $DB_NS get pod -l app=postgres -o name | head -1 | sed 's|pod/||')
echo -n "   pg_isready: "; $K -n $DB_NS exec "$POD" -- pg_isready -U openshell -d openshell

echo "### 3. 两台 Gateway 共用的两样东西: DB URI Secret + KEK Secret"
URI="postgresql://openshell:poc4pass@postgres.$DB_NS.svc.cluster.local:5432/openshell"
for ns in $GWA $GWB; do
  $K -n $ns create secret generic p4-db-uri --from-literal=uri="$URI" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
done
# KEK: 同一个值复制到两个 ns(Secret 不能跨 ns 引用)。⚠ 两台共库但不共 KEK ⇒
#   凭据解不开 —— 这是 chart 源码/注释层面的设计约束;本 POC 没能构造出解密失败的
#   观测点(见 README §13.3)，81 号脚本只断言"配置上共用同一个 KEK"。
if $K -n $GWA get secret p4-credential-kek >/dev/null 2>&1; then
  KEK=$($K -n $GWA get secret p4-credential-kek -o jsonpath='{.data.key-encryption-key}')
else
  KEK=$(openssl rand -base64 32)
  $K -n $GWA create secret generic p4-credential-kek --from-literal=key-encryption-key="$KEK" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
fi
$K -n $GWB create secret generic p4-credential-kek --from-literal=key-encryption-key="$KEK" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null
echo "   KEK 两个 ns 是否同一份: $([ "$($K -n $GWA get secret p4-credential-kek -o jsonpath='{.data.key-encryption-key}')" = "$($K -n $GWB get secret p4-credential-kek -o jsonpath='{.data.key-encryption-key}')" ] && echo yes || echo no)"

echo "### 4. issuer CA(每个 gateway ns 各一份 ConfigMap; 名字必须等于 values 的 caConfigMapName)"
for ns in $GWA $GWB; do
  $K -n $ns create configmap oidc-ca --from-file=ca.crt="$CA_SRC" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
done

echo "### 5. workspace chart(共享 runtime ns; 每台一个 SA/NetPol)"
for pair in "$RA:$GWA" "$RB:$GWB"; do
  rel=${pair%%:*}; ns=${pair##*:}
  helm --kube-context $CTX upgrade --install "os-ws-$rel" oci://ghcr.io/nvidia/openshell/openshell-workspace \
    --version "$OS_VERSION" --namespace $RT_NS \
    --set gateway.serviceAccount.name="${rel}-openshell" \
    --set gateway.serviceAccount.namespace="$ns" \
    --set gateway.allowDriverConfig=true \
    --set sandboxServiceAccount.name="${rel}-openshell-sandbox" \
    --set networkPolicy.podSelector."app\.kubernetes\.io/instance"="$rel" \
    --timeout 3m --wait >/dev/null 2>&1 && echo "   $rel workspace chart ✓" || echo "   $rel workspace chart ✗"
done

echo "### 6. Gateway ×2(同一套 values、同一台 PG; 只有名字/ns 不同)"
sed "s|__ISSUER__|$ISSUER|" openshell4/gateway-pg-values.yaml > /tmp/gw-pg-values.yaml
for pair in "$RA:$GWA" "$RB:$GWB"; do
  rel=${pair%%:*}; ns=${pair##*:}
  helm --kube-context $CTX upgrade --install "$rel" oci://ghcr.io/nvidia/openshell/helm-chart \
    --version "$OS_VERSION" --namespace "$ns" -f /tmp/gw-pg-values.yaml \
    --set server.name="$ns" --set server.sandboxNamespace="$RT_NS" \
    --set server.otlp.serviceName="$ns" --timeout 8m --wait 2>&1 | tail -2 | sed 's/^/   /'
done

echo "### 6b. 把 gateway 生成的 client-TLS bundle 复制到共享 runtime ns"
# POC2/POC3 同一条实测坑: 缺了它 supervisor 卡 ContainerCreating。
$K -n $RT_NS get secret openshell-client-tls >/dev/null 2>&1 || \
  $K -n $GWA get secret openshell-client-tls -o yaml | python3 -c "
import sys,yaml,json
o=yaml.safe_load(sys.stdin)
print(json.dumps({'apiVersion':'v1','kind':'Secret','metadata':{'name':'openshell-client-tls','namespace':'$RT_NS'},'type':o['type'],'data':o['data']}))" \
  | $K apply -f - >/dev/null
$K -n $RT_NS get secret openshell-client-tls >/dev/null 2>&1 && echo "   runtime ns 有 openshell-client-tls ✓" || echo "   ✗ 缺失"

echo "### 7. 断言**跑着的东西**: 是 Deployment(不是 StatefulSet)、连的是 PostgreSQL"
for pair in "$RA:$GWA" "$RB:$GWB"; do
  rel=${pair%%:*}; ns=${pair##*:}
  echo "   --- $ns"
  $K -n $ns get deploy,sts -o name | sed 's/^/      /'
  $K -n $ns get pods -l app.kubernetes.io/instance=$rel \
    -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount | sed 's/^/      /'
  $K -n $ns logs deploy/${rel}-openshell --tail=200 2>/dev/null | grep -iE "postgres|database|sqlite" | tail -3 | sed 's/^/      /'
  $K -n $ns get deploy ${rel}-openshell \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.valueFrom.secretKeyRef.name}{"\n"}{end}' \
    | grep OPENSHELL_DB_URL | sed 's/^/      env /'
  $K -n $ns get deploy ${rel}-openshell \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' | sed 's/^/      arg /'
done

echo "### 8. NodePort(31445→p4a, 31446→p4b; 不用 port-forward, 同 POC3)"
for pair in "$RA:$GWA:31445" "$RB:$GWB:31446"; do
  rel=${pair%%:*}; rest=${pair#*:}; ns=${rest%%:*}; port=${rest##*:}
  $K -n $ns apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: {name: ${rel}-nodeport, namespace: ${ns}, labels: {app.kubernetes.io/part-of: aisanbox-poc4}}
spec:
  type: NodePort
  selector: {app.kubernetes.io/name: openshell, app.kubernetes.io/instance: ${rel}}
  ports: [{name: grpc, port: 8080, targetPort: 8080, nodePort: ${port}}]
YAML
  echo "   ${rel} -> NodePort ${port}"
done
echo "### 完成"
