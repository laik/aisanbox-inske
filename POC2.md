# NVIDIA OpenShell 多租户 Agent Runtime 安全与可观测性 PoC

**项目类型：** Kubernetes / AI Agent Runtime 技术验证  
**验证环境：** Kind  
**参考版本：** NVIDIA OpenShell v0.1.7  
**Agent：** Pi Coding Agent  
**网络：** Antrea  
**运行时安全观测：** Cilium Tetragon  
**应用可观测性：** OpenTelemetry  
**准入控制：** OPA Gatekeeper  
**多租户管理：** Capsule

---

# 1. PoC 背景与目标

## 1.1 项目背景

本 PoC 验证基于 Kubernetes 构建多租户 AI Agent Runtime 平台的可行性。

平台为每个租户提供独立的 NVIDIA OpenShell Gateway，由租户通过自己的 Gateway 创建和管理 Workspace、Sandbox 及 Agent。

平台继续使用已有的 Kubernetes 基础设施：

- Capsule：租户管理和 Namespace 归属。
- Antrea：租户网络隔离和微分段。
- OPA Gatekeeper：Kubernetes 资源准入与安全约束。
- Cilium Tetragon：基于 eBPF 的运行时行为观测。
- OpenTelemetry：Agent、Gateway 和 Supervisor 的统一遥测。
- NVIDIA OpenShell：Agent 安全执行环境。

本次 PoC 不开发完整的 Runtime SaaS 平台，重点验证各个组件之间的集成关系，以及是否能够形成完整的 Agent 安全执行和审计链路。

## 1.2 核心目标

| 编号 | 验证目标 | 预期结果 |
|---|---|---|
| POC-01 | 每租户独立 Gateway | 租户拥有独立 Gateway 和管理状态 |
| POC-02 | Capsule 租户隔离 | 租户只能使用自己的 Runtime Namespace |
| POC-03 | OpenShell Sandbox | Gateway 可以创建和管理多个 Pi Sandbox |
| POC-04 | Workspace 共享 | 多个 Sandbox 可以访问同一个项目工作区 |
| POC-05 | Antrea 网络隔离 | Agent 无法绕过 Supervisor 直接访问未授权网络 |
| POC-06 | Gatekeeper 准入控制 | 阻止不安全的 Kubernetes 资源创建 |
| POC-07 | Tetragon 行为观测 | 观察 Agent 进程执行和网络连接 |
| POC-08 | Agent OpenTelemetry | 采集 Pi 的模型调用和工具执行 Trace |
| POC-09 | OpenShell 遥测 | 采集 Gateway、Supervisor 和 OCSF 安全事件 |
| POC-10 | 多 Agent 协作 | 一个 Agent 修改代码，多个 Agent 并行 Review |
| POC-11 | 安全事件关联 | 根据 Tenant、Gateway、Workspace、Sandbox 关联多种观测数据 |

## 1.3 本次 PoC 不验证的内容

以下内容不纳入第一阶段：

- 生产级 Gateway 高可用。
- 多集群 Gateway 调度。
- 大规模 Agent 并发性能。
- GPU 资源调度。
- 多租户计费。
- 生产级身份认证集成。
- 完整的自动化 Multi-Agent Orchestrator。
- 生产环境的 eBPF 性能开销评估。

这些内容放入后续设计阶段。

---

# 2. 总体架构

## 2.1 逻辑架构

```text
                         Tenant User
                              |
                              v
                       Platform API
                              |
                    Tenant Gateway Mapping
                              |
               +--------------+--------------+
               |                             |
               v                             v
         Tenant A                       Tenant B
               |                             |
        OpenShell GW A               OpenShell GW B
               |                             |
        Tenant A Runtime              Tenant B Runtime
               |                             |
       +-------+-------+              +-------+-------+
       |       |       |              |       |       |
      Pi-Dev Pi-R1   Pi-R2            Agent   Agent   ...
       |       |       |
       +-------+-------+
               |
        Shared Workspace
          (RWX PVC)
               |
       Git Repository
               |
       Modified Source Code
```

安全和观测组件：

```text
                 Kubernetes Cluster
                         |
       +-----------------+-----------------+
       |                 |                 |
       v                 v                 v
    Capsule           Antrea          Gatekeeper
       |                 |                 |
   Tenant/NS       Network Policy      Admission
       |                 |                 |
       +-----------------+-----------------+
                         |
                         v
                   Agent Sandbox
                         |
               +---------+---------+
               |                   |
               v                   v
           Supervisor          Pi Agent
               |                   |
               |                   +----> Git
               |                   |
               |                   +----> Model API
               |
               +----> OpenShell Gateway
               |
               +----> OTLP Collector

       Tetragon DaemonSet
               |
          eBPF Events
               |
        OTel Log Adapter
               |
               v
        OpenTelemetry Collector
               |
        +------+--------+
        |               |
        v               v
     Trace Backend   Security Backend
```

## 2.2 Kubernetes Namespace 规划

