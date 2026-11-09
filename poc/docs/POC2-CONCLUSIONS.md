# POC2 模式结论 · 每租户独立 Gateway + 共享 Workspace

> **一句话:** POC2 这套模式在 2026-11-08 的 kind(3 节点 / K8s v1.37 / Ubuntu 24.04 宿主)上
> **跑通了主干**：租户开通 → 租户自己的 Gateway → 带策略与凭据边界的 Pi 沙箱 → 模型调用经
> Supervisor 代理 → 内核层记录进程与连接。**没有跑通的是它最核心的卖点本身**——多个
> Sandbox 共享同一份 Workspace 并各读写权限(POC-04 / §10.5)，以及多 Agent 并行 Review
> (POC-10)与跨源事件关联(POC-11)。
>
> 与 `poc/docs/SUMMARY.md`(第一轮)的区别：那一轮验证的是 **operator 模式**(平台预建
> namespace、按标签让 OpenShell 认领)。**这一轮验证的是 POC2 §2.3 的 shared 模式**——
> 一个 Gateway 只服务一个租户、该租户所有 Sandbox 落在它专属的 runtime namespace。
> 两条路的结论**不通用**，下面会逐条说明差异在哪里。

---

## 1. 这个模式实际是什么(以及和第一轮的差别)

| | 第一轮(operator) | **本轮 POC2(shared)** |
|---|---|---|
| namespace 归谁 | 平台建、打 `openshell.ai/workspace=true`，Gateway 按标签认领 | 平台建一个专属 runtime ns，Gateway 配置里写死 `namespace =` |
| Sandbox 名字 | 裸名(namespace 提供隔离) | `{workspace}--{name}`(namespace 不提供隔离) ← 源码 `driver-kubernetes/config.rs` |
| client-TLS 怎么到 Supervisor | 驱动自己塞进每次生成的 bootstrap Secret | **必须由平台把 Secret 复制进租户 runtime ns**(见 §4.1) |
| 一个 Gateway 覆盖 | 多个 ns | 一个 ns |
| 与 Capsule 的接法 | 标签契约 | **namespace 归属契约**(更直接) |

**模式判断：shared 模式与 Capsule 的组合更简单、可解释性更好**——一个租户 = 一个
Capsule Tenant = 一个 Gateway = 两个 namespace(gateway / runtime)。第一轮的 operator
模式多出一层"标签发现"，排查时多一处看不见的手。代价是 shared 模式**要求平台自己做两件
事**：把 client-TLS bundle 落到 runtime ns，以及把外部 PVC 的授权标签管住(§4)。

---

## 2. 验证结果(按 POC2 的编号)

> 规则(POC2 §14.3 明确要求)：**不把设计预期写成测试结果**。下面"证据"一栏只写实际看到的输出。

