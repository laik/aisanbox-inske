# aisanbox-inske · 多租户 AI Agent Sandbox POC / Multi-Tenant AI Agent Sandbox POC

> **给每个租户一个管得住、也看得见的 AI agent 沙箱。**
> 开通租户 → 租户自己的 OpenShell Gateway → 带策略与凭据边界的 Pi 沙箱 → 模型调用经 Supervisor 代理 → 内核层记录进程与连接。
>
> **Give every tenant an AI agent sandbox that is both controllable and observable.**
> Provision a tenant → the tenant's own OpenShell Gateway → a Pi sandbox with policy and credential boundaries →
> model calls proxied through the Supervisor → process and network records at the kernel layer.

本文档是仓库的**唯一入口**：概述、文档地图、复现方式和当前缺口都在这里。详细设计与逐项证据分别见
[`POC2.md`](POC2.md) 与 [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md)。

This README is the **single entry point**: overview, document map, reproduction steps and open gaps.
For the full design see [`POC2.md`](POC2.md); for item-by-item evidence see [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md).

> **文档约定 / Document conventions:** 每段中文后紧跟英文；表格单元格内中文在上、英文在下。
> Each Chinese passage is followed by English; inside table cells Chinese is on top and English below.

---

## 1. 当前状态 / Current status

2026-11-08 在 `root@192.168.5.190` 的 kind 集群(3 节点 / K8s v1.37 / Ubuntu 24.04 宿主)上，按 **POC2 shared 模式**
(一个 Gateway 只服务一个租户)完成了主干验证。

On 2026-11-08, on the kind cluster at `root@192.168.5.190` (3 nodes / K8s v1.37 / Ubuntu 24.04 host), the main chain was
validated in the **POC2 shared mode** (one Gateway serves exactly one tenant).

| 结论 / Verdict | 内容 / What |
|---|---|
| ✅ 跑通 / Works | 租户开通 → 每租户独立 Gateway(mTLS / 独立 `gateway_id` / 独立 SQLite PVC)→ 配额真正管住沙箱 → 凭据经 Provider 代理注入 → 模型调用被 Supervisor 以 L7 策略记录(OCSF)<br>Tenant provisioning → per-tenant Gateway (mTLS / own `gateway_id` / own SQLite PVC) → quota really governs sandboxes → credentials injected through the Provider proxy → model calls recorded by the Supervisor at L7 (OCSF) |
| ✅ 跑通 / Works | Antrea 唯一 CNI：deny-all / 白名单 / 跨节点路径 9/9；Gatekeeper 精确到身份地拒绝 privileged、hostNetwork、hostPID、hostPath、借用平台 SA；Tetragon 能看到 exec / exit / connect(五元组)/ parent / Pod 身份<br>Antrea as sole CNI: deny-all / allow-list / cross-node paths 9/9; Gatekeeper rejects privileged, hostNetwork, hostPID, hostPath and borrowed platform SAs with identity-level precision; Tetragon shows exec / exit / connect (5-tuple) / parent / Pod identity |
| ⚠️ 部分 / Partial | Pi 的 `gen_ai.*` span 进了 Collector，但尚未证明稳定落到可查询后端；OCSF 只有 JSONL/日志形式，OTLP 导出未验证；Tetragon 强制能力受宿主内核 LSM(无 `bpf`)限制<br>Pi's `gen_ai.*` spans reach the Collector, but reliable landing in a queryable backend is unproven; OCSF exists only as JSONL/logs, OTLP export unverified; Tetragon enforcement is limited by the host kernel LSM (no `bpf`) |
| ❌ 未验证 / Not verified | **多个 Sandbox 共享同一份 Workspace 并各读写权限**(POC-04 / SEC-06 / SEC-07)、多 Agent 并行 Review(POC-10)、跨源事件关联(POC-11)<br>**Multiple Sandboxes sharing one Workspace with per-Sandbox read/write permissions** (POC-04 / SEC-06 / SEC-07), multi-Agent parallel review (POC-10), cross-source correlation (POC-11) |