```text
kind-cluster
│
├── capsule-system
│   └── capsule-controller
│
├── gatekeeper-system
│   └── gatekeeper-controller
│
├── agent-sandbox-system
│   └── agent-sandbox-controller
│
├── observability
│   ├── otel-collector
│   └── telemetry-backend
│
├── tenant-a-gateway
│   └── openshell-gateway
│
├── tenant-a-runtime
│   ├── openshell-workspace-resources
│   ├── shared-workspace-pvc
│   ├── pi-developer-sandbox
│   ├── pi-reviewer-1-sandbox
│   └── pi-reviewer-2-sandbox
│
└── tenant-b-gateway
    └── openshell-gateway
```

说明：

- 每个租户独立部署 OpenShell Gateway。
- 每个租户有独立的 Gateway Namespace。
- 每个租户有独立的 Runtime Namespace。
- Agent Sandbox Controller 全集群部署一次。
- Tetragon DaemonSet 全集群部署一次。
- OTel Collector 可以集中部署，但需要按租户和 Sandbox 身份进行数据隔离。

## 2.3 OpenShell Workspace 模式

本 PoC 使用：

`workspaceMode: shared`

原因：

当前一个 Gateway 只服务一个租户，所有 Workspace Sandbox 都放在该租户专属的 Runtime Namespace。

因此不需要使用 operator 模式来管理多个预创建 Namespace。

如果未来一个 Gateway 要管理多个不同 Runtime Namespace，再验证 operator 模式。

---

# 3. Kind 测试环境

## 3.1 环境要求

建议：

| 资源 | 建议 |
|---|---|
| CPU | 8 Core 以上 |
| Memory | 16 GB 以上 |
| Disk | 40 GB 以上 |
| Kubernetes | 1.32 或兼容的 1.29+ 版本 |
| Kind | 0.20+ |
| Helm | Helm 3 |
| Docker | Docker Engine / Docker Desktop |
| Linux Kernel | 5.10+，建议具备 BTF |

注意：Tetragon 需要宿主 Linux Kernel 支持 eBPF 和 BTF。Mac 上运行 Kind 时，实际观察的是 Docker Desktop Linux VM 的内核，而不是 macOS 内核。

先检查：

```bash
uname -r

ls -l /sys/kernel/btf/vmlinux

docker info
```

如果没有 BTF，先解决内核 BTF 问题，不要继续排查 Tetragon 配置。

## 3.2 创建 Kind 集群

创建 `kind.yaml`：

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

name: agent-runtime-poc

networking:
  disableDefaultCNI: true
  podSubnet: 10.244.0.0/16

nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

创建集群：

```bash
kind create cluster \
  --config kind.yaml \
  --wait 120s
```

检查：

```bash
kubectl get nodes
kubectl cluster-info
```

## 3.3 安装 Antrea

Kind 不安装默认 CNI，使用 Antrea 作为唯一 CNI。

```bash
helm repo add antrea https://charts.antrea.io

helm repo update
```

安装：

```bash
export ANTREA_VERSION=<选定并记录的版本>

helm upgrade --install antrea antrea/antrea \
  --namespace kube-system \
  --version "${ANTREA_VERSION}"
```

等待：

```bash
kubectl rollout status daemonset/antrea-agent \
  -n kube-system

kubectl get pods -n kube-system
```

验证 Pod 网络：

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

**验收：** 所有节点 Ready，Pod 网络正常，NetworkPolicy 的 ingress 和 egress 均能实际执行。

不要只检查 NetworkPolicy 对象是否创建成功，必须用实际网络连接验证。

## 3.4 安装 Capsule

```bash
helm repo add projectcapsule \
  https://projectcapsule.github.io/charts

helm repo update
```

安装：

```bash
helm upgrade --install capsule \
  projectcapsule/capsule \
  --namespace capsule-system \
  --create-namespace
```

创建 Tenant：

```yaml
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: tenant-a
spec:
  namespaceOptions:
    quota: 5
  forceTenantPrefix: true
```

应用：

```bash
kubectl apply -f tenant-a.yaml
kubectl get tenants
```

后续由平台管理员创建 Gateway 和 Runtime Namespace，并确保这些 Namespace 归属于正确 Tenant。

## 3.5 安装 Gatekeeper

```bash
helm repo add gatekeeper \
  https://open-policy-agent.github.io/gatekeeper/charts

helm repo update

helm upgrade --install gatekeeper \
  gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace
```

验证：

```bash
kubectl get pods -n gatekeeper-system
kubectl get crd | grep gatekeeper
```

本次至少验证：

- 禁止 privileged 容器。
- 禁止 hostNetwork。
- 禁止 hostPID。
- 禁止不受控 hostPath。
- 禁止租户使用平台专用 ServiceAccount。
- 禁止租户直接创建和修改 OpenShell Sandbox 资源。
- 要求 Runtime 工作负载有资源 requests/limits。

Gatekeeper 的规则要针对租户用户身份精确生效，不要因为 OpenShell Controller 需要管理资源，就对整个 Runtime Namespace 做宽泛豁免。

## 3.6 安装 Agent Sandbox Controller

OpenShell Kubernetes Driver 依赖 Kubernetes SIG Agent Sandbox。