| 编号 | 结论 | 证据 / 缺口 |
|---|---|---|
| POC-01 每租户独立 Gateway | ✅ 通过 | 两个 Gateway 各自 mTLS 认证、各自 `gateway_id`、各自 SQLite PVC；两边都建出同名 workspace `poc-shared` 且互不可见；`auth can-i` 显示 A 的 SA 在 B 的 runtime ns 里是 `no` |
| POC-02 Capsule 租户隔离 | ✅ 通过(比预期更强) | 归属只在创建时由 webhook 注入(不能事后追认)；`ForceTenantPrefix` 拦住跨租户命名；**配额真的管住了 OpenShell 创建的沙箱**：`exceeded quota: capsule-tenant-a-0, requested: limits.memory=1Gi, used: 2Gi, limited: 2560Mi` |
| POC-03 Gateway 管理多个 Sandbox | ⚠️ 部分 | 同一 Gateway 下同时有 2 个沙箱在 Running。**第 3 个被配额挡住**后才把配额调大；调大之后没有再跑到 3 个 |
| POC-04 多 Sandbox 共享 Workspace | ❌ **未验证** | RWX 本身是真的(NFS，两个跨节点 Pod 读写同一份、并发追加 50/50 行；local-path 上同样的声明停在 Pending)。但**没有用两个 OpenShell 沙箱去读写同一个 PVC**——这正是 §10.5 要的场景，也是这个模式的核心卖点 |
| POC-05 Antrea 网络隔离 | ✅ 通过 | 9/9：无策略通、deny-all 拦、白名单只放行被选中的 Pod；并进了 Antrea 控制面与 OVS 流表(123→135→123)，跨节点路径 |
| POC-06 Gatekeeper 准入 | ✅ 通过(且作用域精确) | privileged / hostNetwork / hostPID / hostPath / 借用平台 SA 全部被 `[poc-tenant-pod-boundary]` 拒；**同一个 ns 内**平台 SA 身份通过、租户身份被拒 —— 没有任何 ns 级豁免 |
| POC-07 Tetragon 行为观测 | ✅ 观测通过 / ⚠️ 强制受限 | exec、exit、connect(五元组)、parent、pod/namespace/容器/镜像身份都在事件里。但**这台宿主的内核 LSM 列表没有 `bpf`**(`lockdown,capability,landlock,yama,apparmor`)，基于 lsm hook 的策略加载失败 |
| POC-08 Pi 的 OTel Trace | ⚠️ 部分 | Pi 的 `gen_ai.*` span **确实进了 Collector**(collector `verbosity=detailed` 的日志里有 `gen_ai.operation.name=chat`、`gen_ai.usage.input_tokens=1594`、`gen_ai.tool.name=bash`)。但**没能证明它们稳定落到可查询的后端**：Jaeger all-in-one 是内存存储、重启即清空；Tempo 里只查到 Gateway 的 trace。且证据窗口很短——见下方"关于沙箱生命周期" |
| POC-09 OpenShell 遥测 | ⚠️ 部分 | Gateway / driver / supervisor 的 trace 进了两个后端(Tempo 里 `reconcile.sandboxes`、`driver_watch.sandbox_updated`)；OCSF 在 **Supervisor 日志里**是完整的(`OCSF HTTP:POST ALLOWED POST http://…/v1/chat/completions [policy:_provider_poc_model engine:l7]`)。但 POC2 §8.3 的 `[openshell.gateway.otlp.ocsf]` **没有验证**——chart 暴露的是 `ocsf_log` 写 JSONL 文件，不是 OTLP 导出 |
| POC-10 多 Agent 协作 | ❌ 未做 | — |
| POC-11 安全事件关联 | ❌ 未证明 | 三条流各自都有数据，但**没有证明它们能按同一个键关联**。Pi 的 span 上没有看到 `openshell.sandbox.id` 或 `k8s.*` 属性(relay 转发时是否补属性，未验证) |

**关于沙箱生命周期(实测，值得写进模式结论):** 沙箱的存活期 = 我们传给它的命令的存活期。
`-- sleep 1800` 到期之后沙箱 phase 变 `Completed`，之后任何 `sandbox exec` 都是
`Error: sandbox 'x' is not ready (phase: Completed)`。不是超时、不是被回收。
对"跑一段任务再查观测"的用法，这意味着要么给足够长的 keepalive，要么用
`--restart-policy` 与真正的长驻进程。这个行为对**证据留存**影响很大: 观测后端里的数据
还在，但产生它的那个工作负载已经不能回去查了。

### 安全用例(POC2 §11)

| 用例 | 结果 | 实测 |
|---|---|---|
| SEC-01 Pi 直接 curl 未授权域名 | ✅ | `api.openai.com` / `example.com` **4–6 ms** 内失败(`Couldn't connect`，不是超时) |
| SEC-02 经 Supervisor 访问批准的端点 | ✅ | `192.168.5.190:8080/v1/chat/completions` 被 supervisor 记为 `OCSF HTTP:POST ALLOWED … engine:l7` |
| SEC-03 未批准域名 | ✅ | 同 SEC-01；策略名在事件里可见(`_provider_poc_model`) |
| SEC-05 Agent 访问 Kubernetes API | ✅ | `kubernetes.default.svc:443` 被拒 |
| SEC-09 不安全 Pod | ✅ | 见 POC-06 |
| SEC-10 租户直接创建 Sandbox CR | ✅ | 两层分开测：RBAC 先拒；**故意把权限给租户之后**，`[poc-managed-cr-only-platform]` 仍然拒 |
| SEC-11 Agent 读不到 Provider Token | ✅ | 沙箱里 `OPENAI_API_KEY=openshell:resolve:env:v7305…_OPENAI_API_KEY`，是**代理占位符**；真实 key 只在边界上注入(请求能成功即证明) |
| SEC-14 使用未批准的 PVC | ✅ | 无标签 / 标签值不匹配 → `external resource not admitted by required labels`；标签匹配 → 允许 |
| SEC-06 / SEC-07 Reviewer 只读 / Developer 可写 | ❌ **未测** | 依赖 POC-04；`policies/pi-reviewer.yaml` 已写好但没跑 |
| SEC-04 / SEC-08 跨租户网络 | ⚠️ 未单独测 | Antrea 机制已在 POC-05 证明，但**没有做 Tenant A → Tenant B 的实际连接测试** |
| SEC-12 Supervisor 断链 fail-closed | ❌ 未测 | — |