**不要**把上表的"设计预期"当成"实测结果"。完整状态表(POC-01..11、SEC-01..14)与每条证据原文见
[`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md) §2。

**Do not** read the design expectations above as measured results. The full status tables (POC-01..11, SEC-01..14) and the
verbatim evidence for each item are in [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md) §2.

---

## 2. 为什么是这套组合 / Why this stack

每个组件只负责一段，接口是 Kubernetes 原生对象，中间不写胶水代码。

Each component owns one segment; the interfaces are native Kubernetes objects, with no glue code in between.

| 层 / Layer | 组件 / Component | 只管这一件事 / Owns exactly this |
|---|---|---|
| 租户合同 / Tenant contract | Capsule | 命名空间归谁、配额上限、跨租户命名拦截<br>Namespace ownership, quota ceilings, cross-tenant naming rejection |
| 工作负载编排 / Workload orchestration | agent-sandbox (SIG Apps) | `Sandbox` CR：稳定身份、生命周期、持久存储<br>`Sandbox` CR: stable identity, lifecycle, persistent storage |
| 执行边界 / Execution boundary | OpenShell | 文件系统、网络出口、凭据代理，以及每租户独立 Gateway<br>Filesystem, network egress, credential brokerage, and a per-tenant Gateway |
| 网络隔离 / Network isolation | Antrea | NetworkPolicy 的真实执行与微分段<br>Real NetworkPolicy enforcement and micro-segmentation |
| 准入控制 / Admission control | OPA Gatekeeper | 不安全的 Pod 与资源创建在入库前被拒<br>Unsafe Pods and resources rejected before persistence |
| 内核观测 / Kernel observability | Tetragon | 不依赖 agent 自报的进程与连接真相<br>Ground truth for processes and connections, independent of agent self-report |
| 统一遥测 / Unified telemetry | OpenTelemetry | Pi / Gateway / Supervisor / Tetragon 进入同一观测面<br>Pi / Gateway / Supervisor / Tetragon on one observability plane |

---

## 3. 文档地图 / Document map

| 想知道什么 / Question | 看哪里 / Where |
|---|---|
| **设计与实施计划**(双语，16 章：架构、安装、策略、业务流程、验收标准)<br>**Design and implementation plan** (bilingual, 16 chapters) | [`POC2.md`](POC2.md) |
| **实测结论、证据、未完成项**(双语；POC-01..11 / SEC-01..14)<br>**Measured conclusions, evidence, open items** (bilingual) | [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md) |
| 第一轮(operator 模式)逐项证据与踩坑附录<br>Round 1 (operator mode) evidence and pitfall appendix | [`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md) |
| kind 集群如何从外部访问(证书 SAN + NodePort 映射)<br>How to reach the kind cluster from outside (cert SAN + NodePort mapping) | [`poc/kind/README-external-access.md`](poc/kind/README-external-access.md) |
| 在 Tetragon 里查"agent 访问了谁 / 做了哪些危险操作"<br>Querying Tetragon for "what did the agent reach / do" | [`poc/usage/02-agent-visibility.md`](poc/usage/02-agent-visibility.md) |
| 可重复执行的安装脚本(按编号顺序)<br>Repeatable installation scripts (run in numeric order) | [`poc/phases/`](poc/phases/) |

> 第一轮的 `SUMMARY.md` / `RECAP.md` / `DEMO.md` / `index.html` / `architecture.html` 已移除：它们描述的是
> **operator 模式在 Mac + 两个 kind 集群**上的旧路径，与 POC2 shared 模式结论不通用。历史内容在 git 历史中可查。
> 对应的可执行资产(`poc/agent`、`poc/usage`、`poc/openshell` 等)保留。
>
> Round 1's `SUMMARY.md` / `RECAP.md` / `DEMO.md` / `index.html` / `architecture.html` were removed: they describe the
> **operator mode on a Mac with two kind clusters**, whose conclusions do not carry over to POC2 shared mode. The history
> remains in git. The corresponding executable assets (`poc/agent`, `poc/usage`, `poc/openshell`, etc.) are retained.

---

## 4. 复现 / Reproduce

```bash
# 依赖 / Requirements: Docker + kind + kubectl + helm；宿主内核需 BTF
# 1) 建集群(kind 配置含外部访问所需的 apiServerAddress / certSANs / extraPortMappings)
bash poc/phases/01-cluster.sh

# 2) 01 之后补 apiserver SAN(字段名必须是 certSANs，写 extraSANs 会被静默忽略)
SAN=<宿主IP> bash poc/kind/fix-apiserver-sans.sh

# 3) 按顺序执行；注意 10(观测栈)必须在 08(Gateway)之前
bash poc/phases/02-antrea.sh
bash poc/phases/03-netpol-verify.sh
bash poc/phases/04-capsule.sh
bash poc/phases/05-gatekeeper.sh
bash poc/phases/06-agent-sandbox.sh
bash poc/phases/07-rwx-storage.sh
bash poc/phases/10-observability.sh
bash poc/phases/08-gateway.sh
bash poc/phases/09-resource-admission.sh
bash poc/phases/12-tetragon.sh
```

外部可访问的两个必要条件(证书 SAN 含宿主 IP、NodePort 用 `extraPortMappings` 显式发布)见
[`poc/kind/README-external-access.md`](poc/kind/README-external-access.md)。

The two necessary conditions for external access (the certificate SAN includes the host IP, and NodePorts are published
explicitly with `extraPortMappings`) are in [`poc/kind/README-external-access.md`](poc/kind/README-external-access.md).

本轮未编写的脚本：`poc/phases/11-pi-scenario.sh`(业务流程：clone → 修改 → test → 双 Reviewer)与
`poc/phases/13-security-matrix.sh`(SEC-04/06/07/08/12)。因此 POC-04/10/11 的结论是 ❌，不是 ⚠️。

Scripts not yet written this round: `poc/phases/11-pi-scenario.sh` (business flow: clone → modify → test → two reviewers) and
`poc/phases/13-security-matrix.sh` (SEC-04/06/07/08/12). The verdicts for POC-04/10/11 are therefore ❌, not ⚠️.

### 演示入口 / Demo entry points