```bash
export AGENT_SANDBOX_VERSION=<选定并记录的版本>

kubectl apply -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox.yaml"
```

等待：

```bash
kubectl rollout status deployment/agent-sandbox-controller \
  -n agent-sandbox-system \
  --timeout=120s

kubectl get crd sandboxes.agents.x-k8s.io
```

必须确认 OpenShell 使用的 Sandbox API 版本与已安装的 Agent Sandbox CRD 兼容。

## 3.7 安装 Tetragon

Tetragon 以 DaemonSet 形式运行。

```bash
helm repo add cilium https://helm.cilium.io

helm repo update
```

安装：

```bash
export TETRAGON_VERSION=<选定并记录的版本>

helm upgrade --install tetragon cilium/tetragon \
  --namespace kube-system \
  --version "${TETRAGON_VERSION}"
```

等待：

```bash
kubectl rollout status daemonset/tetragon \
  -n kube-system
```

检查：

```bash
kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=tetragon
```

检查 Tetragon 事件：

```bash
kubectl exec -it \
  -n kube-system \
  ds/tetragon \
  -c tetragon -- \
  tetra getevents -o compact
```

首先确认能看到普通测试 Pod 的进程执行事件。

然后再部署 Agent。

---

# 4. OpenShell Gateway 部署

## 4.1 创建租户 Namespace

```bash
kubectl create namespace tenant-a-gateway

kubectl create namespace tenant-a-runtime
```

确认 Namespace 归属 Capsule Tenant A。

建议标签：

```yaml
metadata:
  labels:
    platform.example.com/tenant: tenant-a
    platform.example.com/runtime: "true"
```

这些标签由平台管理，租户不可自行修改。

## 4.2 安装 Gateway

本次固定 OpenShell v0.1.7，所有镜像、Chart 和 CLI 版本需要保持兼容。

Gateway 和 Workspace 资源分开安装：

```bash
helm upgrade --install openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.1.7 \
  --namespace tenant-a-gateway \
  --set workspaceResources.enabled=false \
  --set server.sandboxNamespace=tenant-a-runtime
```

## 4.3 安装 Workspace 资源

```bash
helm upgrade --install openshell-workspace \
  oci://ghcr.io/nvidia/openshell/openshell-workspace \
  --version 0.1.7 \
  --namespace tenant-a-runtime \
  --set gateway.serviceAccount.name=openshell \
  --set gateway.serviceAccount.namespace=tenant-a-gateway
```

本 PoC 使用 shared Workspace Namespace。

需要特别注意：Gateway 和 Workspace Chart 分开安装时，Workspace Chart 不负责创建 Namespace 或 Gateway，它负责 Workspace Namespace 中的 Sandbox ServiceAccount、Role、RoleBinding 和 NetworkPolicy。

## 4.4 开启外部 PVC 挂载能力

为了让多个 Pi Sandbox 访问同一份 Workspace，需要使用 Kubernetes Driver 的 PVC Mount 配置。

Gateway 侧：

```yaml
gatewayConfig:
  openshell.drivers.kubernetes:
    allow_driver_config: true
    workspace_mode: shared
    resource_admission:
      enabled: true
      required_labels:
        openshell.ai/sandbox-attachable: "true"
        openshell.ai/sandbox-attachable-workspace: "${workspace}"
```

Workspace Chart 侧：

```yaml
gateway:
  allowDriverConfig: true
```

以上是配置结构示意，实际 values 文件需要按 v0.1.7 Chart 的字段结构合并，并用 `helm template` 检查。

**不要关闭 resource admission 来图省事。**

外部 PVC 必须经过 OpenShell 的授权标签检查。这里 `${workspace}` 指 OpenShell Workspace 名称，而不是 Kubernetes Namespace 名称。

---

# 5. 多 Pi 共享 Workspace

这是本次 PoC 的核心测试点。

## 5.1 设计

创建一个共享项目目录：

```text
/data/workspace
    └── godotenv
```

Sandbox 规划：

| Sandbox | Agent | Workspace 权限 | 任务 |
|---|---|---|---|
| pi-dev | Pi Developer | ReadWrite | Clone 和修改代码 |
| pi-review-1 | Pi Reviewer A | ReadOnly | 代码质量 Review |
| pi-review-2 | Pi Reviewer B | ReadOnly | 安全 Review |

三个 Sandbox 使用同一个 PVC。

但是权限不同：

```text
                 shared-workspace-pvc
                          |
            +-------------+-------------+
            |             |             |
            v             v             v
         pi-dev        pi-review-1   pi-review-2
            |             |             |
           RW             RO            RO
```

这样可以验证共享工作区，同时防止 Reviewer 修改 Developer 的代码。

## 5.2 PVC 存储

创建 `workspace-pvc.yaml`：

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-workspace
  namespace: tenant-a-runtime
  labels:
    openshell.ai/sandbox-attachable: "true"
    openshell.ai/sandbox-attachable-workspace: "poc-code-review"
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: <rwx-storage-class>
  resources:
    requests:
      storage: 5Gi