---

## 3. 关于这个模式的 6 条结构性结论

这一节才是"模式"层面的东西——不是某个组件的 bug，而是**这套组合的固有性质**。

### 3.1 平台默认值的覆盖范围，决定了你要写多少策略

OpenShell 不给文件系统策略时，基线是
`/bin /usr /lib /proc /dev/urandom /etc /var/log` 只读、`/tmp /dev/null` 读写。
**不含 `/opt`，也不含 `/data`。** 后果是同一类报错在两个地方出现：

- Pi 的 agent 目录放在 `/opt` → 沙箱里 `Permission denied`，而 `ls -ld` 显示 mode 是
  `0755 root`(uid 10001 本该能读)——**报错指向 Unix 权限，实际是策略边界**；
- 共享 PVC 挂在 `/data/workspace` → 同样 `Permission denied`，而**同一个 PVC 挂进普通
  Pod** 时 uid 10001 读写都正常(`UID_WRITE_OK`)。

**结论：这个模式里"策略基线覆盖了哪些路径"是平台契约的一部分。** 任何放在基线之外的路径
(agent 目录、工作区、缓存)都必须显式进策略，且要在开通流程里生成，不能靠调镜像。
POC2 §5.3 已经写了"每个 Sandbox 使用自己的 OpenShell 策略"，但没写**为什么必须**——
上面就是为什么。

### 3.2 沙箱以 uid 10001 运行，镜像里的 `USER` 会被覆盖

POC2 §6.1 的 Dockerfile 用 `USER node`。实际沙箱里是 `uid=10001`。因此：

- 镜像里 `chown node` 的目录在沙箱里不可写；
- 镜像的 `ENV PI_CODING_AGENT_DIR` **不会**传进沙箱(要靠运行期给)。

所以 Pi 镜像的正确做法是：构建期把 agent 目录(含扩展)准备好并设成**所有 uid 可读**，
运行期复制成可写副本(`/usr/local/pi/setup-agent-home.sh`)。同一个坑在 `USER node`
之后的 `/opt` 上也出现过一次(构建期 `unable to find user node`)。

### 3.3 凭据与网络是同一个控制点，不是两层

Provider profile 同时声明 **endpoint + 哪个二进制能去 + 凭据放哪儿**。实测：

- OpenShell **不把任何 provider profile 编进发行版**(源码注释原话)。
  `provider create --type openai` 必然报 `provider profile 'openai' not found`——
  **平台必须自己声明允许哪个主机**。这不是缺陷，是这个模式的前提。
- 官方 `providers/openai.yaml` 的注释明确要求：**另一个主机上的 OpenAI 兼容服务要另建一个
  profile 命名那个主机**，不要改官方的。本轮就是照这个做的(`providers/poc-model.yaml`)。
- 凭据的存储键是 profile 里声明的 **`env_vars` 名**(`OPENAI_API_KEY`)，不是逻辑名
  (`api_key`)。写 `--credential api_key=…` 会得到
  `provider credentials are not declared by profile 'poc-model': api_key`。
- **不需要凭据的纯出权也能表达**(`credentials: []` + `--provider poc-git`)，这让
  "沙箱能访问 GitHub"成为**显式声明**而不是默认允许。

### 3.4 Agent 侧的 OTLP 是"免费"的，但要理解它接到哪儿

