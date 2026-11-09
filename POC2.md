# NVIDIA OpenShell 多租户 Agent Runtime 安全与可观测性 PoC / Multi-Tenant AI Agent Runtime Security & Observability PoC with NVIDIA OpenShell

- **项目类型 / Project type:** Kubernetes / AI Agent Runtime 技术验证 (technical validation)
- **验证环境 / Test environment:** Kind
- **参考版本 / Reference version:** NVIDIA OpenShell v0.1.7
- **Agent 运行时 / Agent runtime:** Pi Coding Agent
- **网络 / Networking:** Antrea
- **运行时安全观测 / Runtime security observability:** Cilium Tetragon
- **应用可观测性 / Application observability:** OpenTelemetry
- **准入控制 / Admission control:** OPA Gatekeeper
- **多租户管理 / Multi-tenancy:** Capsule

> **文档约定 / Document conventions:** 每段中文后紧跟对应的英文段落；表格每个单元格内中文在上、英文在下；代码块不翻译。
> Each Chinese passage is followed by its corresponding English passage; in tables the Chinese text is on top and the English below within each cell; code blocks are not translated.

> **当前状态 / Current status:** 本文是**设计与实施计划**(POC2 设计文档)。实际验证结果、证据与未完成项见
> [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md)。
> This document is the **design and implementation plan**. Actual results, evidence and open items are
> recorded in [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md).

---

## 目录 / Table of Contents