```

Kind 默认的 local-path StorageClass 不提供真正的 RWX 共享文件系统。

因此需要在 Kind 中安装 NFS Server + NFS Subdir External Provisioner，创建一个支持 RWX 的 StorageClass。

不要把 PVC 声明为 RWX 就当作底层存储已经支持 RWX。

验收：

```bash
kubectl get storageclass
kubectl get pvc -n tenant-a-runtime
```

## 5.3 Sandbox PVC 挂载

开发 Agent：

```json
{
  "kubernetes": {
    "volumes": [
      {
        "name": "shared-workspace",
        "persistent_volume_claim": {
          "claim_name": "shared-workspace",
          "read_only": false
        }
      }
    ],
    "containers": {
      "agent": {
        "volume_mounts": [
          {
            "name": "shared-workspace",
            "mount_path": "/data/workspace",
            "read_only": false
          }
        ]
      }
    }
  }
}
```

Reviewer Agent：

```json
{
  "kubernetes": {
    "volumes": [
      {
        "name": "shared-workspace",
        "persistent_volume_claim": {
          "claim_name": "shared-workspace",
          "read_only": true
        }
      }
    ],
    "containers": {
      "agent": {
        "volume_mounts": [
          {
            "name": "shared-workspace",
            "mount_path": "/data/workspace",
            "read_only": true
          }
        ]
      }
    }
  }
}
```

注意：

- 挂载路径使用 `/data/workspace`。
- 不覆盖 `/.openshell`、`/run` 等受保护目录。
- 本 PoC 不将外部 PVC 挂载到 `/sandbox`，避免替换 OpenShell 默认工作区 PVC。
- 每个 Sandbox 使用自己的 OpenShell 策略。
- Developer 的策略允许写入 `/data/workspace`。
- Reviewer 的策略只允许读取 `/data/workspace`。

---

# 6. Pi Agent 镜像和 OpenTelemetry

## 6.1 Pi 镜像

创建 `Dockerfile.pi`：

```dockerfile
FROM node:24-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash \
       ca-certificates \
       git \
       ripgrep \
       fd-find \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g \
    @earendil-works/pi-coding-agent

RUN mkdir -p /data/workspace /tmp/pi-agent \
    && chown -R node:node /data /tmp/pi-agent

USER node

ENV PI_CODING_AGENT_DIR=/tmp/pi-agent

WORKDIR /data/workspace
```

实际使用时应锁定 Pi 版本，不能长期使用不受控制的 latest。

构建：

```bash
docker build -t pi-agent:poc -f Dockerfile.pi .
```

把镜像加载到 Kind：

```bash
kind load docker-image pi-agent:poc \
  --name agent-runtime-poc
```

如果 Gateway 无法直接使用本地镜像缓存，则将镜像推送到 Gateway 能访问的 Registry。

## 6.2 Pi OpenTelemetry Extension

安装 Pi 的 OTel 扩展：

```bash
pi install npm:pi-otel
```

建议锁定经过验证的版本，例如 PoC 使用 `pi-otel@0.3.0`。

Pi 配置：

```json
{
  "otel": {
    "enabled": true,
    "endpoint": "http://otel-collector.observability.svc:4317",
    "protocol": "grpc",
    "serviceName": "pi-agent",
    "captureContent": "metadata_only",
    "spanNaming": "genai",
    "sampleRatio": 1.0,
    "signals": {
      "traces": true,
      "metrics": false,
      "logs": false
    }
  }
}
```

正式接入时，Pi 应优先通过 OpenShell 的 Agent Trace Relay 获取 OTLP Endpoint，而不是自行绕过 Supervisor 直接访问 Collector。

上面直接配置 Collector 的方式用于独立验证 Pi OTel 扩展；在最终集成测试中，应将 endpoint 切换为 OpenShell 提供的 Relay。

## 6.3 需要观察的 Pi Trace

期望形成：

```text
invoke_agent pi
    |
    +---- chat / llm_request
    |
    +---- execute_tool bash
    |         |
    |         +---- git clone
    |         +---- go test
    |         +---- git diff
    |
    +---- chat / llm_request
    |
    +---- execute_tool
```

建议每条 Trace 能关联以下信息：

```text
tenant.id
gateway.name
workspace.name
openshell.sandbox.id
agent.name
agent.role
task.id
git.repository
git.commit
```

其中 Sandbox ID 应与 OpenShell 的遥测属性对应；Tenant、Agent Role 等属性可通过 Pod 标签和 OTel Collector 的 Kubernetes Attributes Processor 补充。

不要采集完整 Prompt、模型思维内容、访问 Token 或 GitHub 凭证。本次 PoC 使用 metadata_only。

---

# 7. Tetragon 安全观测

## 7.1 观测目标

Tetragon 不负责替代 OpenShell 和 Antrea 的访问控制。

它的作用是从 Linux Kernel 层观察实际发生的进程和网络行为。

重点关注：

| 类型 | 观察内容 |
|---|---|
| Process Exec | pi、node、git、bash、curl、go 等进程 |
| Process Exit | 进程退出状态 |
| Network Connect | 进程发起的 TCP 连接 |
| Process Parent | Agent 启动的子进程关系 |
| Namespace | 进程所属 Namespace |
| Pod Identity | 进程所属 Pod 和容器 |
| File Access | 后续阶段增加对关键文件访问的观察 |

## 7.2 网络观测策略

先使用 Tetragon 官方的网络 egress 示例：

```bash
export PODCIDR=10.244.0.0/16
export SERVICECIDR=<kind-service-cidr>