- 宿主 Grafana(Tempo 数据源)：`http://<宿主IP>:3000`
- 集群内 Jaeger UI(NodePort)：`http://<宿主IP>:31686`(需 `extraPortMappings` 映射)
- OTLP 接入点：Collector `observability/otel-collector:4317`(gRPC)/ `:4318`(HTTP)

- Host Grafana (Tempo data source): `http://<host-ip>:3000`
- In-cluster Jaeger UI (NodePort): `http://<host-ip>:31686` (requires the `extraPortMappings` entry)
- OTLP endpoints: collector `observability/otel-collector:4317` (gRPC) / `:4318` (HTTP)

---

## 5. 组件版本 / Component versions

| 组件 / Component | 版本 / Version |
|---|---|
| kind | v0.33.0 |
| Kubernetes | v1.37.0 |
| Antrea | 2.7.0 |
| Capsule | 0.15.2 |
| OPA Gatekeeper | 3.23.1 |
| agent-sandbox | v1.0.10 |
| OpenShell | 0.1.7 |
| Tetragon | 1.8.0 |
| NFS Server Provisioner | 1.8.0 |
| OpenTelemetry Collector (contrib) | 0.155.0 |
| Jaeger all-in-one | 1.69.0 |
| Pi Coding Agent | 1.5.0 |
| pi-otel | 0.3.0 |

---

## 6. 仓库结构 / Repository layout

```
poc/
├── docs/          POC2-CONCLUSIONS.md · FINDINGS.md(第一轮证据附录)
├── phases/        01→12 可重复安装脚本(10 在 08 之前)
├── kind/          poc2-cluster.yaml · fix-apiserver-sans.sh · README-external-access.md
├── capsule2/      租户与配额(按实测重算)
├── gatekeeper/    约束模板
├── openshell2/    Gateway values(shared 模式)
├── providers/     Provider profile(模型出口、GitHub 纯出权)
├── policies/      Developer / Reviewer 文件系统策略
├── pi/            Pi 镜像与运行期 agent home 初始化
├── observability2/ Collector 配置(双出口:Jaeger + Tempo)
├── observability/ OTLP 自检 Pod
├── storage/       RWX PVC 与探针
├── tetragon/      观测与强制策略
├── scripts/       gh-fetch.sh(绕开 release asset 超时)
└── usage/         开通脚本 · Tetragon 查询手册 · 第一轮演示脚本
```

第一轮的资产(`agent/`、`capsule/`、`openshell/`、`agent-sandbox/`、`usage/01,03`)仍在仓库中，供对照与复用。

Round-1 assets (`agent/`, `capsule/`, `openshell/`, `agent-sandbox/`, `usage/01,03`) remain in the repository for reference
and reuse.

---

## 7. 仍未解决 / Open items

1. **共享 Workspace 的读写分权未验证**(POC-04 / SEC-06 / SEC-07)。这是模式的核心主张，需要真实 `touch` 失败。
   **Read/write separation on the shared Workspace is unverified.** This is the pattern's central claim; it needs a real
   failing `touch`.
2. **跨源关联未证明**(POC-11)：先确认 relay 是否补 `openshell.sandbox.id`，否则按 Pod UID + 时间关联。
   **Cross-source correlation is unproven**: first check whether the relay adds `openshell.sandbox.id`, otherwise correlate
   by Pod UID + time.
3. **多 Agent 协作未做**(POC-10)。
   **Multi-Agent collaboration was not done.**
4. **OCSF 的 OTLP 导出未验证**；当前只有 JSONL / 日志行。
   **OCSF OTLP export is unverified**; only JSONL / log lines exist today.
5. **观测后端持久化**：Jaeger all-in-one 为内存存储，生产需换带存储与保留期的后端。
   **Observability persistence**: Jaeger all-in-one is in-memory; production needs storage and retention.
6. **Gateway 单副本 + SQLite**：生产需外部 PostgreSQL，且证书轮转要持续同步到 runtime ns 的 client-TLS 副本。
   **Gateway single replica + SQLite**: production needs external PostgreSQL, and certificate rotation must be synced
   continuously to the client-TLS copy in the runtime ns.
7. **Tetragon 强制能力取决于宿主内核**(LSM 需含 `bpf`)，属于交付前提。
   **Tetragon enforcement depends on the host kernel** (LSM must include `bpf`); this is a delivery precondition.

---

## 8. 历史 / History

- **第一轮(2026-11-03)**：operator 模式，Mac + Docker Desktop + 两个 kind 集群。验证了预热池、uid 10001、内核层快速拒绝、
  OTLP 与内核事件对齐等。证据保留在 [`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md)。
- **第二轮(2026-11-08)**：POC2 shared 模式，单租户单 Gateway，结论见
  [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md)。**本轮是当前有效的结论。**

- **Round 1 (2026-11-03)**: operator mode, Mac + Docker Desktop + two kind clusters. Validated warm pools, uid 10001,
  fast kernel-level denial, OTLP/kernel event alignment. Evidence is kept in [`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md).
- **Round 2 (2026-11-08)**: POC2 shared mode, one Gateway per tenant. Conclusions are in
  [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md). **This round's conclusions are the current ones.**
