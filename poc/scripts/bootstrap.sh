#!/usr/bin/env env -S /bin/bash
# 一键重建 POC。前提: docker 运行中, kind/kubectl/helm 已安装。
# 注意: 两个 kind 集群内存合计约 2.5-3GiB，宿主机 docker 至少给 8GiB。
set -euo pipefail
cd "$(dirname "$0")/.."

VER_AGENT_SANDBOX=v1.0.9
VER_CAPSULE=0.15.2
VER_TETRAGON=1.8.0
VER_OS=0.1.4              # helm chart 与 appVersion 同号；GHCR 分页会让 0.0.x 看起来像最新，别取错

A=kind-inske-plane-a; B=kind-inske-plane-b

echo "### 1/6 创建两个 kind 集群(共享 docker 'kind' 网络 -> 跨集群 IP 可达)"
kind create cluster --config kind/cluster-a.yaml --wait 120s || true
kind create cluster --config kind/cluster-b.yaml --wait 120s || true

echo "### 2/6 plane-a: agent-sandbox(OpenShell 的 K8s 驱动直接依赖它)"
kubectl --context $A apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${VER_AGENT_SANDBOX}/sandbox-with-extensions.yaml"
kubectl --context $A -n agent-sandbox-system wait --for=condition=available deploy/agent-sandbox-controller --timeout=180s

echo "### 3/6 plane-a: cert-manager + Capsule(租户契约)"
kubectl --context $A apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
kubectl --context $A -n cert-manager wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager --all --timeout=180s
kubectl --context $A create ns capsule-system --dry-run=client -o yaml | kubectl apply -f -
helm --context $A upgrade --install capsule projectcapsule/capsule --version $VER_CAPSULE \
  -n capsule-system --wait --timeout 5m

echo "### 4/6 plane-a: 租户(由 tenant owner 自己建 ns，Capsule 注入标签/配额/策略)"
kubectl --context $A apply -f capsule/tenants.yaml
kubectl --context $A apply -f capsule/tenant-owners.yaml
kubectl --context $A create ns acme   --as=alice --as-group=tenant-acme   || true
kubectl --context $A create ns globex --as=bob   --as-group=tenant-globex || true

echo "### 5/6 plane-a: Tetragon(需要 BTF 内核; Docker Desktop 6.12 满足)"
# 用 poc/tetragon/values.yaml 里的 daemon 配置：默认安装缺 parents-map / process-cred /
# process-ns / ancestors 这几个开关，matchParentBinaries 等能力会直接加载失败。
helm repo add cilium https://helm.cilium.io >/dev/null && helm repo update >/dev/null
helm --context $A upgrade --install tetragon cilium/tetragon --version $VER_TETRAGON -n kube-system \
  -f tetragon/values.yaml --wait --timeout 6m

echo "### 6/6 plane-a: OpenShell gateway(operator 模式) + 每个租户 ns 的 workspace 前置"
TMP=$(mktemp -d)
helm pull oci://ghcr.io/nvidia/openshell/helm-chart --version $VER_OS --untar --untardir "$TMP" >/dev/null
helm --context $A upgrade --install openshell "$TMP/helm-chart" -n openshell --create-namespace \
  -f openshell/values-plane-a.yaml --timeout 6m
WS="$TMP/ws"; mkdir -p "$WS/templates"
for f in Chart.yaml values.yaml; do curl -sSL -o "$WS/$f" "https://raw.githubusercontent.com/NVIDIA/OpenShell/main/deploy/helm/openshell-workspace/$f"; done
for f in _helpers.tpl networkpolicy.yaml role.yaml rolebinding.yaml serviceaccount.yaml; do
  curl -sSL -o "$WS/templates/$f" "https://raw.githubusercontent.com/NVIDIA/OpenShell/main/deploy/helm/openshell-workspace/templates/$f"