curl -fsSL \
  https://raw.githubusercontent.com/cilium/tetragon/main/examples/quickstart/network_egress_cluster.yaml \
  -o network_egress_cluster.yaml
```

渲染并应用：

```bash
envsubst < network_egress_cluster.yaml \
  | kubectl apply -f -
```

观察：

```bash
kubectl exec -it -n kube-system ds/tetragon \
  -c tetragon -- \
  tetra getevents -o compact
```

分别验证：

1. Agent 访问 GitHub。
2. Agent 访问模型 API。
3. Agent 尝试访问未授权域名。
4. Agent 尝试访问其他 Tenant 的 Pod。
5. Agent 尝试直接连接外部 IP。

Tetragon 应能记录进程和网络行为，Antrea 和 OpenShell 应负责实际允许或拒绝。

## 7.3 Tetragon 与 OpenTelemetry 集成

一个重要实现细节：

Tetragon 原生主要提供 JSON 事件和 gRPC 事件接口，不应假设它自身已经提供通用 OTLP Exporter。

本 PoC 使用：

```text
Tetragon
    |
    +---- JSON Events / gRPC
               |
               v
       OTel Log Adapter
               |
               v
       OpenTelemetry Collector
               |
               v
       Security Log Backend
```

第一阶段可使用 OTel Collector Contrib 的 Filelog Receiver 读取 Tetragon JSON 输出。

第二阶段再开发 Go Adapter：

- 通过 Tetragon gRPC 订阅事件。
- 转换为 OTel Logs。
- 添加 Kubernetes Resource Attributes。
- 输出 OTLP。
- 保留 Tetragon 原始事件字段。

建议增加的属性：

```text
tenant.id
k8s.namespace.name
k8s.pod.name
k8s.container.name
k8s.pod.uid
openshell.sandbox.id
process.executable.name
process.executable.path
process.parent.executable.name
network.destination.ip
network.destination.port
```

注意：Tetragon 事件与 Pi Trace 不一定共享同一个 trace_id。优先使用 Sandbox ID、Pod UID、进程 ID 和时间戳进行关联，不要伪造 Trace Parent。

---

# 8. OpenShell OTel 配置

## 8.1 Gateway Trace

Gateway 配置：

```toml
[openshell.gateway]
name = "tenant-a-gateway"
metrics_bind_address = "0.0.0.0:9090"

[openshell.gateway.otlp]
endpoint = "http://otel-collector.observability.svc:4317"
service_name = "openshell-gateway"

[openshell.gateway.otlp.agent]
enabled = true
```

这部分配置需要通过 Helm 的 `gatewayConfig` 转换到 Gateway ConfigMap。

## 8.2 OpenShell Agent Trace Relay

Agent Trace Relay 默认关闭。

开启之后：

- Pi 的 OTEL Trace 经 Supervisor Relay 转发。
- Agent 不需要直接连接 Collector。
- Agent 不需要持有 Collector 的认证凭证。
- Trace 带有 `openshell.sandbox.id`。
- 可以与 Supervisor Trace 关联。

本 PoC 只要求 Agent Traces，不能把 Agent Trace Relay 当作通用 Metrics / Logs Relay。

Pi 的 Metrics 和 Logs 暂时由独立配置或其他日志采集机制处理。

## 8.3 OpenShell OCSF 安全事件

开启 OCSF OTLP 输出：

```toml
[openshell.gateway.otlp.ocsf]
enabled = true
```

关注：

- 网络策略决策。
- HTTP 请求策略决策。
- 进程生命周期。
- SSH Session。
- Gateway 配置变更。
- Policy 修改和风险审批。

最终应将 OCSF、Pi Trace 和 Tetragon Events 放在同一个观测平台中。

---

# 9. Antrea 网络隔离验证

## 9.1 网络模型

```text
Pi Workload
    |
    | 禁止直接 Egress
    |
    v
OpenShell Supervisor
    |
    +----> OpenShell Gateway
    |
    +----> Approved GitHub
    |
    +----> Approved Model API
    |
    +----> OTel Relay