- [1. PoC 背景与目标 / Background and Goals](#s1)
- [2. 总体架构 / Overall Architecture](#s2)
- [3. Kind 测试环境 / Kind Test Environment](#s3)
- [4. OpenShell Gateway 部署 / OpenShell Gateway Deployment](#s4)
- [5. 多 Pi 共享 Workspace / Multiple Pi Sandboxes Sharing a Workspace](#s5)
- [6. Pi Agent 镜像和 OpenTelemetry / Pi Agent Image and OpenTelemetry](#s6)
- [7. Tetragon 安全观测 / Tetragon Security Observability](#s7)
- [8. OpenShell OTel 配置 / OpenShell OTel Configuration](#s8)
- [9. Antrea 网络隔离验证 / Antrea Network Isolation Validation](#s9)
- [10. 核心业务场景：Pi GitHub Code Review / Core Scenario: Pi GitHub Code Review](#s10)
- [11. 安全测试用例 / Security Test Cases](#s11)
- [12. OpenTelemetry 数据设计 / OpenTelemetry Data Design](#s12)
- [13. PoC 验收标准 / PoC Acceptance Criteria](#s13)
- [14. 最终设计报告 / Final Design Report](#s14)
- [15. 实施顺序 / Implementation Order](#s15)
- [16. 生产架构方向 / Production Architecture Direction](#s16)

---

<a id="s1"></a>
# 1. PoC 背景与目标 / Background and Goals

## 1.1 项目背景 / Project Background

本 PoC 验证基于 Kubernetes 构建多租户 AI Agent Runtime 平台的可行性。

This PoC validates the feasibility of building a multi-tenant AI Agent Runtime platform on Kubernetes.

平台为每个租户提供独立的 NVIDIA OpenShell Gateway，由租户通过自己的 Gateway 创建和管理 Workspace、Sandbox 及 Agent。

The platform provides each tenant with an independent NVIDIA OpenShell Gateway, through which the tenant creates and manages its own Workspaces, Sandboxes and Agents.

平台继续使用已有的 Kubernetes 基础设施：

The platform continues to use the existing Kubernetes infrastructure:

- Capsule：租户管理和 Namespace 归属。
  Capsule: tenant management and Namespace ownership.
- Antrea：租户网络隔离和微分段。
  Antrea: tenant network isolation and micro-segmentation.
- OPA Gatekeeper：Kubernetes 资源准入与安全约束。
  OPA Gatekeeper: Kubernetes resource admission and security constraints.
- Cilium Tetragon：基于 eBPF 的运行时行为观测。
  Cilium Tetragon: eBPF-based runtime behavior observability.
- OpenTelemetry：Agent、Gateway 和 Supervisor 的统一遥测。
  OpenTelemetry: unified telemetry for Agents, Gateways and Supervisors.
- NVIDIA OpenShell：Agent 安全执行环境。
  NVIDIA OpenShell: secure execution environment for Agents.

本次 PoC 不开发完整的 Runtime SaaS 平台，重点验证各个组件之间的集成关系，以及是否能够形成完整的 Agent 安全执行和审计链路。

This PoC does not build a complete Runtime SaaS platform. It focuses on validating the integration between the components and whether they can form an end-to-end chain for secure Agent execution and auditing.

## 1.2 核心目标 / Core Goals

| 编号 / ID | 验证目标 / Goal | 预期结果 / Expected result |
|---|---|---|
| POC-01 | 每租户独立 Gateway<br>Per-tenant independent Gateway | 租户拥有独立 Gateway 和管理状态<br>Each tenant owns an independent Gateway and its own management state |
| POC-02 | Capsule 租户隔离<br>Capsule tenant isolation | 租户只能使用自己的 Runtime Namespace<br>A tenant can only use its own Runtime Namespace |
| POC-03 | OpenShell Sandbox | Gateway 可以创建和管理多个 Pi Sandbox<br>A Gateway can create and manage multiple Pi Sandboxes |
| POC-04 | Workspace 共享<br>Shared Workspace | 多个 Sandbox 可以访问同一个项目工作区<br>Multiple Sandboxes can access the same project workspace |
| POC-05 | Antrea 网络隔离<br>Antrea network isolation | Agent 无法绕过 Supervisor 直接访问未授权网络<br>An Agent cannot bypass the Supervisor to reach unauthorized networks |
| POC-06 | Gatekeeper 准入控制<br>Gatekeeper admission control | 阻止不安全的 Kubernetes 资源创建<br>Unsafe Kubernetes resource creation is blocked |
| POC-07 | Tetragon 行为观测<br>Tetragon behavior observability | 观察 Agent 进程执行和网络连接<br>Observe Agent process execution and network connections |
| POC-08 | Agent OpenTelemetry | 采集 Pi 的模型调用和工具执行 Trace<br>Collect traces of Pi model calls and tool execution |
| POC-09 | OpenShell 遥测<br>OpenShell telemetry | 采集 Gateway、Supervisor 和 OCSF 安全事件<br>Collect Gateway, Supervisor and OCSF security events |
| POC-10 | 多 Agent 协作<br>Multi-agent collaboration | 一个 Agent 修改代码，多个 Agent 并行 Review<br>One Agent modifies code while multiple Agents review in parallel |
| POC-11 | 安全事件关联<br>Security event correlation | 根据 Tenant、Gateway、Workspace、Sandbox 关联多种观测数据<br>Correlate multiple observability sources by Tenant, Gateway, Workspace and Sandbox |

## 1.3 本次 PoC 不验证的内容 / Out of Scope

以下内容不纳入第一阶段：

The following items are out of scope for the first phase:

- 生产级 Gateway 高可用。
  Production-grade Gateway high availability.
- 多集群 Gateway 调度。
  Multi-cluster Gateway scheduling.
- 大规模 Agent 并发性能。
  Large-scale Agent concurrency performance.
- GPU 资源调度。
  GPU resource scheduling.
- 多租户计费。
  Multi-tenant billing.
- 生产级身份认证集成。
  Production-grade identity authentication integration.
- 完整的自动化 Multi-Agent Orchestrator。
  A complete automated Multi-Agent Orchestrator.
- 生产环境的 eBPF 性能开销评估。
  Evaluation of eBPF performance overhead in production.

这些内容放入后续设计阶段。

These items are deferred to a later design phase.

---

<a id="s2"></a>
# 2. 总体架构 / Overall Architecture

## 2.1 逻辑架构 / Logical Architecture

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

Security and observability components:

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

## 2.2 Kubernetes Namespace 规划 / Namespace Layout

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

Notes:

- 每个租户独立部署 OpenShell Gateway。
  Each tenant gets its own OpenShell Gateway deployment.
- 每个租户有独立的 Gateway Namespace。
  Each tenant has a dedicated Gateway Namespace.
- 每个租户有独立的 Runtime Namespace。
  Each tenant has a dedicated Runtime Namespace.
- Agent Sandbox Controller 全集群部署一次。
  The Agent Sandbox Controller is deployed once per cluster.
- Tetragon DaemonSet 全集群部署一次。
  The Tetragon DaemonSet is deployed once per cluster.
- OTel Collector 可以集中部署，但需要按租户和 Sandbox 身份进行数据隔离。
  The OTel Collector can be deployed centrally, but data must be isolated by tenant and Sandbox identity.

## 2.3 OpenShell Workspace 模式 / OpenShell Workspace Mode

本 PoC 使用：

This PoC uses:

`workspaceMode: shared`

原因：

Rationale:

当前一个 Gateway 只服务一个租户，所有 Workspace Sandbox 都放在该租户专属的 Runtime Namespace。

Currently, one Gateway serves exactly one tenant, and all Workspace Sandboxes live in that tenant's dedicated Runtime Namespace.

因此不需要使用 operator 模式来管理多个预创建 Namespace。

Therefore the operator mode, which manages multiple pre-created Namespaces, is not needed.

如果未来一个 Gateway 要管理多个不同 Runtime Namespace，再验证 operator 模式。

If a future design needs one Gateway to manage multiple different Runtime Namespaces, the operator mode should be validated then.

---

<a id="s3"></a>
# 3. Kind 测试环境 / Kind Test Environment

## 3.1 环境要求 / Requirements

建议：

Recommended:

| 资源 / Resource | 建议 / Recommendation |
|---|---|
| CPU | 8 Core 以上<br>8 cores or more |
| Memory | 16 GB 以上<br>16 GB or more |
| Disk | 40 GB 以上<br>40 GB or more |
| Kubernetes | 1.32 或兼容的 1.29+ 版本<br>1.32, or a compatible 1.29+ release |
| Kind | 0.20+ |
| Helm | Helm 3 |
| Docker | Docker Engine / Docker Desktop |
| Linux Kernel | 5.10+，建议具备 BTF<br>5.10+, with BTF recommended |

注意：Tetragon 需要宿主 Linux Kernel 支持 eBPF 和 BTF。Mac 上运行 Kind 时，实际观察的是 Docker Desktop Linux VM 的内核，而不是 macOS 内核。

Note: Tetragon requires the host Linux kernel to support eBPF and BTF. When Kind runs on a Mac, the kernel being observed is the one of the Docker Desktop Linux VM, not the macOS kernel.

先检查：

Check first:

```bash
uname -r

ls -l /sys/kernel/btf/vmlinux

docker info
```

如果没有 BTF，先解决内核 BTF 问题，不要继续排查 Tetragon 配置。

If BTF is missing, fix the kernel BTF problem first instead of continuing to debug Tetragon configuration.

## 3.2 创建 Kind 集群 / Creating the Kind Cluster

创建 `kind.yaml`：

Create `kind.yaml`:

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

Create the cluster:

```bash
kind create cluster \
  --config kind.yaml \
  --wait 120s
```

检查：

Verify:

```bash
kubectl get nodes
kubectl cluster-info
```

> **实际配置 / Actual configuration:** 本轮执行使用 [`poc/kind/poc2-cluster.yaml`](poc/kind/poc2-cluster.yaml)，
> 额外包含外部访问所需的 `apiServerAddress` / `apiServerPort` / `certSANs` / `extraPortMappings`；
> 完整条件见 [`poc/kind/README-external-access.md`](poc/kind/README-external-access.md)。
> This round was executed with [`poc/kind/poc2-cluster.yaml`](poc/kind/poc2-cluster.yaml), which additionally carries
> `apiServerAddress` / `apiServerPort` / `certSANs` / `extraPortMappings` for external access; full conditions are in
> [`poc/kind/README-external-access.md`](poc/kind/README-external-access.md).

## 3.3 安装 Antrea / Installing Antrea

Kind 不安装默认 CNI，使用 Antrea 作为唯一 CNI。

Kind installs no default CNI; Antrea is used as the only CNI.

```bash
helm repo add antrea https://charts.antrea.io

helm repo update
```

安装：

Install:

```bash
export ANTREA_VERSION=<选定并记录的版本>

helm upgrade --install antrea antrea/antrea \
  --namespace kube-system \
  --version "${ANTREA_VERSION}"
```

等待：

Wait for rollout:

```bash
kubectl rollout status daemonset/antrea-agent \
  -n kube-system

kubectl get pods -n kube-system
```

验证 Pod 网络：

Verify Pod networking:

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

**验收 / Acceptance:** 所有节点 Ready，Pod 网络正常，NetworkPolicy 的 ingress 和 egress 均能实际执行。
All nodes are Ready, Pod networking works, and NetworkPolicy ingress and egress are actually enforced.

不要只检查 NetworkPolicy 对象是否创建成功，必须用实际网络连接验证。

Do not merely check that NetworkPolicy objects were created; verify with real network connections.

## 3.4 安装 Capsule / Installing Capsule

```bash
helm repo add projectcapsule \
  https://projectcapsule.github.io/charts

helm repo update
```

安装：

Install:

```bash
helm upgrade --install capsule \
  projectcapsule/capsule \
  --namespace capsule-system \
  --create-namespace
```

创建 Tenant：

Create a Tenant:

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

Apply:

```bash
kubectl apply -f tenant-a.yaml
kubectl get tenants
```

后续由平台管理员创建 Gateway 和 Runtime Namespace，并确保这些 Namespace 归属于正确 Tenant。

The platform administrator then creates the Gateway and Runtime Namespaces and ensures those Namespaces belong to the correct Tenant.

## 3.5 安装 Gatekeeper / Installing Gatekeeper

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

Verify:

```bash
kubectl get pods -n gatekeeper-system
kubectl get crd | grep gatekeeper
```

本次至少验证：

This PoC at minimum validates:

- 禁止 privileged 容器。
  Privileged containers are denied.
- 禁止 hostNetwork。
  hostNetwork is denied.
- 禁止 hostPID。
  hostPID is denied.
- 禁止不受控 hostPath。
  Uncontrolled hostPath is denied.
- 禁止租户使用平台专用 ServiceAccount。
  Tenants are denied the use of platform-only ServiceAccounts.
- 禁止租户直接创建和修改 OpenShell Sandbox 资源。
  Tenants are denied direct creation or modification of OpenShell Sandbox resources.
- 要求 Runtime 工作负载有资源 requests/limits。
  Runtime workloads must declare resource requests/limits.

Gatekeeper 的规则要针对租户用户身份精确生效，不要因为 OpenShell Controller 需要管理资源，就对整个 Runtime Namespace 做宽泛豁免。

Gatekeeper rules must apply precisely to tenant user identities. Do not grant a blanket exemption to the whole Runtime Namespace just because the OpenShell Controller needs to manage resources.

## 3.6 安装 Agent Sandbox Controller / Installing the Agent Sandbox Controller

OpenShell Kubernetes Driver 依赖 Kubernetes SIG Agent Sandbox。

The OpenShell Kubernetes Driver depends on the Kubernetes SIG Agent Sandbox.

```bash
export AGENT_SANDBOX_VERSION=<选定并记录的版本>

kubectl apply -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox.yaml"
```

等待：

Wait for rollout:

```bash
kubectl rollout status deployment/agent-sandbox-controller \
  -n agent-sandbox-system \
  --timeout=120s

kubectl get crd sandboxes.agents.x-k8s.io
```

必须确认 OpenShell 使用的 Sandbox API 版本与已安装的 Agent Sandbox CRD 兼容。

Confirm that the Sandbox API version used by OpenShell is compatible with the installed Agent Sandbox CRD.

## 3.7 安装 Tetragon / Installing Tetragon

Tetragon 以 DaemonSet 形式运行。

Tetragon runs as a DaemonSet.

```bash
helm repo add cilium https://helm.cilium.io

helm repo update
```

安装：

Install:

```bash
export TETRAGON_VERSION=<选定并记录的版本>

helm upgrade --install tetragon cilium/tetragon \
  --namespace kube-system \
  --version "${TETRAGON_VERSION}"
```

等待：

Wait for rollout:

```bash
kubectl rollout status daemonset/tetragon \
  -n kube-system
```

检查：

Check:

```bash
kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=tetragon
```

检查 Tetragon 事件：

Inspect Tetragon events:

```bash
kubectl exec -it \
  -n kube-system \
  ds/tetragon \
  -c tetragon -- \
  tetra getevents -o compact
```

首先确认能看到普通测试 Pod 的进程执行事件。

First confirm that process execution events from an ordinary test Pod are visible.

然后再部署 Agent。

Only then deploy the Agent.

---

<a id="s4"></a>
# 4. OpenShell Gateway 部署 / OpenShell Gateway Deployment

## 4.1 创建租户 Namespace / Creating Tenant Namespaces

```bash
kubectl create namespace tenant-a-gateway

kubectl create namespace tenant-a-runtime
```

确认 Namespace 归属 Capsule Tenant A。

Confirm that the Namespaces belong to Capsule Tenant A.

建议标签：

Suggested labels:

```yaml
metadata:
  labels:
    platform.example.com/tenant: tenant-a
    platform.example.com/runtime: "true"
```

这些标签由平台管理，租户不可自行修改。

These labels are managed by the platform and cannot be modified by tenants.

## 4.2 安装 Gateway / Installing the Gateway

本次固定 OpenShell v0.1.7，所有镜像、Chart 和 CLI 版本需要保持兼容。

This PoC pins OpenShell v0.1.7; all images, charts and CLI versions must stay compatible.

Gateway 和 Workspace 资源分开安装：

Gateway and Workspace resources are installed separately:

```bash
helm upgrade --install openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.1.7 \
  --namespace tenant-a-gateway \
  --set workspaceResources.enabled=false \
  --set server.sandboxNamespace=tenant-a-runtime
```

## 4.3 安装 Workspace 资源 / Installing Workspace Resources

```bash
helm upgrade --install openshell-workspace \
  oci://ghcr.io/nvidia/openshell/openshell-workspace \
  --version 0.1.7 \
  --namespace tenant-a-runtime \
  --set gateway.serviceAccount.name=openshell \
  --set gateway.serviceAccount.namespace=tenant-a-gateway
```

本 PoC 使用 shared Workspace Namespace。

This PoC uses the shared Workspace Namespace.

需要特别注意：Gateway 和 Workspace Chart 分开安装时，Workspace Chart 不负责创建 Namespace 或 Gateway，它负责 Workspace Namespace 中的 Sandbox ServiceAccount、Role、RoleBinding 和 NetworkPolicy。

Note carefully: when the Gateway and Workspace charts are installed separately, the Workspace chart does not create the Namespace or the Gateway. It creates the Sandbox ServiceAccount, Role, RoleBinding and NetworkPolicy inside the Workspace Namespace.

## 4.4 开启外部 PVC 挂载能力 / Enabling External PVC Mounts

为了让多个 Pi Sandbox 访问同一份 Workspace，需要使用 Kubernetes Driver 的 PVC Mount 配置。

To let multiple Pi Sandboxes access the same Workspace, the Kubernetes Driver's PVC mount configuration is required.

Gateway 侧：

Gateway side:

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

Workspace chart side:

```yaml
gateway:
  allowDriverConfig: true
```

以上是配置结构示意，实际 values 文件需要按 v0.1.7 Chart 的字段结构合并，并用 `helm template` 检查。

The above only illustrates the configuration structure. The actual values file must be merged according to the v0.1.7 chart's field structure and checked with `helm template`.

**不要关闭 resource admission 来图省事。**

**Do not disable resource admission just to save effort.**

外部 PVC 必须经过 OpenShell 的授权标签检查。这里 `${workspace}` 指 OpenShell Workspace 名称，而不是 Kubernetes Namespace 名称。

External PVCs must pass OpenShell's authorization label check. Here `${workspace}` refers to the OpenShell Workspace name, not the Kubernetes Namespace name.

---

<a id="s5"></a>
# 5. 多 Pi 共享 Workspace / Multiple Pi Sandboxes Sharing a Workspace

这是本次 PoC 的核心测试点。

This is the core test point of the PoC.

## 5.1 设计 / Design

创建一个共享项目目录：

Create one shared project directory:

```text
/data/workspace
    └── godotenv
```

Sandbox 规划：

Sandbox plan:

| Sandbox | Agent | Workspace 权限 / Workspace permission | 任务 / Task |
|---|---|---|---|
| pi-dev | Pi Developer | ReadWrite | Clone 和修改代码<br>Clone and modify code |
| pi-review-1 | Pi Reviewer A | ReadOnly | 代码质量 Review<br>Code-quality review |
| pi-review-2 | Pi Reviewer B | ReadOnly | 安全 Review<br>Security review |

三个 Sandbox 使用同一个 PVC。

All three Sandboxes use the same PVC.

但是权限不同：

But with different permissions:

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

This validates the shared workspace while preventing Reviewers from modifying the Developer's code.

## 5.2 PVC 存储 / PVC Storage

创建 `workspace-pvc.yaml`：

Create `workspace-pvc.yaml`:

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

Kind's default local-path StorageClass does not provide a real RWX shared filesystem.

因此需要在 Kind 中安装 NFS Server + NFS Subdir External Provisioner，创建一个支持 RWX 的 StorageClass。

Therefore install an NFS Server plus the NFS Subdir External Provisioner in Kind to create an RWX-capable StorageClass.

不要把 PVC 声明为 RWX 就当作底层存储已经支持 RWX。

Do not mistake declaring a PVC as RWX for the underlying storage actually supporting RWX.

验收：

Acceptance:

```bash
kubectl get storageclass
kubectl get pvc -n tenant-a-runtime
```

## 5.3 Sandbox PVC 挂载 / Sandbox PVC Mounts

开发 Agent：

Developer Agent:

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

Reviewer Agent:

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

Notes:

- 挂载路径使用 `/data/workspace`。
  The mount path is `/data/workspace`.
- 不覆盖 `/.openshell`、`/run` 等受保护目录。
  Do not override protected directories such as `/.openshell` and `/run`.
- 本 PoC 不将外部 PVC 挂载到 `/sandbox`，避免替换 OpenShell 默认工作区 PVC。
  This PoC does not mount the external PVC at `/sandbox`, which would replace the default OpenShell workspace PVC.
- 每个 Sandbox 使用自己的 OpenShell 策略。
  Each Sandbox uses its own OpenShell policy.
- Developer 的策略允许写入 `/data/workspace`。
  The Developer policy allows writes to `/data/workspace`.
- Reviewer 的策略只允许读取 `/data/workspace`。
  The Reviewer policy allows only reads from `/data/workspace`.

> **实测补充 / Field note:** 仅把 PVC 挂进来还不够。OpenShell 的文件系统策略基线只覆盖
> `/bin /usr /lib /proc /dev/urandom /etc /var/log`(只读)与 `/tmp /dev/null`(读写)，**不含 `/data`**；
> `/data/workspace` 必须显式写进该 Sandbox 的策略，否则容器内会得到与 Unix 权限无关的 `Permission denied`。
> Mounting the PVC is not sufficient. OpenShell's filesystem baseline covers only `/bin /usr /lib /proc /dev/urandom /etc /var/log`
> (read-only) and `/tmp /dev/null` (read-write) — **not `/data`**. `/data/workspace` must be listed explicitly in that Sandbox's
> policy, otherwise the container returns `Permission denied` unrelated to Unix permissions.
> 详见 [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md) §3.1。

---

<a id="s6"></a>
# 6. Pi Agent 镜像和 OpenTelemetry / Pi Agent Image and OpenTelemetry

## 6.1 Pi 镜像 / Pi Image

创建 `Dockerfile.pi`：

Create `Dockerfile.pi`:

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

Pin the Pi version in real use; do not rely on an uncontrolled `latest` long-term.

构建：

Build:

```bash
docker build -t pi-agent:poc -f Dockerfile.pi .
```

把镜像加载到 Kind：

Load the image into Kind:

```bash
kind load docker-image pi-agent:poc \
  --name agent-runtime-poc
```

如果 Gateway 无法直接使用本地镜像缓存，则将镜像推送到 Gateway 能访问的 Registry。

If the Gateway cannot use the local image cache directly, push the image to a registry the Gateway can reach.

> **实测补充 / Field note:** 构建参数 `ARG` 必须写在 `FROM` 之后，否则 `${PI_VERSION}` 在构建阶段为空、版本实际没有锁住；
> 并且沙箱以 **uid 10001** 运行，镜像里的 `USER node` 会被覆盖，`ENV` 也不会注入沙箱 —— agent 目录需要在构建期准备成
> 所有 uid 可读，再由运行期脚本复制成可写副本。
> Build `ARG`s must be declared **after** `FROM`, otherwise `${PI_VERSION}` expands to empty and the version is not pinned;
> also, the sandbox runs as **uid 10001**, overriding the image's `USER node`, and image `ENV` is not injected into the sandbox —
> prepare the agent directory at build time so every uid can read it, then copy it to a writable location at runtime.

## 6.2 Pi OpenTelemetry Extension / Pi OpenTelemetry Extension

安装 Pi 的 OTel 扩展：

Install Pi's OTel extension:

```bash
pi install npm:pi-otel
```

建议锁定经过验证的版本，例如 PoC 使用 `pi-otel@0.3.0`。

Pin a validated version; this PoC uses `pi-otel@0.3.0`.

Pi 配置：

Pi configuration:

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

In the final integration, Pi should obtain its OTLP endpoint from OpenShell's Agent Trace Relay instead of bypassing the Supervisor to reach the Collector directly.

上面直接配置 Collector 的方式用于独立验证 Pi OTel 扩展；在最终集成测试中，应将 endpoint 切换为 OpenShell 提供的 Relay。

The direct-to-Collector configuration above is for validating the Pi OTel extension in isolation; in the final integration test the endpoint should be switched to the Relay provided by OpenShell.

## 6.3 需要观察的 Pi Trace / Pi Traces to Observe

期望形成：

Expected shape:

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

Each trace should be able to carry the following information:

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

The Sandbox ID should correspond to OpenShell's telemetry attribute; attributes such as Tenant and Agent Role can be added from Pod labels via the OTel Collector's Kubernetes Attributes Processor.

不要采集完整 Prompt、模型思维内容、访问 Token 或 GitHub 凭证。本次 PoC 使用 metadata_only。

Do not capture full prompts, model reasoning content, access tokens or GitHub credentials. This PoC uses `metadata_only`.

---

<a id="s7"></a>
# 7. Tetragon 安全观测 / Tetragon Security Observability

## 7.1 观测目标 / Observability Goals

Tetragon 不负责替代 OpenShell 和 Antrea 的访问控制。

Tetragon does not replace the access control provided by OpenShell and Antrea.

它的作用是从 Linux Kernel 层观察实际发生的进程和网络行为。

Its role is to observe, from the Linux kernel layer, the process and network behavior that actually happens.

重点关注：

Focus on:

| 类型 / Type | 观察内容 / What to observe |
|---|---|
| Process Exec | pi、node、git、bash、curl、go 等进程<br>Processes such as pi, node, git, bash, curl and go |
| Process Exit | 进程退出状态<br>Process exit status |
| Network Connect | 进程发起的 TCP 连接<br>TCP connections initiated by processes |
| Process Parent | Agent 启动的子进程关系<br>Parent-child relationships of processes spawned by the Agent |
| Namespace | 进程所属 Namespace<br>The Namespace a process belongs to |
| Pod Identity | 进程所属 Pod 和容器<br>The Pod and container a process belongs to |
| File Access | 后续阶段增加对关键文件访问的观察<br>Observing access to key files, added in a later phase |

## 7.2 网络观测策略 / Network Observation Policy

先使用 Tetragon 官方的网络 egress 示例：

Start from Tetragon's official network egress example:

```bash
export PODCIDR=10.244.0.0/16
export SERVICECIDR=<kind-service-cidr>

curl -fsSL \
  https://raw.githubusercontent.com/cilium/tetragon/main/examples/quickstart/network_egress_cluster.yaml \
  -o network_egress_cluster.yaml
```

渲染并应用：

Render and apply:

```bash
envsubst < network_egress_cluster.yaml \
  | kubectl apply -f -
```

观察：

Observe:

```bash
kubectl exec -it -n kube-system ds/tetragon \
  -c tetragon -- \
  tetra getevents -o compact
```

分别验证：

Validate each of the following:

1. Agent 访问 GitHub。
   The Agent accesses GitHub.
2. Agent 访问模型 API。
   The Agent accesses the model API.
3. Agent 尝试访问未授权域名。
   The Agent attempts to reach an unauthorized domain.
4. Agent 尝试访问其他 Tenant 的 Pod。
   The Agent attempts to reach another Tenant's Pod.
5. Agent 尝试直接连接外部 IP。
   The Agent attempts a direct connection to an external IP.

Tetragon 应能记录进程和网络行为，Antrea 和 OpenShell 应负责实际允许或拒绝。

Tetragon should record process and network behavior; Antrea and OpenShell are responsible for actually allowing or denying it.

## 7.3 Tetragon 与 OpenTelemetry 集成 / Tetragon and OpenTelemetry Integration

一个重要实现细节：

An important implementation detail:

Tetragon 原生主要提供 JSON 事件和 gRPC 事件接口，不应假设它自身已经提供通用 OTLP Exporter。

Tetragon natively exposes JSON events and a gRPC event interface; do not assume it ships a general-purpose OTLP exporter.

本 PoC 使用：

This PoC uses:

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

Phase 1 can use the OTel Collector Contrib Filelog Receiver to read Tetragon's JSON output.

第二阶段再开发 Go Adapter：

Phase 2 develops a Go adapter that:

- 通过 Tetragon gRPC 订阅事件。
  Subscribes to events over Tetragon gRPC.
- 转换为 OTel Logs。
  Converts them to OTel Logs.
- 添加 Kubernetes Resource Attributes。
  Adds Kubernetes resource attributes.
- 输出 OTLP。
  Exports over OTLP.
- 保留 Tetragon 原始事件字段。
  Preserves the original Tetragon event fields.

建议增加的属性：

Suggested attributes:

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

Note: Tetragon events and Pi traces do not necessarily share a trace_id. Correlate them by Sandbox ID, Pod UID, process ID and timestamp rather than fabricating a trace parent.

---

<a id="s8"></a>
# 8. OpenShell OTel 配置 / OpenShell OTel Configuration

## 8.1 Gateway Trace

Gateway 配置：

Gateway configuration:

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

This configuration must be translated into the Gateway ConfigMap through Helm's `gatewayConfig`.

## 8.2 OpenShell Agent Trace Relay

Agent Trace Relay 默认关闭。

The Agent Trace Relay is disabled by default.

开启之后：

Once enabled:

- Pi 的 OTEL Trace 经 Supervisor Relay 转发。
  Pi's OTEL traces are forwarded through the Supervisor Relay.
- Agent 不需要直接连接 Collector。
  The Agent does not need a direct connection to the Collector.
- Agent 不需要持有 Collector 的认证凭证。
  The Agent does not need credentials for the Collector.
- Trace 带有 `openshell.sandbox.id`。
  Traces carry `openshell.sandbox.id`.
- 可以与 Supervisor Trace 关联。
  They can be correlated with Supervisor traces.

本 PoC 只要求 Agent Traces，不能把 Agent Trace Relay 当作通用 Metrics / Logs Relay。

This PoC only requires Agent traces; the Agent Trace Relay must not be treated as a generic Metrics/Logs relay.

Pi 的 Metrics 和 Logs 暂时由独立配置或其他日志采集机制处理。

Pi's metrics and logs are handled by separate configuration or other log collection mechanisms for now.

## 8.3 OpenShell OCSF 安全事件 / OpenShell OCSF Security Events

开启 OCSF OTLP 输出：

Enable OCSF OTLP output:

```toml
[openshell.gateway.otlp.ocsf]
enabled = true
```

关注：

Focus on:

- 网络策略决策。
  Network policy decisions.
- HTTP 请求策略决策。
  HTTP request policy decisions.
- 进程生命周期。
  Process lifecycle.
- SSH Session。
  SSH sessions.
- Gateway 配置变更。
  Gateway configuration changes.
- Policy 修改和风险审批。
  Policy changes and risk approval.

最终应将 OCSF、Pi Trace 和 Tetragon Events 放在同一个观测平台中。

Ultimately OCSF events, Pi traces and Tetragon events belong in one observability platform.

> **实测补充 / Field note:** v0.1.7 的 chart 实际暴露的是 `ocsf_log`(JSONL 落盘)，上面这种 **OTLP 形式的 OCSF 导出在本轮未验证**。
> 本轮证据来自 Supervisor 日志中的 OCSF 行，以及 collector 的 `file_log` 采集。详见结论文档 §2。
> The v0.1.7 chart actually exposes `ocsf_log` (JSONL files); the **OTLP form of OCSF export above was not verified in this round**.
> This round's evidence came from OCSF lines in Supervisor logs and the collector's `file_log` receiver. See the conclusions doc §2.

---

<a id="s9"></a>
# 9. Antrea 网络隔离验证 / Antrea Network Isolation Validation

## 9.1 网络模型 / Network Model

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

## 9.2 网络验证矩阵 / Network Validation Matrix

| 来源 / Source | 目标 / Destination | 预期 / Expected |
|---|---|---|
| Pi Workload | Supervisor Boundary | ALLOW |
| Pi Workload | GitHub | DENY（直接连接）<br>DENY (direct connection) |
| Pi Workload | Internet | DENY（直接连接）<br>DENY (direct connection) |
| Supervisor | Gateway | ALLOW |
| Supervisor | GitHub | 按 OpenShell Policy 控制<br>Governed by the OpenShell policy |
| Supervisor | Model API | ALLOW |
| Tenant A | Tenant B Runtime | DENY |
| Tenant A | Tenant B Gateway | DENY |
| Pi Reviewer | shared-workspace | READ |
| Pi Reviewer | shared-workspace 写入<br>shared-workspace write | DENY |

特别注意：OpenShell 的 Sandbox 网络策略依赖 CNI 真正执行 NetworkPolicy。Antrea 必须完成实际网络测试，不能只检查规则对象。

Note carefully: OpenShell's Sandbox network policy relies on the CNI actually enforcing NetworkPolicy. Antrea must be validated with real network tests, not by inspecting rule objects alone.

同时需要验证 Antrea 现有 Allow 规则与 OpenShell 自动生成的 NetworkPolicy 之间的最终执行效果。

Also validate the combined effect of Antrea's existing Allow rules and the NetworkPolicies OpenShell generates automatically.

---

<a id="s10"></a>
# 10. 核心业务场景：Pi GitHub Code Review / Core Scenario: Pi GitHub Code Review

这是整个 PoC 的主要业务测试。

This is the main business-level test of the whole PoC.

## 10.1 测试项目 / Test Project

建议使用一个公开的 GitHub 项目：

A public GitHub project is recommended:

```text
https://github.com/joho/godotenv.git
```

项目代码克隆到：

The project is cloned to:

```text
/data/workspace/godotenv
```

本次不需要 GitHub 写入 Token，不推送修改到原始仓库。

No GitHub write token is needed, and changes are not pushed to the upstream repository.

模型服务使用一个可通过 OpenShell Provider 访问的 OpenAI-compatible 或 Anthropic-compatible Endpoint。

The model service is an OpenAI-compatible or Anthropic-compatible endpoint reachable through an OpenShell Provider.

## 10.2 Sandbox 规划 / Sandbox Plan

创建三个独立 Pi Sandbox：

Create three independent Pi Sandboxes:

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

All three Sandboxes must mount the same PVC.

## 10.3 第一步：Developer Clone 项目 / Step 1: Developer Clones the Project

启动 Pi Developer：

Start the Pi Developer:

```bash
openshell sandbox create \
  --name pi-dev \
  --from pi-agent:poc \
  --provider <model-provider> \
  --driver-config-json '<developer-pvc-config>' \
  -- pi
```

给 Pi 的任务：

Task given to Pi:

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

English equivalent:

```text
You are a software development Agent.

Complete the following work:

1. Inspect the current workspace.
2. Clone the project from GitHub:

   https://github.com/joho/godotenv.git

3. Read the project structure and existing tests.
4. Choose a small, test-verifiable code improvement.
5. First state which files you intend to change and your implementation plan.
6. Perform the code changes.
7. Add or update the relevant unit tests.
8. Run the project's tests.
9. Output git diff and a summary of the changes.

Constraints:

- Do not modify the Git remote.
- Do not push code.
- Do not delete existing tests.
- Do not modify files unrelated to the task.
- Keep all changes in the current workspace.
```

验收：

Acceptance:

```bash
cd /data/workspace/godotenv

git status
git diff
```

确认 Developer 的修改实际写入共享 PVC。

Confirm that the Developer's changes are actually written to the shared PVC.

## 10.4 第二步：启动两个 Reviewer / Step 2: Starting the Two Reviewers

Reviewer 1：

Reviewer 1:

```bash
openshell sandbox create \
  --name pi-review-1 \
  --from pi-agent:poc \
  --provider <model-provider> \
  --driver-config-json '<reviewer-readonly-pvc-config>' \
  -- pi
```

Reviewer 2：

Reviewer 2:

```bash
openshell sandbox create \
  --name pi-review-2 \
  --from pi-agent:poc \
  --provider <model-provider> \
  --driver-config-json '<reviewer-readonly-pvc-config>' \
  -- pi
```

两个 Reviewer 使用相同的 Workspace，但都是只读权限。

Both Reviewers use the same Workspace, with read-only permission.

Reviewer 1 任务：

Reviewer 1 task:

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

English equivalent:

```text
You are an independent code review Agent.

Review:

/data/workspace/godotenv

Focus on:

1. Code correctness.
2. API compatibility.
3. Error handling.
4. Edge cases.
5. Whether there are unnecessary changes.

Do not modify any file.

Output:

- Review Summary
- Findings
- Severity
- File and Line
- Suggested Fix
```

Reviewer 2 任务：

Reviewer 2 task:

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

English equivalent:

```text
You are a security review Agent.

Independently review:

/data/workspace/godotenv

Focus on:

1. Input handling.
2. File access.
3. Environment variable handling.
4. Sensitive data leakage.
5. Potential command execution risks.
6. Insecure default behavior.

Do not modify any file.

Output:

- Security Summary
- Findings
- Severity
- Evidence
- Recommended Fix
```

## 10.5 第三步：验证共享工作区 / Step 3: Validating the Shared Workspace

检查：

Check:

```bash
kubectl get pods -n tenant-a-runtime

kubectl get pvc -n tenant-a-runtime

kubectl describe pvc shared-workspace \
  -n tenant-a-runtime
```

预期：

Expected:

- pi-dev 能看到并修改代码。
  pi-dev can see and modify the code.
- pi-review-1 能看到 pi-dev 修改后的代码。
  pi-review-1 can see the code modified by pi-dev.
- pi-review-2 能看到相同代码。
  pi-review-2 can see the same code.
- 两个 Reviewer 无法修改共享文件。
  Neither Reviewer can modify the shared files.
- 删除任意一个 Reviewer Sandbox，不影响共享 PVC。
  Deleting either Reviewer Sandbox does not affect the shared PVC.
- 删除 Developer Sandbox，不影响共享 PVC。
  Deleting the Developer Sandbox does not affect the shared PVC.

特别测试 Reviewer 写入：

Specifically test a Reviewer write:

```bash
touch /data/workspace/reviewer-test.txt
```

预期：

Expected:

```text
Permission denied
```

这项测试必须真实进入 Reviewer 容器执行，不能只看 PVC YAML 中的 `readOnly` 字段。

This test must be executed inside the Reviewer container; do not settle for the `readOnly` field in the PVC YAML.

## 10.6 第四步：对比 Agent 行为和安全观测 / Step 4: Comparing Agent Behavior with Security Observability

在三个 Agent 执行期间同时采集：

While the three Agents run, collect all of the following:

- OpenShell Gateway Trace。
  OpenShell Gateway traces.
- Supervisor Trace。
  Supervisor traces.
- Pi Agent Trace。
  Pi Agent traces.
- OpenShell OCSF。
  OpenShell OCSF events.
- Tetragon Process Events。
  Tetragon process events.
- Tetragon Network Events。
  Tetragon network events.
- Antrea 网络策略结果。
  Antrea network policy outcomes.
- Kubernetes Audit / Gatekeeper 拒绝事件。
  Kubernetes audit / Gatekeeper denial events.

期望能够还原：

Expected to reconstruct:

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

Every step can be tied back to a specific Sandbox.

---

<a id="s11"></a>
# 11. 安全测试用例 / Security Test Cases

| 编号 / ID | 测试动作 / Test action | 预期结果 / Expected result |
|---|---|---|
| SEC-01 | Pi Workload 直接 curl GitHub<br>Pi workload curls GitHub directly | 被网络策略阻止<br>Blocked by network policy |
| SEC-02 | Supervisor 代理访问批准的 GitHub<br>Supervisor proxies access to approved GitHub | 允许<br>Allowed |
| SEC-03 | Pi 访问未批准域名<br>Pi accesses an unapproved domain | OpenShell 拒绝<br>Denied by OpenShell |
| SEC-04 | Pi 访问 Tenant B Pod<br>Pi accesses a Tenant B Pod | Antrea 拒绝<br>Denied by Antrea |
| SEC-05 | Pi 访问 Kubernetes API<br>Pi accesses the Kubernetes API | 拒绝<br>Denied |
| SEC-06 | Reviewer 修改共享文件<br>Reviewer modifies a shared file | 拒绝<br>Denied |
| SEC-07 | Developer 修改共享文件<br>Developer modifies a shared file | 允许<br>Allowed |
| SEC-08 | Tenant A 访问 Tenant B Gateway<br>Tenant A accesses the Tenant B Gateway | 拒绝<br>Denied |
| SEC-09 | 租户创建 privileged Pod<br>Tenant creates a privileged Pod | Gatekeeper 拒绝<br>Denied by Gatekeeper |
| SEC-10 | 租户创建不受授权的 Sandbox CR<br>Tenant creates an unauthorized Sandbox CR | Gatekeeper / RBAC 拒绝<br>Denied by Gatekeeper / RBAC |
| SEC-11 | Agent 尝试读取 Provider Token<br>Agent attempts to read the Provider token | 拒绝<br>Denied |
| SEC-12 | Supervisor 失去 Gateway 连接<br>Supervisor loses its Gateway connection | Fail Closed |
| SEC-13 | 通过其他进程绕过 Agent 工具调用直接访问网络<br>Bypass Agent tool calls via another process to reach the network | 不允许绕过 Supervisor<br>Must not bypass the Supervisor |
| SEC-14 | 使用未批准的 PVC<br>Using an unapproved PVC | OpenShell Resource Admission 拒绝<br>Denied by OpenShell Resource Admission |

每项测试至少保留：

Each test must retain at least:

- 测试时间。
  Test timestamp.
- Tenant。
  Tenant.
- Sandbox ID。
  Sandbox ID.
- 操作命令。
  The command executed.
- 实际返回结果。
  The actual result returned.
- OpenShell 日志。
  OpenShell logs.
- Tetragon 事件。
  Tetragon events.
- Antrea 策略结果。
  Antrea policy outcomes.

---

<a id="s12"></a>
# 12. OpenTelemetry 数据设计 / OpenTelemetry Data Design

## 12.1 统一关联属性 / Unified Correlation Attributes

建议定义统一的资源属性：

Define a common set of resource attributes:

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

## 12.2 三种主要数据 / Three Main Data Categories

| 数据源 / Source | 信号 / Signal | 用途 / Purpose |
|---|---|---|
| Pi | Traces | 模型调用、工具调用、Agent 生命周期<br>Model calls, tool calls, Agent lifecycle |
| OpenShell | Traces | Gateway、Sandbox、Supervisor 生命周期<br>Gateway, Sandbox and Supervisor lifecycle |
| OpenShell | OCSF Logs | 策略决策、安全事件<br>Policy decisions and security events |
| Tetragon | Logs | 进程和网络行为<br>Process and network behavior |
| Antrea | 网络事件/流量记录<br>Network events / flow records | 网络访问和拒绝分析<br>Network access and denial analysis |
| Kubernetes | Events / Audit | 资源创建、修改和准入结果<br>Resource creation, modification and admission outcomes |

## 12.3 安全事件关联 / Security Event Correlation

例如：

For example:

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

The security observability UI should be able to pinpoint:

- 哪个租户。
  Which tenant.
- 哪个 Gateway。
  Which Gateway.
- 哪个 Sandbox。
  Which Sandbox.
- 哪个 Agent。
  Which Agent.
- 执行了哪个进程。
  Which process executed.
- 访问了哪个目标。
  Which destination was accessed.
- OpenShell 是否允许。
  Whether OpenShell allowed it.
- Antrea 是否允许。
  Whether Antrea allowed it.
- 对应的 Agent Trace。
  The corresponding Agent trace.

---

<a id="s13"></a>
# 13. PoC 验收标准 / PoC Acceptance Criteria

## 13.1 功能验收 / Functional Acceptance

| 项目 / Item | 验收标准 / Acceptance criterion |
|---|---|
| 独立 Gateway<br>Independent Gateway | 两个租户可分别管理自己的 Gateway<br>Two tenants can each manage their own Gateway |
| Sandbox | 一个 Gateway 创建多个 Pi Sandbox<br>One Gateway creates multiple Pi Sandboxes |
| Workspace | 多个 Sandbox 共享一个项目 PVC<br>Multiple Sandboxes share one project PVC |
| Git | Developer 成功 Clone GitHub 项目<br>The Developer successfully clones the GitHub project |
| 修改<br>Modification | Developer 能够完成实际代码修改<br>The Developer completes a real code modification |
| Review | 两个 Reviewer 能同时读取修改结果<br>Both Reviewers can read the modified result concurrently |
| ReadOnly | Reviewer 无法写入共享工作区<br>Reviewers cannot write to the shared workspace |
| 生命周期<br>Lifecycle | 单个 Sandbox 删除不影响其他 Sandbox<br>Deleting one Sandbox does not affect the others |
| 租户隔离<br>Tenant isolation | Tenant A 无法访问 Tenant B Runtime<br>Tenant A cannot access the Tenant B Runtime |

## 13.2 安全验收 / Security Acceptance

- Workload 无法绕过 Supervisor 直接访问网络。
  Workloads cannot bypass the Supervisor to reach the network directly.
- OpenShell 策略能够拒绝未授权域名。
  OpenShell policies can deny unauthorized domains.
- Antrea 能够隔离不同 Tenant。
  Antrea can isolate different Tenants.
- Gatekeeper 能阻止不安全 Pod。
  Gatekeeper blocks unsafe Pods.
- Provider 凭证不会出现在 Agent 环境和普通日志中。
  Provider credentials never appear in the Agent environment or ordinary logs.
- 外部 PVC 必须经过 OpenShell Resource Admission。
  External PVCs must pass OpenShell Resource Admission.
- Tetragon 能观察到 Agent 进程执行和外部连接。
  Tetragon can observe Agent process execution and outbound connections.

## 13.3 可观测性验收 / Observability Acceptance

- Pi Agent Trace 可以被采集。
  Pi Agent traces can be collected.
- OpenShell Gateway Trace 可以被采集。
  OpenShell Gateway traces can be collected.
- Supervisor Trace 可以被采集。
  Supervisor traces can be collected.
- OpenShell OCSF 安全事件可以被采集。
  OpenShell OCSF security events can be collected.
- Tetragon JSON / gRPC 事件能够进入统一安全日志平台。
  Tetragon JSON / gRPC events reach the unified security log platform.
- 事件可以根据 Sandbox ID 和 Pod UID 关联。
  Events can be correlated by Sandbox ID and Pod UID.
- 不同租户的数据可以被隔离查询。
  Data from different tenants can be queried in isolation.

---

<a id="s14"></a>
# 14. 最终设计报告 / Final Design Report

PoC 执行完成后，输出以下设计报告。

After the PoC completes, produce the following design report.

## 14.1 报告结构 / Report Structure

1. 项目背景和验证目标。
   Project background and validation goals.
2. 测试环境和软件版本清单。
   Test environment and software version inventory.
3. 整体架构图。
   Overall architecture diagram.
4. 每租户独立 Gateway 部署验证。
   Validation of per-tenant independent Gateway deployment.
5. Capsule 租户隔离验证。
   Capsule tenant isolation validation.
6. Antrea 网络策略验证。
   Antrea network policy validation.
7. Gatekeeper 准入控制验证。
   Gatekeeper admission control validation.
8. OpenShell Sandbox 生命周期验证。
   OpenShell Sandbox lifecycle validation.
9. 多 Pi 共享 Workspace 验证。
   Validation of multiple Pi Sandboxes sharing a Workspace.
10. Pi GitHub Clone 和代码修改结果。
    Pi GitHub clone and code modification results.
11. 多 Pi 并行 Review 结果。
    Results of parallel review by multiple Pi Sandboxes.
12. Tetragon eBPF 行为观测结果。
    Tetragon eBPF behavior observation results.
13. OpenTelemetry Trace 数据分析。
    OpenTelemetry trace data analysis.
14. OpenShell OCSF 安全事件分析。
    OpenShell OCSF security event analysis.
15. 组件间事件关联效果。
    Effectiveness of cross-component event correlation.
16. 已发现的问题和限制。
    Issues and limitations found.
17. 生产环境架构建议。
    Production architecture recommendations.
18. 后续实施计划。
    Follow-up implementation plan.

## 14.2 必须保留的证据 / Evidence That Must Be Retained

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

## 14.3 最终报告需要回答的问题 / Questions the Final Report Must Answer

1. 每个租户是否真的可以独立管理 Gateway？
   Can each tenant genuinely manage its Gateway independently?
2. Gateway 是否能够只管理自己租户的 Sandbox？
   Can a Gateway manage only its own tenant's Sandboxes?
3. 一个 Workspace 是否可以被多个 Pi Sandbox 安全共享？
   Can one Workspace be safely shared by multiple Pi Sandboxes?
4. 多 Agent 的读写权限是否可以独立控制？
   Can read/write permissions be controlled independently per Agent?
5. OpenShell 是否能防止 Agent 直接出网？
   Can OpenShell prevent an Agent from egressing directly?
6. Antrea 是否能够提供额外的网络隔离？
   Can Antrea provide additional network isolation?
7. Tetragon 能否观察 Agent 的真实进程行为？
   Can Tetragon observe the Agent's real process behavior?
8. Pi、Gateway、Supervisor 的 Trace 是否完整？
   Are the Pi, Gateway and Supervisor traces complete?
9. Tetragon 和 OpenShell 事件是否能够与 Agent Trace 关联？
   Can Tetragon and OpenShell events be correlated with Agent traces?
10. 当前架构距离生产部署还有哪些差距？
    What gaps remain between the current architecture and production deployment?

最终输出：

Final deliverable:

**《Kubernetes Multi-Tenant AI Agent Runtime 安全与可观测性架构设计报告》**
**"Kubernetes Multi-Tenant AI Agent Runtime Security and Observability Architecture Design Report"**

报告必须区分：

The report must distinguish:

- 已通过验证的能力。
  Capabilities that have been verified.
- 部分通过的能力。
  Capabilities that are partially verified.
- 尚未验证的能力。
  Capabilities that have not been verified.
- 已发现的限制。
  Limitations that have been found.
- 生产部署前必须解决的问题。
  Problems that must be resolved before production deployment.

不得把设计预期写成实际测试结果。

Design expectations must not be written as actual test results.

---

<a id="s15"></a>
# 15. 实施顺序 / Implementation Order

建议按以下顺序推进：

The following order is recommended:

| 阶段 / Phase | 工作 / Work | 交付 / Deliverable |
|---|---|---|
| Phase 1 | Kind + Antrea + Capsule + Gatekeeper | 基础集群<br>Base cluster |
| Phase 2 | Agent Sandbox + OpenShell Gateway | Pi Sandbox 可启动<br>Pi Sandboxes can start |
| Phase 3 | RWX PVC + 多 Sandbox 共享<br>RWX PVC + multi-Sandbox sharing | Workspace 验证<br>Workspace validation |
| Phase 4 | Pi + GitHub + 代码修改 + Review<br>Pi + GitHub + code changes + review | 业务流程验证<br>Business flow validation |
| Phase 5 | Tetragon + OTel | 安全观测验证<br>Security observability validation |
| Phase 6 | 安全攻击测试和数据关联<br>Security attack tests and data correlation | 测试证据<br>Test evidence |
| Phase 7 | 整理结果和问题<br>Consolidate results and issues | 正式设计报告<br>Final design report |

建议不要同时调试所有组件。先把一个 Pi Sandbox 成功运行起来，再验证共享存储，最后接入观测系统。

Do not debug all components at once. Get one Pi Sandbox running first, then validate shared storage, and only then connect the observability stack.

> **实际执行脚本 / Executed scripts:** 仓库把上表拆成了 `poc/phases/` 下的可重复脚本：
> `01-cluster` `02-antrea` `03-netpol-verify` `04-capsule` `05-gatekeeper` `06-agent-sandbox`
> `07-rwx-storage` `08-gateway` `09-resource-admission` `10-observability` `12-tetragon`。
> 注意 **10(观测栈)要在 08(Gateway)之前**执行，否则 Gateway 启动期所有 OTLP 导出都会失败。
> The repository splits the table above into repeatable scripts under `poc/phases/`:
> `01-cluster` `02-antrea` `03-netpol-verify` `04-capsule` `05-gatekeeper` `06-agent-sandbox`
> `07-rwx-storage` `08-gateway` `09-resource-admission` `10-observability` `12-tetragon`.
> Note that **10 (observability) must run before 08 (Gateway)**, otherwise every OTLP export fails during Gateway startup.
> Phase 4 对应脚本 `11-pi-scenario.sh` 与 Phase 6 对应脚本 `13-security-matrix.sh` **尚未编写**(见结论文档 §6)。
> The scripts for Phase 4 (`11-pi-scenario.sh`) and Phase 6 (`13-security-matrix.sh`) are **not yet written** (see conclusions doc §6).

---

<a id="s16"></a>
# 16. 生产架构方向 / Production Architecture Direction

如果 PoC 全部通过，生产环境建议保持：

If the PoC passes in full, the production architecture should keep:

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

The platform manages only the deployment, quota and security boundary of tenant Gateways.

租户通过自己的 Gateway 管理 Workspace、Sandbox 和 Agent。

Tenants manage Workspaces, Sandboxes and Agents through their own Gateway.

Tetragon 负责观察实际运行行为，OpenShell 负责 Agent 执行权限，Antrea 负责网络隔离，OpenTelemetry 负责统一遥测。

Tetragon observes actual runtime behavior, OpenShell governs Agent execution permissions, Antrea enforces network isolation, and OpenTelemetry provides unified telemetry.

**最终目标：形成一套能够部署、隔离、执行、观测、审计和复现的 Kubernetes 多租户 Agent Runtime 基础平台。**

**Final goal: a Kubernetes multi-tenant Agent Runtime foundation that can be deployed, isolated, executed, observed, audited and reproduced.**
