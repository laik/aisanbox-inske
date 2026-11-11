#!/usr/bin/env bash
# =============================================================================
# OpenShell Gateway 生产部署（单 release、Deployment、外置 PostgreSQL）
#
# 用法：
#   DOMAIN=openshell.example.com \
#   ISSUER=https://id.example.com/realms/openshell \
#   bash deploy-prod.sh
#
# 幂等：可重复执行（helm upgrade --install）。
# 前置：PostgreSQL、2 个 Secret、cert-manager、Gateway API + Envoy Gateway、
#       Agent Sandbox CRD、openshell-workspace chart 能拉到。
# 本脚本**只装 gateway 侧**；数据库与备份见 postgres-cnpg.yaml / README §3。
# =============================================================================
set -euo pipefail

CTX=${CTX:-}
NS=${NS:-openshell}
RT=${RT:-openshell-runtime}
OS_VERSION=${OS_VERSION:-0.1.7}
DOMAIN=${DOMAIN:?请设置 DOMAIN（例如 openshell.example.com）}
ISSUER=${ISSUER:?请设置 ISSUER（OIDC issuer URL）}
APPLY_MONITORING=${APPLY_MONITORING:-0}

echo "### 0. 前置检查"
command -v kubectl >/dev/null || { echo "缺少 kubectl"; exit 1; }
command -v helm >/dev/null || { echo "缺少 helm"; exit 1; }
CTX=${CTX:-$(kubectl config current-context)}
HELM_ARGS=(--kube-context "$CTX")
KC() { kubectl --context "$CTX" "$@"; }
for crd in gateways.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io \
           certificates.cert-manager.io sandboxes.agents.x-k8s.io; do
  if ! out=$(KC get crd "$crd" 2>&1); then
    case "$out" in
      *Forbidden*) echo "✗ 无权读取 CRD，无法确认 $crd（需要集群级读权限）";;
      *)           echo "✗ 缺少 CRD: $crd";;
    esac
    exit 1
  fi
done
KC get ns "$NS" >/dev/null 2>&1 || KC create ns "$NS"
KC get ns "$RT" >/dev/null 2>&1 || KC create ns "$RT"
KC label ns "$RT" openshell.ai/sandbox-runtime=true --overwrite >/dev/null
KC -n "$NS" get secret openshell-db >/dev/null || { echo "✗ 缺少 Secret $NS/openshell-db"; exit 1; }
KC -n "$NS" get secret openshell-kek >/dev/null || { echo "✗ 缺少 Secret $NS/openshell-kek"; exit 1; }
echo "   ✓ CRD / namespace / Secret 齐备"

echo "### 1. sandbox workspace 资源（runtime ns：SA/Role/NetworkPolicy）"
helm "${HELM_ARGS[@]}" upgrade --install os-ws-openshell \
  oci://ghcr.io/nvidia/openshell/openshell-workspace --version "$OS_VERSION" \
  --namespace "$RT" \
  --set gateway.serviceAccount.name=openshell \
  --set gateway.serviceAccount.namespace="$NS" \
  --set gateway.allowDriverConfig=false \
  --set sandboxServiceAccount.name=openshell-sandbox \
  --set networkPolicy.podSelector."app\.kubernetes\.io/instance"=openshell \
  --timeout 5m --wait | tail -2 | sed 's/^/   /'

echo "### 2. Gateway（Deployment + 外置 PG + 边缘 TLS 终止）"
helm "${HELM_ARGS[@]}" upgrade --install openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart --version "$OS_VERSION" \
  --namespace "$NS" \
  -f "$(dirname "$0")/values-gateway-prod.yaml" \
  --set server.oidc.issuer="$ISSUER" \
  --set 'grpcRoute.hostnames[0]='"$DOMAIN" \
  --timeout 10m --wait | tail -3 | sed 's/^/   /'

echo "### 3. client TLS bundle 复制到 runtime ns（chart 跨 ns 不复制；缺失时 supervisor 卡住）"
if KC -n "$RT" get secret openshell-client-tls >/dev/null 2>&1; then
  echo "   已存在"
else
  KC -n "$NS" get secret openshell-client-tls -o yaml 2>/dev/null | python3 -c "
import sys,yaml,json
o=yaml.safe_load(sys.stdin)
print(json.dumps({'apiVersion':'v1','kind':'Secret','metadata':{'name':'openshell-client-tls','namespace':'$RT'},'type':o['type'],'data':o['data']}))" \
    | KC apply -f - >/dev/null && echo "   已复制"
fi

echo "### 4. PDB / 监控（可选）"
KC apply -f "$(dirname "$0")/pdb-gateway.yaml"
if [ "$APPLY_MONITORING" = "1" ]; then
  KC apply -f "$(dirname "$0")/servicemonitor.yaml"
  KC apply -f "$(dirname "$0")/prometheusrule.yaml"
fi

echo "### 5. 部署后断言"
DEP=$(KC -n "$NS" get deploy -l app.kubernetes.io/instance=openshell -o jsonpath='{.items[0].metadata.name}')
[ -n "$DEP" ] || { echo "✗ 找不到 release=openshell 的 Deployment"; exit 1; }
echo "   Deployment: $DEP  (release=openshell 时名字就是 openshell; 改名后是 <release>-openshell)"
KC -n "$NS" rollout status "deploy/$DEP" --timeout=300s | sed 's/^/   /'
KC -n "$NS" get deploy,sts -o name | sed 's/^/   /'
KC -n "$NS" get pods -l app.kubernetes.io/instance=openshell \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount | sed 's/^/   /'
echo -n "   DB env -> "; KC -n "$NS" get deploy "$DEP" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}{"\n"}'
echo -n "   args    -> "; KC -n "$NS" get deploy "$DEP" \
  -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
echo "### 完成。CLI 指向: https://$DOMAIN"