done
sed -i "s/^version: 0.0.0/version: ${VER_OS}/; s/^appVersion: \"0.0.0\"/appVersion: \"${VER_OS}\"/" "$WS/Chart.yaml"
for t in acme globex; do
  helm --context $A upgrade --install "os-workspace-$t" "$WS" -n "$t" \
    --set gateway.serviceAccount.name=openshell --set gateway.serviceAccount.namespace=openshell
done
rm -rf "$TMP"

echo "### 租户侧安全策略由 Capsule GlobalTenantResource 自动下发(单一来源)"
kubectl --context $A apply -f capsule/global-tenant-resource.yaml
for f in tetragon/policies/*.yaml; do kubectl --context $A apply -f "$f"; done
kubectl --context $A apply -f agent-sandbox/warmpool-acme.yaml

echo "### agent 侧观测后端(Jaeger + 模型出口) + 让沙箱真的能出去"
# 这两份是 2026-11-06 第二轮实测补上的，缺一不可：
#   observability/trace-backend.yaml  收 OTLP 的 Jaeger，以及"租户模型网关"的替身
#   agent/egress-allow.yaml           没有它，沙箱的 egress 只有 DNS，什么都连不上
kubectl --context $A create ns observability --dry-run=client -o yaml | kubectl --context $A apply -f -
kubectl --context $A apply -f observability/trace-backend.yaml
# 模型上游默认是宿主机上的端点；换成真实网关就改这两行(或部署后再 kubectl set env)。
MODEL_UPSTREAM_HOST=${MODEL_UPSTREAM_HOST:-host.docker.internal}
MODEL_UPSTREAM_PORT=${MODEL_UPSTREAM_PORT:-15721}
kubectl --context $A -n observability set env deploy/model-egress \
  MODEL_UPSTREAM_HOST=$MODEL_UPSTREAM_HOST MODEL_UPSTREAM_PORT=$MODEL_UPSTREAM_PORT
kubectl --context $A apply -f agent/egress-allow.yaml
kubectl --context $A -n observability rollout status deploy/jaeger --timeout=180s || true
kubectl --context $A -n observability rollout status deploy/model-egress --timeout=120s || true

echo "### 观测栈放在 plane-b(平台集群)，抓 plane-a 的 NodePort 指标"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null && helm repo update >/dev/null
kubectl --context $A -n capsule-system patch svc capsule-controller-manager-metrics-service \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"metrics","port":8080,"protocol":"TCP","targetPort":8080,"nodePort":30901},{"name":"health-api","port":10080,"protocol":"TCP","targetPort":10080}]}}'
kubectl --context $A apply -f - <<'SVC'
apiVersion: v1
kind: Service
metadata: {name: tetragon-metrics-nodeport, namespace: kube-system}
spec:
  type: NodePort
  selector: {app.kubernetes.io/name: tetragon}
  ports: [{name: metrics, port: 2112, targetPort: 2112, nodePort: 30902}]
SVC
kubectl --context $A -n openshell patch svc openshell -p '{"spec":{"type":"NodePort"}}'
NODE_IP=$(kubectl --context $A get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
OS_PORT=$(kubectl --context $A -n openshell get svc openshell -o jsonpath='{.spec.ports[?(@.name=="metrics")].nodePort}')
sed -e "s/172\.18\.0\.2/${NODE_IP}/g" -e "s/32133/${OS_PORT}/g" observability/scrape-tenants.yaml > /tmp/scrape.yaml
helm --context $B upgrade --install prometheus prometheus-community/prometheus --version 27.38.0 \
  -n monitoring --create-namespace --set alertmanager.enabled=false --set pushgateway.enabled=false \
  --set kube-state-metrics.enabled=false --set nodeExporter.enabled=false \
  --set-file extraScrapeConfigs=/tmp/scrape.yaml --timeout 6m
echo "OK. Prometheus: kubectl --context $B -n monitoring port-forward deploy/prometheus-server 9090:9090"