```

## 9.2 网络验证矩阵

| 来源 | 目标 | 预期 |
|---|---|---|
| Pi Workload | Supervisor Boundary | ALLOW |
| Pi Workload | GitHub | DENY（直接连接） |
| Pi Workload | Internet | DENY（直接连接） |
| Supervisor | Gateway | ALLOW |
| Supervisor | GitHub | 按 OpenShell Policy 控制 |
| Supervisor | Model API | ALLOW |
| Tenant A | Tenant B Runtime | DENY |
| Tenant A | Tenant B Gateway | DENY |
| Pi Reviewer | shared-workspace | READ |
| Pi Reviewer | shared-workspace 写入 | DENY |

特别注意：OpenShell 的 Sandbox 网络策略依赖 CNI 真正执行 NetworkPolicy。Antrea 必须完成实际网络测试，不能只检查规则对象。

同时需要验证 Antrea 现有 Allow 规则与 OpenShell 自动生成的 NetworkPolicy 之间的最终执行效果。

---

# 10. 核心业务场景：Pi GitHub Code Review

这是整个 PoC 的主要业务测试。

## 10.1 测试项目

建议使用一个公开的 GitHub 项目：

```text
https://github.com/joho/godotenv.git
```

项目代码克隆到：

```text
/data/workspace/godotenv
```

本次不需要 GitHub 写入 Token，不推送修改到原始仓库。

模型服务使用一个可通过 OpenShell Provider 访问的 OpenAI-compatible 或 Anthropic-compatible Endpoint。

## 10.2 Sandbox 规划

创建三个独立 Pi Sandbox：

```text
Workspace: poc-code-review

pi-dev
  role: developer
  filesystem: read-write

pi-review-1
  role: code-reviewer
  filesystem: read-only

pi-review-2
  role: security-reviewer
  filesystem: read-only
```

三个 Sandbox 必须挂载相同 PVC。

## 10.3 第一步：Developer Clone 项目

启动 Pi Developer：

```bash
openshell sandbox create \
  --name pi-dev \
  --from pi-agent:poc \
  --provider <model-provider> \
  --driver-config-json '<developer-pvc-config>' \
  -- pi
```

给 Pi 的任务：

```text
你是一个软件开发 Agent。

请完成以下工作：

1. 检查当前工作区。
2. 从 GitHub 克隆项目：

   https://github.com/joho/godotenv.git

3. 阅读项目结构和现有测试。
4. 选择一个范围小、可以通过测试验证的代码改进。
5. 先说明准备修改的文件和实现方案。
6. 执行代码修改。
7. 增加或更新相关单元测试。
8. 执行项目测试。
9. 输出 git diff 和修改总结。

约束：

- 不要修改 Git Remote。
- 不要推送代码。
- 不要删除现有测试。
- 不要修改与任务无关的文件。
- 所有修改都保留在当前工作区。
```

验收：

```bash
cd /data/workspace/godotenv

git status
git diff
```

确认 Developer 的修改实际写入共享 PVC。

## 10.4 第二步：启动两个 Reviewer

Reviewer 1：

```bash
openshell sandbox create \
  --name pi-review-1 \
  --from pi-agent:poc \
  --provider <model-provider> \
  --driver-config-json '<reviewer-readonly-pvc-config>' \
  -- pi
```

Reviewer 2：

```bash
openshell sandbox create \
  --name pi-review-2 \
  --from pi-agent:poc \
  --provider <model-provider> \
  --driver-config-json '<reviewer-readonly-pvc-config>' \
  -- pi
```

两个 Reviewer 使用相同的 Workspace，但都是只读权限。

Reviewer 1 任务：

```text
你是独立代码审查 Agent。

请审查：

/data/workspace/godotenv

重点：

1. 代码正确性。
2. API 兼容性。
3. 错误处理。
4. 边界条件。
5. 是否存在不必要的修改。

不要修改任何文件。

输出：

- Review Summary
- Findings
- Severity
- File and Line
- Suggested Fix
```

Reviewer 2 任务：

```text
你是安全审查 Agent。

请独立审查：

/data/workspace/godotenv

重点：

1. 输入处理。
2. 文件访问。
3. 环境变量处理。
4. 敏感数据泄漏。
5. 潜在命令执行风险。
6. 不安全的默认行为。

不要修改任何文件。

输出：

- Security Summary
- Findings
- Severity
- Evidence
- Recommended Fix
```

## 10.5 第三步：验证共享工作区

检查：

```bash
kubectl get pods -n tenant-a-runtime

kubectl get pvc -n tenant-a-runtime

kubectl describe pvc shared-workspace \
  -n tenant-a-runtime
```

预期：

- pi-dev 能看到并修改代码。
- pi-review-1 能看到 pi-dev 修改后的代码。
- pi-review-2 能看到相同代码。
- 两个 Reviewer 无法修改共享文件。
- 删除任意一个 Reviewer Sandbox，不影响共享 PVC。
- 删除 Developer Sandbox，不影响共享 PVC。

特别测试 Reviewer 写入：

```bash
touch /data/workspace/reviewer-test.txt
```

预期：

```text
Permission denied
```

这项测试必须真实进入 Reviewer 容器执行，不能只看 PVC YAML 中的 `readOnly` 字段。

## 10.6 第四步：对比 Agent 行为和安全观测

在三个 Agent 执行期间同时采集：

- OpenShell Gateway Trace。
- Supervisor Trace。
- Pi Agent Trace。
- OpenShell OCSF。
- Tetragon Process Events。
- Tetragon Network Events。
- Antrea 网络策略结果。
- Kubernetes Audit / Gatekeeper 拒绝事件。

期望能够还原：

```text
Task Start
    |
    v
Pi Developer Started
    |
    v
