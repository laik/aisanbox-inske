#!/usr/bin/env bash
# 在一个已有 Capsule 租户体系的集群里，为某个租户开通 AI sandbox 能力。
# 前提: 集群已装 agent-sandbox + OpenShell gateway(operator 模式) + Tetragon。
# 这是"新增一个租户"要做的全部动作 —— 5 步，没有手工 kubectl 逐项配置。
set -euo pipefail
TENANT="${1:?usage: $0 <tenant> [ns]}"
NS="${2:-$TENANT}"
GW_NS="${OPEN_SHELL_NS:-openshell}"
WS_CHART="${WS_CHART:-./vendor/openshell-workspace}"

echo "1) 声明租户(若已存在则跳过)。关键: namespaceOptions.additionalMetadata.labels
   里的 openshell.ai/workspace=true 是把 Capsule 租户接到 OpenShell 的那根线。"
kubectl apply -f - <<YAML
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: $TENANT
  labels: {app.kubernetes.io/part-of: aisanbox-poc, aisanbox.io/sandbox: "true"}
spec:
  owners: [{kind: Group, name: tenant-$TENANT}]
  namespaceOptions:
    quota: 2
    additionalMetadata:
      labels:
        openshell.ai/workspace: "true"
        aisanbox.io/tenant: $TENANT
  resourceQuotas:
    items:
      - hard:
          requests.cpu: "4"
          requests.memory: 4Gi
          limits.cpu: "4"
          limits.memory: 4Gi
          persistentvolumeclaims: "10"     # 每个 sandbox 一个 workspace PVC
          count/pods: "40"
  # 沙箱模板不写 resources 时由这里兜底 —— 但模板仍应显式声明(见 §预热池容量)
  limitRanges:
    items:
      - limits:
          - type: Container
            default: {cpu: 500m, memory: 512Mi}
            defaultRequest: {cpu: 100m, memory: 128Mi}
            max: {cpu: "2", memory: 2Gi}
            min: {cpu: 10m, memory: 16Mi}
  storageClasses: {allowed: [standard], default: standard}
YAML

echo "2) 注册租户使用者(不注册的话 owner 连 create ns 的权限都没有)"
kubectl apply -f - <<YAML
apiVersion: capsule.clastix.io/v1beta2
kind: TenantOwner
metadata:
  name: $TENANT-owner
  labels: {projectcapsule.dev/tenant: $TENANT}
spec: {kind: Group, name: tenant-$TENANT}
YAML

echo "3) 由租户 owner 自己建命名空间(Capsule webhook 注入标签/配额/默认网络策略)"
kubectl create ns "$NS" --as="$TENANT-admin" --as-group="tenant-$TENANT" || true

echo "4) 给该命名空间装 OpenShell 的命名空间级前置(SA/Role/NP)。
   operator 模式下这是 gateway 在该 ns 内唯一的 Secret 权限来源。"
helm upgrade --install "os-workspace-$TENANT" "$WS_CHART" -n "$NS" \
  --set gateway.serviceAccount.name=openshell \
  --set gateway.serviceAccount.namespace="$GW_NS"

echo "5) 下发该租户的 agent 可观测/强制策略(按租户标签选工作负载)"
sed "s/projectcapsule.dev\/tenant: acme/projectcapsule.dev\/tenant: $TENANT/g" \
  ./poc/tetragon/policies/*.yaml | kubectl apply -f -

echo "完成。租户侧使用:"
echo "  openshell workspace create --name $TENANT"
echo "  openshell --workspace $TENANT sandbox create --name try1 -- <cmd>"