创建沙箱后，OpenShell 自动注入：

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://192.0.0.8:4318   # 这个沙箱自己的 supervisor relay
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
NODE_EXTRA_CA_CERTS=/run/openshell-supervisor-ca/material/ca.crt
```

pi-otel 正好读这两个环境变量，所以 **agent 不需要知道 Collector 地址、也不需要任何
Collector 凭据**——POC2 §8.2 想要的效果是现成的(且 relay 默认关闭，`otlp.agent.enabled=true`
一开就有)。实测 relay 说 OTLP/HTTP protobuf(发 JSON 会得到 415 并明确告诉你
`send application/x-protobuf`)。

**但**：这条链在 POC 里只证明了"到 Collector"，没证明"到可查询的后端并带上可关联的身份"。
relay 会不会给 span 补 `openshell.sandbox.id`，未验证。**这正是 POC-11 的入口，也是这套
模式能不能产生审计价值的关键一环。**

### 3.5 失败路径很长，跨产品

三个实测例子，报错都**不在**产生问题的地方：

| 现象 | 报错在哪 | 真实原因在哪 |
|---|---|---|
| 第 3 个沙箱起不来 | CLI: `timed out waiting for gated workload Pod` | agent-sandbox 控制器日志: Capsule **配额**已满 |
| Supervisor 卡在 ContainerCreating | kubelet: `secret "openshell-client-tls" not found` | shared 模式下**平台要自己把 Secret 复制到 runtime ns**(驱动只在多 ns 模式下自己塞) |
| `ls /data/workspace` 被拒 | 沙箱内 `Permission denied` | OpenShell **策略基线**不含 `/data` |

**结论：这套模式对可观测性的要求不是"锦上添花"，而是可用性前提。** §12 的关联设计要优先
覆盖"配额拒绝""策略基线""Secret 缺失"这三类，因为运维第一次撞到它们时看到的都是别的
产品的错误。

### 3.6 配额要按"一个沙箱的真实开销"设计

一个沙箱不止 agent 容器：还有它自己的 supervisor Pod 和一个 workspace PVC。实测一个沙箱
(带 PVC)让租户配额涨到 `limits.memory=1536Mi / count/pods=2`。`scope: Tenant` 让配额是
**跨该租户所有 namespace 聚合**的——gateway Pod 也算。

按这个算，3 个沙箱的场景至少要 `limits.memory ≥ 512Mi + 3×1Gi`。`capsule2/tenants.yaml`
已按实测重算，并把上面那段报错留在注释里。

---

## 4. 对 POC2 文档本身的修订建议

| POC2 位置 | 现状 | 应改成 |
|---|---|---|
| §4.3 | 只说 workspace chart 负责 SA/Role/RoleBinding/NetworkPolicy | **补一步**：shared 模式还要把 `openshell-client-tls` 复制到租户 runtime ns(否则 supervisor 永远起不来) |
| §4.2/§4.3 顺序 | 先 Gateway 后 workspace chart | **必须反过来**(或至少让 RBAC 先到位)，否则 Gateway CrashLoop：`sandboxes.agents.x-k8s.io is forbidden … in the namespace "tenant-a-runtime"` |
| §4.4 | `required_labels` 用 `openshell.ai/sandbox-attachable-workspace: "${workspace}"` | 语法可用(`${workspace}` 是整值替换)，但**必须同时有一个不含 `${workspace}` 的固定标签**，否则启动校验拒绝(`must include a shared approval label`) |
| §6.1 | Dockerfile 里 `ARG` 写在 `FROM` 之前 | **版本根本没锁上**：stage 里 `${PI_VERSION}` 展开为空，装的是 latest。`ARG` 必须在 `FROM` 之后 |
| §6.1 | `USER node` + `ENV PI_CODING_AGENT_DIR` | 沙箱以 uid 10001 运行、镜像 ENV 不注入 → 需要运行期的可写 agent home |
| §6.2 | `pi install npm:pi-otel` 在运行期 | 必须**构建期**装(运行期出不了网)；且手工拷扩展会缺依赖(`Cannot find module '@opentelemetry/api'`)，要用 Pi 自己的 installer |
| §8.3 | `[openshell.gateway.otlp.ocsf] enabled = true` | v0.1.7 的 chart 只暴露 `ocsf_log`(JSONL 落盘)。**OTLP 形式的 OCSF 未验证**，文档要把这条标成待验证 |
| §7.3 | "Tetragon 提供 eBPF 观测" | 要加前提：**宿主内核的 LSM 列表必须含 `bpf`**(`lsm=bpf`)，否则基于 lsm hook 的策略全部加载失败；另外 1.8.0 的 `kprobe_multi` 默认值会拒绝同符号重复/Overrides，需要 `--disable-kprobe-multi` |
| §3.5 | "要求 Runtime 工作负载有资源 requests/limits" | 要写明**这条在带 LimitRange default 的 ns 里永远不会触发**：Capsule 的 mutating webhook 在 Gatekeeper 之前就把值补上了。这是顺序决定的，不是规则写错 |
| §5.2 | 用 Kind 默认 storageClass 不行 | 已验证：要装 NFS + Subdir Provisioner。并且**同样的 RWX 声明放在 local-path 上会被 API 接受但停在 Pending**——§5.2 那句警告是对的，值得加一句"这就是它的表现" |

---

## 5. 这个模式离生产还差什么

按"必须解决 → 应该解决"排序：

1. **共享 Workspace 的读写分权(POC-04/SEC-06/SEC-07)未验证。** 这是模式的核心主张，
   必须补：Developer RW + 两个 Reviewer RO 挂同一个 PVC，并在容器里真的 `touch` 失败。
   `policies/pi-reviewer.yaml` 与只读 mount 的配置都已备好。
2. **跨源关联(POC-11)未证明。** 需要一条 trace 能同时定位租户/Gateway/Sandbox/进程/目标。
   先确认 relay 补不补 `openshell.sandbox.id`；如果不补，就要在 Collector 侧按
   Pod UID + 时间关联(POC2 §7.3 已经给了正确的做法：不要伪造 trace parent)。
3. **多 Agent 协作(POC-10)未做。**
4. **OCSF 走 OTLP 未验证**——现在只有 JSONL 文件和日志里的人类可读行。
5. **观测后端的持久化与证据留存。** Jaeger all-in-one 内存存储在两轮里各丢过一次证据；
   本轮已改成双出口(集群内 Jaeger 供脚本断言、宿主 Tempo/Grafana 供演示)，但生产要换成
   带存储的后端，并且给 trace 设保留期。
6. **Gateway 仍是单副本 + SQLite。** POC2 §1.3 把 HA 排除在 PoC 外是对的，但报告的
   "生产前必须解决"里要有：外部 PostgreSQL、Gateway 的证书轮转如何同步到 runtime ns 的
   client-TLS 副本(§3.1 那条平台步骤必须是**持续**的，不是一次性的)。
7. **Tetragon 的强制能力取决于宿主内核配置**，属于交付前提，要在开通检查里。

---

## 6. 怎么复现本轮

```bash
# 宿主: Ubuntu 24.04 / 内核 6.8.0-147 (有 BTF, LSM 无 bpf) / 48C / 94G
ssh root@192.168.5.190 'cd /root/poc2 && bash phases/NN-*.sh'

# 01-cluster 之后必须补 apiserver SAN(kind 的 kubeadmConfigPatches 里字段名是 certSANs，
# 写 extraSANs 会被**静默忽略**)：
ssh root@192.168.5.190 'cd /root/poc2 && SAN=192.168.5.190 bash kind/fix-apiserver-sans.sh'

# 顺序: 01→12。其中 10(观测栈)必须在 08(Gateway)之前装好，
# 否则 gateway 的 OTLP 第一屏全是失败，会被误读成"OpenShell 没配好"。
```

外部可访问(kind 配置里 `apiServerAddress: 0.0.0.0` + `apiServerPort: 6443`)的完整条件见
`poc/kind/README-external-access.md`：**两个**必要条件——证书 SAN 要有宿主 IP，
NodePort 要用 `extraPortMappings` 显式发布。

### 本轮还没跑的部分

`phases/11-pi-scenario.sh`(§10 业务流程: git clone → 修改 → go test → 两个 Reviewer 并行
只读)与 `phases/13-security-matrix.sh`(SEC-04/06/07/08/12)尚未编写。POC-04/10/11 的
结论因此是 ❌，不是 ⚠️。