git clone
    |
    v
Code Modification
    |
    v
go test
    |
    v
Pi Reviewer 1 Started
    |
    v
Pi Reviewer 2 Started
    |
    v
Parallel Review
    |
    v
Review Results
```

每一步都能关联到具体 Sandbox。

---

# 11. 安全测试用例

| 编号 | 测试动作 | 预期结果 |
|---|---|---|
| SEC-01 | Pi Workload 直接 curl GitHub | 被网络策略阻止 |
| SEC-02 | Supervisor 代理访问批准的 GitHub | 允许 |
| SEC-03 | Pi 访问未批准域名 | OpenShell 拒绝 |
| SEC-04 | Pi 访问 Tenant B Pod | Antrea 拒绝 |
| SEC-05 | Pi 访问 Kubernetes API | 拒绝 |
| SEC-06 | Reviewer 修改共享文件 | 拒绝 |
| SEC-07 | Developer 修改共享文件 | 允许 |
| SEC-08 | Tenant A 访问 Tenant B Gateway | 拒绝 |
| SEC-09 | 租户创建 privileged Pod | Gatekeeper 拒绝 |
| SEC-10 | 租户创建不受授权的 Sandbox CR | Gatekeeper / RBAC 拒绝 |
| SEC-11 | Agent 尝试读取 Provider Token | 拒绝 |
| SEC-12 | Supervisor 失去 Gateway 连接 | Fail Closed |
| SEC-13 | 通过其他进程绕过 Agent 工具调用直接访问网络 | 不允许绕过 Supervisor |
| SEC-14 | 使用未批准的 PVC | OpenShell Resource Admission 拒绝 |

每项测试至少保留：

- 测试时间。
- Tenant。
- Sandbox ID。
- 操作命令。
- 实际返回结果。
- OpenShell 日志。
- Tetragon 事件。
- Antrea 策略结果。

---

# 12. OpenTelemetry 数据设计

## 12.1 统一关联属性

建议定义统一的资源属性：

```text
platform.tenant.id
platform.gateway.id
platform.workspace.id
platform.task.id
platform.agent.id
platform.agent.role

openshell.gateway.name
openshell.sandbox.id

k8s.namespace.name
k8s.pod.name
k8s.pod.uid
k8s.container.name
```

## 12.2 三种主要数据

| 数据源 | 信号 | 用途 |
|---|---|---|
| Pi | Traces | 模型调用、工具调用、Agent 生命周期 |
| OpenShell | Traces | Gateway、Sandbox、Supervisor 生命周期 |
| OpenShell | OCSF Logs | 策略决策、安全事件 |
| Tetragon | Logs | 进程和网络行为 |
| Antrea | 网络事件/流量记录 | 网络访问和拒绝分析 |
| Kubernetes | Events / Audit | 资源创建、修改和准入结果 |

## 12.3 安全事件关联

例如：

```text
Tenant: tenant-a

Gateway: tenant-a-gateway

Workspace: poc-code-review

Sandbox: pi-review-1

Pod UID: xxxxx

Process:
  /usr/local/bin/node

Child Process:
  /usr/bin/git

Network:
  github.com:443

Action:
  Allowed
```

期望从安全观测界面可以定位：

- 哪个租户。
- 哪个 Gateway。
- 哪个 Sandbox。
- 哪个 Agent。
- 执行了哪个进程。
- 访问了哪个目标。
- OpenShell 是否允许。
- Antrea 是否允许。
- 对应的 Agent Trace。

---

# 13. PoC 验收标准

## 13.1 功能验收

| 项目 | 验收标准 |
|---|---|
| 独立 Gateway | 两个租户可分别管理自己的 Gateway |
| Sandbox | 一个 Gateway 创建多个 Pi Sandbox |
| Workspace | 多个 Sandbox 共享一个项目 PVC |
| Git | Developer 成功 Clone GitHub 项目 |
| 修改 | Developer 能够完成实际代码修改 |
| Review | 两个 Reviewer 能同时读取修改结果 |
| ReadOnly | Reviewer 无法写入共享工作区 |
| 生命周期 | 单个 Sandbox 删除不影响其他 Sandbox |
| 租户隔离 | Tenant A 无法访问 Tenant B Runtime |

## 13.2 安全验收

- Workload 无法绕过 Supervisor 直接访问网络。
- OpenShell 策略能够拒绝未授权域名。
- Antrea 能够隔离不同 Tenant。
- Gatekeeper 能阻止不安全 Pod。
- Provider 凭证不会出现在 Agent 环境和普通日志中。
- 外部 PVC 必须经过 OpenShell Resource Admission。
- Tetragon 能观察到 Agent 进程执行和外部连接。

## 13.3 可观测性验收

- Pi Agent Trace 可以被采集。
- OpenShell Gateway Trace 可以被采集。
- Supervisor Trace 可以被采集。
- OpenShell OCSF 安全事件可以被采集。
- Tetragon JSON / gRPC 事件能够进入统一安全日志平台。
- 事件可以根据 Sandbox ID 和 Pod UID 关联。
- 不同租户的数据可以被隔离查询。

---

# 14. 最终设计报告

PoC 执行完成后，输出以下设计报告。

## 14.1 报告结构

1. 项目背景和验证目标。
2. 测试环境和软件版本清单。
3. 整体架构图。
4. 每租户独立 Gateway 部署验证。
5. Capsule 租户隔离验证。
6. Antrea 网络策略验证。
7. Gatekeeper 准入控制验证。
8. OpenShell Sandbox 生命周期验证。
9. 多 Pi 共享 Workspace 验证。
10. Pi GitHub Clone 和代码修改结果。
11. 多 Pi 并行 Review 结果。
12. Tetragon eBPF 行为观测结果。
13. OpenTelemetry Trace 数据分析。
14. OpenShell OCSF 安全事件分析。
15. 组件间事件关联效果。
16. 已发现的问题和限制。
17. 生产环境架构建议。
18. 后续实施计划。

## 14.2 必须保留的证据

```text
poc-output/
├── environment/
│   ├── kind-config.yaml
│   ├── component-versions.txt
│   └── cluster-status.txt
│
├── manifests/
│   ├── capsule/
│   ├── antrea/
│   ├── gatekeeper/
│   ├── tetragon/
│   └── openshell/
│
├── runtime/
│   ├── gateway-a.yaml
│   ├── workspace-pvc.yaml
│   ├── sandbox-list.txt
│   └── sandbox-describe/
│
├── agent/
│   ├── developer-trace.json
│   ├── reviewer-1-trace.json
│   ├── reviewer-2-trace.json
│   ├── developer-diff.patch
│   └── review-results/
│
├── security/
│   ├── tetragon-events.jsonl
│   ├── openshell-ocsf.jsonl
│   ├── antrea-policy-results/
│   ├── gatekeeper-denials/
│   └── security-test-results.md
│
└── report/
    ├── architecture.md
    ├── test-results.md
    └── final-design-report.md
```

## 14.3 最终报告需要回答的问题

1. 每个租户是否真的可以独立管理 Gateway？
2. Gateway 是否能够只管理自己租户的 Sandbox？
3. 一个 Workspace 是否可以被多个 Pi Sandbox 安全共享？
4. 多 Agent 的读写权限是否可以独立控制？
5. OpenShell 是否能防止 Agent 直接出网？
6. Antrea 是否能够提供额外的网络隔离？
7. Tetragon 能否观察 Agent 的真实进程行为？
8. Pi、Gateway、Supervisor 的 Trace 是否完整？
9. Tetragon 和 OpenShell 事件是否能够与 Agent Trace 关联？
10. 当前架构距离生产部署还有哪些差距？

最终输出：

**《Kubernetes Multi-Tenant AI Agent Runtime 安全与可观测性架构设计报告》**

报告必须区分：

- 已通过验证的能力。
- 部分通过的能力。
- 尚未验证的能力。
- 已发现的限制。
- 生产部署前必须解决的问题。

不得把设计预期写成实际测试结果。

---

# 15. 实施顺序

建议按以下顺序推进：

| 阶段 | 工作 | 交付 |
|---|---|---|
| Phase 1 | Kind + Antrea + Capsule + Gatekeeper | 基础集群 |
| Phase 2 | Agent Sandbox + OpenShell Gateway | Pi Sandbox 可启动 |
| Phase 3 | RWX PVC + 多 Sandbox 共享 | Workspace 验证 |
| Phase 4 | Pi + GitHub + 代码修改 + Review | 业务流程验证 |
| Phase 5 | Tetragon + OTel | 安全观测验证 |
| Phase 6 | 安全攻击测试和数据关联 | 测试证据 |
| Phase 7 | 整理结果和问题 | 正式设计报告 |

建议不要同时调试所有组件。先把一个 Pi Sandbox 成功运行起来，再验证共享存储，最后接入观测系统。

---

# 16. 生产架构方向

如果 PoC 全部通过，生产环境建议保持：

```text
Platform
   |
   +---- Capsule Tenant
   |
   +---- Tenant Gateway Controller
   |
   +---- Antrea Policy Controller
   |
   +---- Gatekeeper
   |
   +---- Tetragon DaemonSet
   |
   +---- OpenTelemetry Collector
              |
              +---- Trace Backend
              |
              +---- Security Event Backend

Tenant A
   |
   +---- Gateway A
   |
   +---- Runtime Namespace A
   |
   +---- Workspace PVC A
   |
   +---- Pi / Claude / Qwen / Browser Agents

Tenant B
   |
   +---- Gateway B
   |
   +---- Runtime Namespace B
   |
   +---- Workspace PVC B
   |
   +---- Agents
```

平台只管理租户 Gateway 的部署、配额和安全边界。

租户通过自己的 Gateway 管理 Workspace、Sandbox 和 Agent。

Tetragon 负责观察实际运行行为，OpenShell 负责 Agent 执行权限，Antrea 负责网络隔离，OpenTelemetry 负责统一遥测。

**最终目标：形成一套能够部署、隔离、执行、观测、审计和复现的 Kubernetes 多租户 Agent Runtime 基础平台。**
