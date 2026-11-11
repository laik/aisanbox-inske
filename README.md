# aisanbox-inske · 多租户 AI Agent Sandbox POC

> **给每个租户一个管得住、也看得见的 AI agent 沙箱。**
> 开通租户 → 租户自己的 OpenShell Gateway → 带策略与凭据边界的 Pi 沙箱 → 模型调用经 Supervisor 代理 →
> 内核层记录进程与连接。

本文是**结论的唯一出处**：POC-01..11、SEC-01..14 的判定，第三轮 POC3 的 K/G/C/N 用例（§12），
结构性结论、对 POC2/POC3 设计文档的修订建议、离生产还差什么、以及**手工复验清单**（第 7、12.7 节，可直接粘贴命令）。英文版见 [`README.en.md`](README.en.md)。
设计原文见 [`POC2.md`](POC2.md)（第二轮）与 [`POC3.md`](POC3.md)（第三轮，统一权限体系，结论在 **§12**）；
逐条**原始输出**（报错原文、日志行）见 [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md)。

> **本文的写法约定：** 状态只有三种 —— `✅ 实测通过`、`⚠️ 部分 / 有条件`、`❌ 未验证`。
> "设计预期"一律不写成"实测结果"（这是 POC2 §14.3 明确要求的）。每个 ✅ 都在第 7 节给出一条可粘贴的复验命令。

---

## 1. 一句话结论

这套组合（Capsule + agent-sandbox + OpenShell + Antrea + Gatekeeper + Tetragon + OTel）在
`root@192.168.5.190` 的 kind 集群（3 节点 / K8s v1.37 / Ubuntu 24.04 宿主）上，按 **POC2 shared 模式**
（一个 Gateway 只服务一个租户）跑通了主干，并在 **2026-11-09 补齐了原本没验证的卖点本身**：

- 三个 Sandbox 挂同一份 Workspace 且权限不同（Developer 可写 / 两个 Reviewer 只读）—— POC-04
- 一个 Agent 改代码，另两个 Agent 并行只读 Review —— POC-10
- 按 `openshell.sandbox.id` 把 Trace / OCSF / 内核事件关联到同一个沙箱 —— POC-11
- 跨租户网络、读写分权的两层强制、Supervisor 断链的 fail-closed 边界 —— SEC-04/06/07/08/12

**仍未验证的只剩一项：Tetragon 的强制能力** —— 受宿主内核 LSM 列表（不含 `bpf`）限制，属于环境前提而非功能缺失。

本轮最值得写进报告的其实是**验证方法上的错误**，不是功能缺失。原本判为"没通过"的四条里：

| 原判 | 真实原因 |
|---|---|
| POC-08 ❌ 查不到 Pi 的 trace | 按**错误的 `service.name`** 查（`pi-agent` vs 默认的 `pi`）—— `pi-otel` 只从 `~/.pi/agent/settings.json` 或 `<cwd>/.pi/settings.json` 读配置，我们写到了 agent 目录根，配置被**静默忽略** |
| POC-09 ⚠️ OCSF 不能走 OTLP | **把 chart 没暴露的键当成产品不支持** —— 二进制里有 `otlp.ocsf` 与 `openshell_ocsf_otlp_*` 指标 |
| POC-04 / SEC-06 ❌ 共享 Workspace 不成立 | **策略文件本身没有强制内容** —— `policies/pi-reviewer.yaml` 的 YAML 与 developer 版一字不差，注释却已写成"只读" |
| SEC-04/08 ✅ 跨租户被拒（归因错） | 归因写错了：阻断来自 **OpenShell 自己生成的 NetworkPolicy**，不是 Capsule/Antrea 的租户隔离；平台层当时**没有任何**租户网络策略 |
| SEC-12「数据面 `http=200`」❌ 数字不复现 | **测法错了两次**：① 用 NetworkPolicy 掐断被当成"Gateway 断链"（那掐的是 supervisor 出网）；② 用 `openshell sandbox exec` 探数据面 —— 而这条 exec 通道**自己走 Gateway**，一断就 `transport error`。换成缩容 StatefulSet + 沙箱内自循环之后，结论才立得住（§5.6） |

五条都是测法或文档问题，改对之后功能本身是通的（SEC-12 是本轮补测时**自己又错了一次**，也记在这里）。第 7 节的清单就是为了让"怎么测"不再靠记忆。

---

## 2. 当前状态总表

| 判定 | 内容 |
|---|---|
| ✅ 跑通 | 租户开通 → 每租户独立 Gateway（各自 mTLS / `gateway_id` / SQLite PVC）→ Capsule 配额真正管住沙箱 → 凭据经 Provider 代理注入（沙箱内只有占位符）→ 模型调用被 Supervisor 以 L7 策略记录（OCSF，且 OCSF 走 OTLP 已证） |
| ✅ 跑通 | **三个 Sandbox 共享同一份 Workspace、权限不同**，含跨节点；一个改代码两个并行只读 Review；两个 Reviewer 想写都写不进一个字节（只读强制，见 §5.5） |
| ✅ 跑通 | Antrea 唯一 CNI：无策略通 / deny-all 拦 / 白名单只放行被选中的 Pod，9/9，并进了 Antrea 控制面与 OVS 流表；Gatekeeper 精确到身份地拒绝 privileged、hostNetwork、hostPID、hostPath、借用平台 SA |
| ✅ 跑通 | Tetragon **观测**：exec / exit / connect（五元组）/ parent / Pod 身份；Trace、OCSF、内核事件按 `openshell.sandbox.id` 关联到同一个沙箱 |
| ⚠️ 部分 | Tetragon **强制**：lsm hook 类策略在这台宿主上加载失败（LSM 无 `bpf`）；kprobe 类与 `security_socket_connect` 的 override 正常 |
| ✅ 跑通（POC3，第三轮） | **一套权限体系同时管住 K8s 与 OpenShell**：LDAP → Keycloak → 同一个 OIDC JWT → apiserver（OIDC + RBAC，按租户 ns）与一台 OIDC Gateway（两个 Workspace）。身份是目录 `entryUUID`，两侧读同一个 `groups` claim（§12） |
| ✅ 跑通（POC3 补齐） | **多租户平台级网络隔离**：Capsule `networkPolicies` 已落到两个租户的 4 个 ns，跨租户普通 Pod `BLOCKED`、同租户正对照 `REACHED`（§5.4 已按实测更正）。⚠️ NetworkPolicy 可加性仍在（租户自建策略能放宽，见 §12.2 N-04） |
| ✅ 跑通（POC4，第四轮） | **Gateway 改 Deployment + 外部 PostgreSQL**：两个独立 Helm release（p4a/p4b）共用一套 PG，控制面状态互通；同 release 2 副本 HA；sandbox 可见性走共享 runtime ns，不是 PG（§13） |
| ❌ 未验证 | 观测后端的持久化与保留期（Jaeger 为内存存储）；目录变更到 token 的**自动**同步（Keycloak 26.4 无可用的 LDAP sync 端点，见 §12.4/§12.6-h）；多 Gateway 共库的**并发写**与 **KEK 解密失败路径**（§13.3） |

**注意：** 第一轮的结论文档（operator 模式，Mac + 两个 kind 集群）已删除，只在 git 历史里保留。它的结论**不迁移**到
shared 模式。第一轮的原始证据仍在 [`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md)。

---

## 3. 逐项判定（按 POC2 编号）

### 3.1 能力项 POC-01..11

| 编号 | 判定 | 证据要点 |
|---|---|---|
| POC-01 每租户独立 Gateway | ✅ | 两个 Gateway 各自 mTLS、各自 `gateway_id`、各自 SQLite PVC；两边都建出同名 workspace `poc-shared` 且互不可见；`auth can-i` 显示 A 的 SA 在 B 的 runtime ns 里是 `no` |
| POC-02 Capsule 租户隔离 | ✅（比预期更强） | 归属只在创建时由 webhook 注入，**不能事后追认**；`ForceTenantPrefix` 拦住跨租户命名；配额真的管住了 OpenShell 创建的沙箱：`exceeded quota: capsule-tenant-a-0, requested: limits.memory=1Gi, used: 2Gi, limited: 2560Mi` |
| POC-03 一个 Gateway 管多个 Sandbox | ✅（3 个并发） | `pi-dev` + `pi-review-1` + `pi-review-2` 同时 Ready。之前挡住第 3 个的是两个配额维度，都不是 OpenShell 的问题：① `count/services` —— 每个沙箱建**两个 Service**（`os-boundary-<pair>` + `os-supervisor-<pair>`）；② `requests.memory` —— 一个 Pi 沙箱的 requests 是 1Gi(agent) + 128mi(它自己的 supervisor) ≈ **1.15Gi**，而 CLI 只说 `timed out waiting for gated workload Pod`。算术见 `poc/capsule2/tenants.yaml` |
| POC-04 多 Sandbox 共享 Workspace | ✅（含跨节点） | `pi-dev` 用 RW 挂 `shared-workspace`，clone 项目、跑 `go test`、让 Pi 写了一个**真的能过的新测试**（`poc_extra_test.go`）；两个 Reviewer 用 RO 挂同一个 PVC，**都看到**这个文件（`git status` 可见、`wc -l` 有内容），写入被拒。跨节点也成立：dev 在 `worker2`，被 `node_selector` 强制到 `worker` 的沙箱读到同一个文件、写入同样被拒。之前判 ❌ 的直接原因是 reviewer 策略的 YAML 与 developer 版一字不差 |
| POC-05 Antrea 网络隔离 | ✅ | 9/9：无策略通、deny-all 拦、白名单只放行被选中的 Pod；策略进了 Antrea 控制面与 OVS 流表（123→135→123），含跨节点路径 |
| POC-06 Gatekeeper 准入 | ✅（作用域精确） | privileged / hostNetwork / hostPID / hostPath / 借用平台 SA 全部被 `[poc-tenant-pod-boundary]` 拒；**同一个 ns 内**平台 SA 身份通过、租户身份被拒 —— 没有任何 ns 级豁免 |
| POC-07 Tetragon 行为观测 | ✅ 观测 / ⚠️ 强制 | exec、exit、connect（五元组）、parent、pod/namespace/容器/镜像身份都在事件里。但宿主内核 LSM 是 `lockdown,capability,landlock,yama,apparmor`（**无 `bpf`**），基于 lsm hook 的策略加载失败 |
| POC-08 Pi 的 OTel Trace | ✅ | `GET /api/traces?service=pi-agent` 返回完整 trace：`invoke_agent pi` / `chat qwen3.8-flash-next` / `pi.turn`，resource 里有 `openshell.sandbox.id`、`openshell.telemetry.source=agent`、`host.name=poc-shared--pi-*`、`process.*`。修好配置路径后 span 命名变成 POC2 §6.3 期望的形状 —— 这本身就是 settings 被读到的证据 |
| POC-09 OpenShell 遥测 | ✅（OCSF 走 OTLP 已证） | Gateway / driver / supervisor 的 trace 进两个后端；OCSF 决策在 Supervisor 日志里完整。`[openshell.gateway.otlp.ocsf] enabled = true` **有效**：gateway 启动日志出现 `ocsf_endpoint=…`，自身指标 `openshell_ocsf_otlp_exported_total 3`（无 error），Collector 收到 scope 为 `openshell.ocsf` 的日志记录，带 `ocsf.class_uid: Int(3002)` 等结构化属性。两个注意点：OCSF 走 Collector 的 **logs** pipeline（不是 traces）；`ocsf_log`(JSONL) 是**并行**的第二条通道，保留它做离线证据 |
| POC-10 多 Agent 协作 | ✅ 平台侧 / ⚠ 模型侧不确定 | dev 改代码（新增一个能过的测试）→ 两个 Reviewer **并行**读同一份工作区；结束后 `git status` 仍只有 dev 那一个未跟踪文件 —— **两个 Reviewer 一个字节都没写**。平台侧（共享可见 + 只读 + 并行不互斥）是**确定**的。⚠ 但"两个 Agent 各自给出 review 结论"**不确定**：本地模型有时**返回空**（2026-11-09 复跑时 `/tmp/rev-1.out` 是 0 字节、`rev-2.out` 有内容，而 `pi` 的退出码仍是 0）。这是模型能力，不是平台缺陷 —— 演示时不要把空输出讲成平台问题，也不要拿它当平台能力 |
| POC-11 安全事件关联 | ✅ | 关联键就是 `openshell.sandbox.id`，**三条流上都齐**：① Trace —— supervisor 的 span 有 `sandbox.id`/`sandbox.name`，Pi 的 span resource 有 `openshell.sandbox.id`（relay 补的，源码 `otlp_relay/enrichment.rs`）；② Kubernetes —— 同一个 UUID 是 workload Pod 与 supervisor Pod 的标签 `openshell.ai/boundary-pair`；③ 内核/OCSF —— 由 Pod 名对上，实测同一次 curl：Tetragon 给出 `binary=/usr/bin/curl`、argv、`uid=10001`、`pod.name=poc-shared--pi-review-2`、`pod.uid`、容器与镜像，**同一秒** Supervisor 给出 `OCSF NET:OPEN [MED] DENIED /usr/bin/curl(0) -> api.openai.com:443 [reason:transparent_tcp_policy_denied]`。join 路径：`trace(sandbox.id)` == `pod label boundary-pair` == `pod name` == Tetragon 的 `pod.name` == 该 supervisor 的 OCSF 行 |

### 3.2 安全用例 SEC-01..14

| 用例 | 结果 | 实测 |
|---|---|---|
| SEC-01 直接 curl 未授权域名 | ✅ | `api.openai.com` / `example.com` 在 **4–6 ms** 内失败（`Couldn't connect`，不是超时） |
| SEC-02 经 Supervisor 访问批准的端点 | ✅ | 模型端点被 supervisor 记为 `OCSF HTTP:POST ALLOWED … engine:l7` |
| SEC-03 未批准域名 | ✅ | 同 SEC-01；策略名在事件里可见（`_provider_poc_model`） |
| SEC-04 / SEC-08 跨租户网络 | ✅ 平台能力（POC3 补齐） | 见 §5.4：2026-11-10 起 Capsule `spec.networkPolicies` 已为非空，两个租户的 4 个 ns 各下发 `capsule-tenant-<t>-0`；跨租户普通 Pod **`BLOCKED`**，同租户正对照 **`REACHED`**（用例 N-01..N-05）。沙箱那一侧仍由 OpenShell 自己生成的两条策略拦住（L4） |
| SEC-05 Agent 访问 Kubernetes API | ✅ | `kubernetes.default.svc:443` 被拒 |
| SEC-06 Reviewer 只读 | ✅（两层分别证） | 见 §5.5：挂载 ro + 策略 ro 时写被拒；**只关策略**（挂载 rw）也被拒，errno 是 `EACCES`；**只关挂载**（策略 rw）errno 是 `EROFS`。两条独立的强制链 |
| SEC-07 Developer 可写 | ✅ | `DEV_WRITE_OK`，且 `mountinfo` 显示 `rw,relatime` |
| SEC-09 不安全 Pod | ✅ | 见 POC-06 |
| SEC-10 租户直接创建 Sandbox CR | ✅ | 两层分开测：RBAC 先拒；**故意把权限给租户之后**，`[poc-managed-cr-only-platform]` 仍然拒 |
| SEC-11 Agent 读不到 Provider Token | ✅ | 沙箱里 `OPENAI_API_KEY=openshell:resolve:env:v7305…_OPENAI_API_KEY`，是**代理占位符**；真实 key 只在边界上注入（请求能成功即证明） |
| SEC-12 Supervisor ↔ Gateway 断链 | ✅ 已实测，结论分控制面/数据面 | 见 §5.6。断链 = `scale statefulset/os-a-openshell 0`。**数据面不 fail-closed**：停机窗口里沙箱仍连续拿到模型回复（`DATA_PLANE_OK` 计数持续增长，两次实测 3→9 / 3→8），supervisor `OCSF HTTP:POST` 同期上涨；**控制面 fail-closed**：`sandbox create` 连 Sandbox CR 都没有（0 个）。supervisor 自己日志有 `OCSF NET:FAIL … os-a-openshell…:8080`（察觉但继续代理）。POC2 §11 只写"Fail Closed"太粗 |
| SEC-13 另一个进程绕过工具调用直接出网 | ✅ 成立，且比设计预期更强 | 被测进程是镜像里的 `node`，**直接开原始 socket**（不经 Pi、不经任何工具调用）。实测：连**自己的 supervisor:5500** = `CONNECTED`（这是正对照，缺它整段不可用），其余全断：`10.96.0.1:443` TIMEOUT、`1.1.1.1:443`（写死 IP、跳过 DNS）TIMEOUT、DNS 解析 `EAI_AGAIN`。拦它的不是 L7 策略，而是 §5.4 那两条 NetworkPolicy（**L4**）—— 所以"绕过 Agent 工具层"这条路根本不存在。复验：`phases/13-security-matrix.sh` 的 SEC-13 一节 |
| SEC-14 使用未批准的 PVC | ✅ | 无标签 / 标签值不匹配 → `external resource not admitted by required labels`；标签匹配 → 允许 |

### 3.3 沙箱生命周期（实测，会影响证据留存）

沙箱的存活期 = 传给它的命令的存活期。`-- sleep 1800` 到期后 phase 变 `Completed`，之后任何 `sandbox exec` 都是
`Error: sandbox 'x' is not ready (phase: Completed)`。不是超时、也不是被回收。**而且 `Completed` 的沙箱仍然占着两个
Service 与 PVC 配额** —— 必须真的 `sandbox delete`。对"跑一段任务再查观测"的用法，要么给足够长的 keepalive，
要么用 `--restart-policy` 与真正的长驻进程。影响：观测后端里的数据还在，但产生它的那个工作负载已经不能回去查了。

---

## 4. 为什么是这套组合

每个组件只负责一段，接口是 Kubernetes 原生对象，中间不写胶水代码。

| 层 | 组件 | 只管这一件事 |
|---|---|---|
| 租户合同 | Capsule | 命名空间归谁、配额上限、跨租户命名拦截 |
| 工作负载编排 | agent-sandbox (SIG Apps) | `Sandbox` CR：稳定身份、生命周期、持久存储 |
| 执行边界 | OpenShell | 文件系统、网络出口、凭据代理，以及每租户独立 Gateway |
| 网络隔离 | Antrea | NetworkPolicy 的真实执行与微分段 |
| 准入控制 | OPA Gatekeeper | 不安全的 Pod 与资源创建在入库前被拒 |
| 内核观测 | Tetragon | 不依赖 agent 自报的进程与连接真相 |
| 统一遥测 | OpenTelemetry | Pi / Gateway / Supervisor / Tetragon 进入同一观测面 |

**模式判断：shared 模式与 Capsule 的组合更简单、可解释性更好** —— 一个租户 = 一个 Capsule Tenant = 一个 Gateway =
两个 namespace（gateway / runtime）。第一轮的 operator 模式多出一层"标签发现"，排查时多一处看不见的手。
代价是 shared 模式**要求平台自己做两件事**：把 client-TLS bundle 落到 runtime ns，以及管住外部 PVC 的授权标签。

| | 第一轮（operator） | 本轮（shared） |
|---|---|---|
| namespace 归谁 | 平台建、打 `openshell.ai/workspace=true`，Gateway 按标签认领 | 平台建专属 runtime ns，Gateway 配置里写死 `namespace =` |
| Sandbox 名字 | 裸名（namespace 提供隔离） | `{workspace}--{name}`（namespace 不提供隔离）← 源码 `driver-kubernetes/config.rs` |
| client-TLS 怎么到 Supervisor | 驱动自己塞进每次生成的 bootstrap Secret | **必须由平台把 Secret 复制进租户 runtime ns** |
| 一个 Gateway 覆盖 | 多个 ns | 一个 ns |
| 与 Capsule 的接法 | 标签契约 | **namespace 归属契约**（更直接） |

---

## 5. 结构性结论（关于这套组合，不是某个组件的 bug）

### 5.1 平台默认值的覆盖范围，决定了你要写多少策略

OpenShell 不给文件系统策略时，基线是 `/bin /usr /lib /proc /dev/urandom /etc /var/log` 只读、`/tmp /dev/null` 读写。
**不含 `/opt`，也不含 `/data`。** 于是同一类报错出现在两个地方：

- Pi 的 agent 目录放在 `/opt` → 沙箱里 `Permission denied`，而 `ls -ld` 显示 mode 是 `0755 root`（uid 10001 本该能读）——
  **报错指向 Unix 权限，实际是策略边界**；
- 共享 PVC 挂在 `/data/workspace` → 同样 `Permission denied`，而**同一个 PVC 挂进普通 Pod** 时 uid 10001 读写都正常。

**结论：**"策略基线覆盖了哪些路径"是平台契约的一部分。任何基线之外的路径（agent 目录、工作区、缓存）都必须显式进策略，
且要在开通流程里生成，不能靠调镜像。POC2 §5.3 写了"每个 Sandbox 使用自己的 OpenShell 策略"，但没写**为什么必须** —— 上面就是为什么。

### 5.2 沙箱以 uid 10001 运行，镜像里的 `USER` 会被覆盖

POC2 §6.1 的 Dockerfile 用 `USER node`，实际沙箱里是 `uid=10001`。因此：镜像里 `chown node` 的目录不可写；
镜像的 `ENV PI_CODING_AGENT_DIR` **不会**传进沙箱。Pi 镜像的正确做法是构建期把 agent 目录（含扩展）准备好并设成
**所有 uid 可读**，运行期复制成可写副本（`poc/pi/setup-agent-home.sh`）。同一个坑在 `USER node` 之后的 `/opt`
上也出现过一次（构建期 `unable to find user node`）。

### 5.3 凭据与网络是同一个控制点，不是两层

Provider profile 同时声明 **endpoint + 哪个二进制能去 + 凭据放哪儿**。实测：

- OpenShell **不把任何 provider profile 编进发行版**（源码注释原话）。`provider create --type openai` 必然报
  `provider profile 'openai' not found` —— **平台必须自己声明允许哪个主机**。这不是缺陷，是这个模式的前提。
- 官方 `providers/openai.yaml` 的注释明确要求：**另一个主机上的 OpenAI 兼容服务要另建一个 profile 命名那个主机**，
  不要改官方的。本轮照做（`poc/providers/poc-model.yaml`）。
- 凭据的存储键是 profile 里声明的 **`env_vars` 名**（`OPENAI_API_KEY`），不是逻辑名（`api_key`）。写
  `--credential api_key=…` 会得到 `provider credentials are not declared by profile 'poc-model': api_key`。
- **不需要凭据的纯出权也能表达**（`credentials: []` + `--provider poc-git`），这让"沙箱能访问 GitHub"成为
  **显式声明**而不是默认允许。
- ⚠️ `access: read-only` 是**按 HTTP 方法**过滤的，不是按业务动作。`git clone` 一定要 POST（smart-HTTP 的 fetch 协商），
  于是被 L7 拒：`OCSF HTTP:POST [MED] DENIED POST …/git-upload-pack [policy:_provider_poc_git engine:l7]`。
  git-over-HTTPS 要 `access: read-write`。而且**改 profile 不会追认到已存在的 Sandbox** —— 有效策略在 create 时快照。

### 5.4 租户网络隔离：平台策略（POC3 补齐）+ OpenShell 边界，两层要分开写

**POC3（2026-11-10）已补齐平台层，并推翻了本节原标题的结论。**先看现在的实测（用例 N-01..N-05）：

| 用例 | 实测 | 含义 |
|---|---|---|
| N-01 | 两个租户的 4 个 ns 各有 `capsule-tenant-<t>-0` | Capsule `spec.networkPolicies` 已非空，平台真的下发了 |
| N-02 | tenant-a 普通 Pod → tenant-b 服务端 Pod：**`BLOCKED`** | 跨租户被平台策略拦住（第二轮同一测试是 `REACHED`） |
| N-03 | tenant-b → tenant-b（正对照）：**`REACHED`** | 不是"网络本来就断" |
| N-04 | 租户自建一条宽松 Ingress 策略后再测：**`REACHED`** | ⚠️ NetworkPolicy 语义是并集，租户能把边界**放宽** |
| N-05 | 撤掉自建策略：**`BLOCKED`** | 边界恢复 |

所以现在的表述是：**"租户之间的网络隔离"是平台能力**（Capsule Tenant 的 `networkPolicies`），
且它是**可加的** —— 要"画了就不能改"，得用 Capsule `spec.rules.enforce.policies` 或
Antrea ClusterNetworkPolicy（平台独占）。⚠️ Capsule 0.15.2 里 `spec.networkPolicies` 已标为
deprecated，升级前要按 TenantReplications 重写。

**而 OpenShell 沙箱那一侧，机制仍是它自己生成的两条策略相加**（与平台策略无关，两者叠加生效）：

   ```
   openshell-sandbox-workloads:  policyTypes=[Ingress,Egress]，但只定义了 ingress 规则
                                 ⇒ 声明了 Egress 而没有任何 egress 规则 = workload 出网**全部 deny**
   os-control-<boundary-pair>:   唯一放行的 egress = 同一个 boundary-pair 的 supervisor:5500
   ```

   也就是说"沙箱只能连自己的 supervisor"不是某条 allowlist，而是"deny-all（由空 egress 隐含）+ 一条 pair 内放行"。
   ⚠️ 取证时**不要**只打印 `openshell-sandbox-workloads` 的 `.spec.egress` —— 它本来就是空的，那一列等于没证据；
   要连 `os-control-<pair>` 的 `.spec.egress[0].to` 一起取（脚本里已改成这样）。

**两条结论必须分开写**（POC2 §9 / §11 把它们混在一起了）：

- **"Agent 无法绕过 Supervisor 直接访问网络"成立** —— 拦它的是沙箱 workload 上那两条 L4 NetworkPolicy。
- **"租户之间的网络隔离"是平台能力**（A 用户的普通 Pod 也进不了 B 的 ns），但它是可加的，
  平台要自己决定是否收紧到"租户不可改"。

⚠️ 历史：第二轮时 `spec.networkPolicies` 是**空的**，两个普通 Pod 跨租户是 `REACHED`，当时的结论是
"隔离只是 OpenShell 边界的副作用"。那条结论**已作废**，只在 git 历史里保留。

⚠️ 测这条时有**两个坑叠在一起**，都会给出假的"隔离生效"：① **目标 Pod 必须在被测端口上真有监听**，
否则 `nc -z` 一定失败，得到的 `NOT_REACHED` 是"没人监听"而不是"被策略拦"；② **busybox 的 `nc -l` 只服务一条
连接就退出**（alpine 里 `-k` 不可靠），所以"先自证在监听"这一步会**自己把 listener 用掉**，下一条跨租户测试必然失败。
正确写法：`while true; do nc -l -p <port> </dev/null; done`，自证只打 127.0.0.1，并且放在跨租户测试**之后**。
两轮在这条上得到过**相反**的结论，差别只在有没有 listener。

顺带一条同机制的实测（SEC-13）：**"换个进程绕过 Agent 工具调用"这条路不存在。**用镜像里的 `node`
直接开原始 socket（不经 Pi、不经任何工具调用），它连**自己的 supervisor:5500** 是 `CONNECTED`（正对照），
其余全断：Kubernetes API `TIMEOUT`、写死的 `1.1.1.1:443`（跳过 DNS）`TIMEOUT`、`dns.lookup` = `EAI_AGAIN`。
拦它的显然是上面那两条 NetworkPolicy（**L4**），不是 OpenShell 的 L7 策略 —— 所以给沙箱加任何额外出口
（自建 proxy、别的 agent runtime）都要改 NetworkPolicy，只改 L7 策略不够。
⚠️ 这条**必须带正对照**：实测过一次 Service 的 clusterIP 取空，`CONNECTED` 变 `ECONNREFUSED`，
看着像"被边界拦"，其实是根本没拿到地址。

### 5.5 读写分权是**两条独立的强制链**，只测一条会在另一层漂移时失效

| 配置 | mountinfo | 写的结果 | 强制发生在 |
|---|---|---|---|
| 挂载 rw + 策略只读 | `rw,relatime` | `touch: … Permission denied`（EACCES） | OpenShell 策略层（agent 进程的系统调用层） |
| 挂载 ro + 策略可写 | `ro,relatime` | `Read-only file system`（EROFS） | Kubernetes 挂载层 |
| 两者都关（Reviewer 实际配置） | `ro,relatime` | EROFS | 两层同时 |

errno 不同，正好证明这是两条链，不是一条策略的两种写法。**生产上两条都要留。**
POC2 §10.5 要求"必须真实进入 Reviewer 容器执行，不能只看 PVC YAML 的 readOnly" —— 这条要求是对的：
本轮 ❌ 的直接原因就是策略文件的 YAML 与 developer 版一字不差，只有注释不同。

⚠️ 读挂载标志**不要按固定列号**取。`/proc/self/mountinfo` 里字段 4 是挂载根、5 是挂载点、6 才是挂载选项，
中间还可能有 `shared:`/`master:` 这类可选字段。写 `awk '{print $4}'` 时 dev 与 reviewer 都打印 `/`，
这一列证据等于没测（本轮踩过）。正确做法是"找到挂载点那一列，打印它的下一列"。

### 5.6 Supervisor 断链：数据面不 fail-closed，控制面才 fail-closed（实测）

沙箱 Pod 的**唯一**出网路径是自己的 supervisor（`os-control-<pair>` 的 egress 只到它），而 supervisor 的
egress 是**全开**的：

```
kubectl --context $CTX -n $NS get netpol openshell-sandbox-supervisors \
  -o jsonpath='{.spec.policyTypes} {.spec.egress}'
#   ["Egress"] [{}]   <== 只声明 Egress 受管、没有任何 to —— 出网全开
```

断链要用 **`kubectl scale statefulset/os-a-openshell --replicas=0`**（Gateway 是 StatefulSet，
`scale deployment/...` 会 `Error from server (NotFound)`）。实测结果（2026-11-09，
`phases/13-security-matrix.sh` 的 SEC-12 一节可整段复现）：

- **数据面不 fail-closed**：在沙箱里起一个每 20s 调一次模型的循环，Gateway 缩到 0 的窗口里 agent
  **仍然连续拿到回复**。次数是每轮变动的（两次实测：`3 → 5 → 9` 与 `3 → 4 → 8`，时间戳都落在停机窗口内），
  但**方向是确定的：断链期间持续增长**。同期该 supervisor 的 `OCSF HTTP:POST` 计数也涨（一次实测 6 → 14）。
- **控制面 fail-closed**：`sandbox create` 失败，而且 `sandboxes.agents.x-k8s.io` 里**连对象都没有**（0 个）。
- supervisor **察觉**了断链：它自己的日志出现 `OCSF NET:FAIL [LOW] os-a-openshell.tenant-a-gateway.svc.cluster.local:8080`，
  Gateway 回来后变回 `NET:OPEN` —— 察觉了，但仍然继续代理**已批准的** L7 流量。

⚠️ 这一条**测法比结论更容易错**，两条 exec 通道都会骗人：`openshell sandbox exec` 自己走 Gateway
（一断就 `Error: × connect error: transport error`，看着像数据面也断了）；`kubectl exec` 的环境**不完整**
（没有注入的 `OPENAI_API_KEY` 占位符、没有 supervisor CA），跑 pi 会得到
`providers.poc-model.apiKey: must not have fewer than 1 characters` + `No models available` ——
那是"没有模型"，不是"网络不通"。所以测数据面要么让调用在沙箱内**自循环**、断链期间只用 `kubectl exec`
**读它的日志文件**（读文件不需要模型、也不依赖 Gateway），要么先 `export` 占位符**再**跑
`setup-agent-home.sh`（`models.json` 是它生成的，顺序反了 key 就是空的）。

⚠️ 本节之前写过"用 NetworkPolicy 掐断后数据面 `http=200`"：**那个数字不能复现，测法本身也不对** ——
`sec12-cut` 那条 netpol 掐的是 supervisor 的出网，跟"supervisor ↔ Gateway 断链"不是一件事。
上面是换成缩容 Gateway 之后的实测。

### 5.7 Agent 侧的 OTLP 是"免费"的，但要理解它接到哪儿

创建沙箱后 OpenShell 自动注入：

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://192.0.0.8:4318   # 这个沙箱自己的 supervisor relay
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
NODE_EXTRA_CA_CERTS=/run/openshell-supervisor-ca/material/ca.crt
```

pi-otel 正好读这两个环境变量，所以 **agent 不需要知道 Collector 地址、也不需要任何 Collector 凭据** ——
POC2 §8.2 想要的效果是现成的（relay 默认关闭，`otlp.agent.enabled=true` 一开就有）。relay 说 OTLP/HTTP protobuf
（发 JSON 会得到 415 并明确告诉你 `send application/x-protobuf`）。

POC-11 已经证明 relay **会**给 span 补 `openshell.sandbox.id`（源码 `otlp_relay/enrichment.rs`）——
这正是这套模式能不能产生审计价值的关键一环，答案是能。

⚠️ 但 `service.name` 要显式钉住：pi-otel 的取值顺序是 `process.env.OTEL_SERVICE_NAME ?? settings.serviceName ?? "pi"`，
而它找 settings 用的是 **`homedir()`，不是 `PI_CODING_AGENT_DIR`**。所以调用 pi 之前必须让 `HOME` 与
`PI_CODING_AGENT_DIR` **同值**，并**同时**设 `OTEL_SERVICE_NAME`（环境变量那条不依赖任何路径解析，是确定性的）。

### 5.8 失败路径很长，跨产品

| 现象 | 报错在哪 | 真实原因在哪 |
|---|---|---|
| 第 3 个沙箱起不来 | CLI: `timed out waiting for gated workload Pod` | agent-sandbox 控制器日志: Capsule **配额**已满（先撞 `count/services`，再撞 `requests.memory`） |
| Supervisor 卡在 ContainerCreating | kubelet: `secret "openshell-client-tls" not found` | shared 模式下**平台要自己把 Secret 复制到 runtime ns**（驱动只在多 ns 模式下自己塞） |
| `ls /data/workspace` 被拒 | 沙箱内 `Permission denied` | OpenShell **策略基线**不含 `/data` |

**结论：这套模式对可观测性的要求不是"锦上添花"，而是可用性前提。** POC2 §12 的关联设计要优先覆盖
"配额拒绝""策略基线""Secret 缺失"这三类，因为运维第一次撞到它们时看到的都是**别的产品**的错误。

### 5.9 配额要按"一个沙箱的真实开销"设计

一个沙箱不止 agent 容器：还有它自己的 supervisor Pod、**两个 Service** 和一个 workspace PVC。实测一个沙箱（带 PVC）
让租户配额涨到 `limits.memory=1536Mi / count/pods=2`。`scope: Tenant` 让配额**跨该租户所有 namespace 聚合** ——
gateway Pod 也算。三条实测事实：

1. **每个沙建两个 Service**（`os-boundary-<pair>` + `os-supervisor-<pair>`），`count/services` 是最先撞到的，
   而且这条**会**直接进 CLI：`services "os-boundary-…" is forbidden: exceeded quota: … limited: count/services=8`；
2. **先撞到的其实是 `requests.memory` 而不是 `limits.memory`**：一个 Pi 沙箱的 requests = agent 1Gi
   （`--memory` 的值同时成了 requests）+ supervisor 128mi（LimitRange default）≈ **1.15Gi**；
3. Capsule 会把 tenant 级配额**按 namespace 分摊**（Tenant 写 10 → runtime 8 / gateway 2）。验证时要读**实际生效**的
   `ResourceQuota`，不是 Tenant CR 里的数。

`poc/capsule2/tenants.yaml` 已按实测重算，并把上面的报错留在注释里。

---

## 6. 对 POC2 / POC3 设计文档的修订建议（已按实测核对）

| POC2 位置 | 现状 | 应改成 |
|---|---|---|
| §4.3 | 只说 workspace chart 负责 SA/Role/RoleBinding/NetworkPolicy | **补一步**：shared 模式还要把 `openshell-client-tls` 复制到租户 runtime ns（否则 supervisor 永远起不来） |
| §4.2/§4.3 顺序 | 先 Gateway 后 workspace chart | **必须反过来**，否则 Gateway CrashLoop：`sandboxes.agents.x-k8s.io is forbidden … in the namespace "tenant-a-runtime"` |
| §4.4 | `required_labels` 用 `openshell.ai/sandbox-attachable-workspace: "${workspace}"` | 语法可用（`${workspace}` 是整值替换，不支持拼接），但**必须同时有一个不含 `${workspace}` 的固定标签**，否则启动校验拒绝：`must include a shared approval label` |
| §5.2 | "Kind 默认 storageClass 不行" | 已验证：要装 NFS + Subdir Provisioner。并且**同样的 RWX 声明放在 local-path 上会被 API 接受但停在 Pending** —— §5.2 那句警告是对的，值得加一句"这就是它的表现" |
| §6.1 | Dockerfile 里 `ARG` 写在 `FROM` 之前 | **版本根本没锁上**：stage 里 `${PI_VERSION}` 展开为空，装的是 latest，且不报错。`ARG` 必须在 `FROM` 之后 |
| §6.1 | `USER node` + `ENV PI_CODING_AGENT_DIR` | 沙箱以 uid 10001 运行、镜像 ENV 不注入 → 需要运行期的可写 agent home |
| §6.2 | `pi install npm:pi-otel` 在运行期 | 必须**构建期**装（运行期出不了网）；手工拷扩展会缺依赖（`Cannot find module '@opentelemetry/api'`），要用 Pi 自己的 installer |
| §6.2 | 配置写在哪都行 | 必须写到 `~/.pi/agent/settings.json` 或 `<cwd>/.pi/settings.json`，否则**静默忽略**；并显式设 `OTEL_SERVICE_NAME` |
| §7.3 | "Tetragon 提供 eBPF 观测" | 加前提：**宿主内核 LSM 必须含 `bpf`**（`lsm=bpf`），否则 lsm-hook 策略全部加载失败；另外 1.8.0 的 `kprobe_multi` 默认会拒绝同符号重复/Overrides，需要 `--disable-kprobe-multi` |
| §8.3 | `[openshell.gateway.otlp.ocsf] enabled = true` | v0.1.7 的 chart 只暴露 `ocsf_log`(JSONL)，但**产品支持 OCSF over OTLP**（只是 chart 没暴露 values）。文档应把它标成"已验证，需直接写 TOML"，并说明它走 Collector 的 **logs** pipeline |
| §9 / §11 | 把"租户网络隔离"与"Agent 不能绕过 Supervisor"并列 | **拆成两条**（见 §5.4）：后者由 OpenShell 的 L4 策略保证；前者 POC3 已作为**平台能力**补上（Capsule `networkPolicies`，N-01..N-05），但可加 —— 租户能自己放宽 |
| §11 SEC-13 | "不允许绕过 Supervisor" | 结论成立，但**要写清是哪一层在拦**：实测非 Pi 进程（`node` 原始 socket）连不上任何非 supervisor 的目标，连 DNS 都失败 —— 拦它的是 workload 的 **L4 NetworkPolicy**（deny-all egress + 只放行自己 pair 的 supervisor:5500），不是 Supervisor 的 L7 策略。含义：任何额外出口都要改 NetworkPolicy |
| §11 SEC-12 | "Fail Closed" | 按控制面 / 数据面分别写（见 §5.6）。实测：断链后数据面**仍通**（沙箱继续拿到模型回复），控制面**不通**（连 Sandbox CR 都没有）。断链要用 `scale statefulset/os-a-openshell 0`，不是 NetworkPolicy |
| §3.5 | "要求 Runtime 工作负载有资源 requests/limits" | 写明**这条在带 LimitRange default 的 ns 里永远不会触发**：Capsule 的 mutating webhook 在 Gatekeeper 之前就把值补上了。这是顺序决定的，不是规则写错 |
| POC3 约束 1 | "tenant-a 用户只能操作 namespace `tenant-a`" | 这个 ns **不存在**（`forceTenantPrefix` ⇒ `tenant-a-gateway` / `tenant-a-runtime` …）。改成"每租户一组前缀 ns，逐个 ns 建 RoleBinding"；ClusterRoleBinding 会过度授权 |
| POC3 §一（`sub`） | 隐含"联邦用户的 `sub` 可直接当身份" | 默认 `sub` 是 Keycloak 本地 id，**重导入即变**。必须 `uuidLDAPAttribute=entryUUID` + mapper 把 `sub` 映射到 `LDAP_ID` |
| POC3 §一（claim 形状） | 两侧各自配置 claim 即可 | kube-apiserver v1.37 **只能读顶层** claim（嵌套时 Groups 静默只剩 `system:authenticated`），OpenShell 的 `rolesClaim` 支持点分路径 ⇒ 两侧统一用扁平 `groups` |
| POC3 §一（audience） | `--oidc-client-id` 足以校验 aud | v1.37 **没有** `--oidc-audience`；同 issuer 其他 client 的 token 也会被接受。用 `--oidc-required-claim=aud=openshell-cli`（K-05 用第二个 client 证） |
| POC3 §四 | 隐含"改目录后下一次请求就生效" | Keycloak 26.4 联邦用户有本地副本，且**没有可用 sync 端点**；必须删副本重导入，或上同步器/自定义 SPI |
| POC3 §三 | 隐含"Workspace 成员资格跟随目录组" | 不会。成员是按 subject 写的资源成员表（C-04）；需要"目录组 → Workspace 成员"的同步控制器 |

---

## 7. 手工复验清单

**环境：** `ssh root@192.168.5.190`，工作树 `/root/poc2`（与本地 `poc/` 双向同步），集群 context
`kind-agent-runtime-poc`，CLI `vendor/openshell-cli-0.1.7/openshell`，gateway 别名 `poc2-a` / `poc2-b`，
workspace `poc-shared`，租户 ns `tenant-a-{gateway,runtime}` / `tenant-b-{gateway,runtime}`。

**POC3（身份链）另有一组入口**：gateway 别名 `p3-alice` / `p3-bob` / `p3-tadmin`，
Gateway `https://172.22.0.3:31444`（NodePort，**不要 port-forward**），Keycloak `https://172.22.0.3:31443`，
Workspace `ws-tenant-a` / `ws-tenant-b`，租户普通用户 `alice` / `bob`、管理员 `tadmin`（密码都是 `poc3pass`），
脚本 `phases/14-identity-federation.sh`。

先起 CLI 需要的 mTLS 隧道（11/13 号脚本自己会起；手工测要先起）：

```bash
kubectl --context kind-agent-runtime-poc -n tenant-a-gateway \
  port-forward svc/os-a-openshell 18441:8080 &
```

**顺序：** `01 → fix-apiserver-sans → 02 → 03 → 04 → 05 → 06 → 07 → 10 → 08 → 09 → 11 → 12 → 13`。
10（观测栈）必须在 08（Gateway）**之前**：否则 gateway 启动初期所有 OTLP export 都失败，
会被误读成"OpenShell 没配好"。13 依赖 11 留下的 Developer 沙箱与共享 PVC。

⚠️ **同一时间只跑一个 phases 脚本。**它们共用同一个 Gateway 与同一份租户配额，两个脚本并行时
配额会被双倍消耗（本轮实测：一条 SSH 断线留下的孤儿进程与新一轮并行，SEC-12 的计数与配额都不再可信）。
在远端跑之前先 `pgrep -af "phases/"` 确认没有上一次留下的进程。

### 7.1 按脚本复现

| 脚本 | 覆盖 | 成功时要看的标记 |
|---|---|---|
| `phases/01-cluster.sh` + `kind/fix-apiserver-sans.sh` | 集群与外部可访问 | `readyz: ok`、`从外部读到 namespace 数=<N>` |
| `phases/02-antrea.sh` | 唯一 CNI | `daemon set "antrea-agent" successfully rolled out`、3 节点 Ready |
| `phases/03-netpol-verify.sh` | POC-05 | `### 结果: PASS=9 FAIL=0`，且 `deny-all 使 br-int 流表增加(n0 -> n1) 期望=OK`、`撤销后流表回落` |
| `phases/04-capsule.sh` | POC-02 | 归属标签 + `Tenant.status.namespaces` + 自动下发的 ResourceQuota；`(b) tenant-b-steal -> 期望被拒`、`(c) 无租户前缀 -> 期望被拒` |
| `phases/05-gatekeeper.sh` | POC-06 / SEC-09 | 每条 `✓ … 被 [poc-tenant-pod-boundary] 拒绝`；平台身份那几条 `✓ … 未被约束拦截` |
| `phases/06-agent-sandbox.sh` | POC-03 前提 / SEC-10 | `两边都是 agents.x-k8s.io/v1beta1（Sandbox）：兼容`；`[poc-managed-cr-only-platform]` 出现 |
| `phases/07-rwx-storage.sh` | RWX 是真的 | `local-path RWX PVC: phase=Pending`（反证）；`总行数=100 a=50 b=50`（正证，跨节点） |
| `phases/10-observability.sh` | 接入点自证 | net-probe 的 `OTLP/HTTP via svc -> ` 成功、collector debug 有 `Traces`、`http://<宿主IP>:31686` 可开 |
| `phases/08-gateway.sh` | POC-01 | 两个 `gateway_id` 不同、各自 `openshell-data` PVC；`A 的 SA 能否 list tenant-b-runtime 的 sandboxes: no` |
| `phases/09-resource-admission.sh` | SEC-14 | `✓ 无授权标签的 PVC … 被 resource admission 拒绝`、`✓ 匹配当前 workspace 的 PVC 允许` |
| `phases/11-pi-scenario.sh` | POC-04 / POC-10 / SEC-06/07 | `DEV_WRITE_OK`、两个 Reviewer 里 `?? poc_extra_test.go` 可见、`mount_flags=ro,relatime`、`删掉两个 Reviewer 之后仍在: …/poc_extra_test.go`。⚠ 脚本会打印两个 Reviewer 输出的**字节数**：其中一个是 0 字节属于已知现象（模型返回空，见 §7.3 第 12 条），不是共享失败 |
| `phases/12-tetragon.sh` | POC-07 | `PROCESS_EXEC binary=… argv=…`、`PROCESS_EXIT … status=7`、`INET … -> 1.1.1.1:443`、`(e) 身份: ns=… pod=…`；只有 `20-supply-chain` / `50-exec-enforcement` 两条 `load_error` |
| `phases/14-identity-federation.sh` | **POC3 §一–§五 + §5.4 更正** | 末尾 `PASS=49 FAIL=0`；`sub=` 等于目录 entryUUID；`alice … tenant-b-runtime -> no` 且有正对照 `bob … tenant-a-runtime -> yes`；`a -> b(跨租户): BLOCKED` + `b -> b(同租户): REACHED`；`G-05/G-11` 打印 `role 'os-admin' required` / `not a member of workspace`；`C-02/C-03` PASS。⚠️ 先看清场：残留的 `Terminating` workspace 会让 G-03/G-06/G-10 假 FAIL（§12.7 第 1 条） |
| `phases/13-security-matrix.sh` | SEC-04/06/07/08/12/13 | 完成标志：`spec.networkPolicies` 空 + 普通 Pod `REACHED` + 沙箱 `TIMEOUT`；`mount_flags=rw,relatime` 但写被拒 `Permission denied`(EACCES) 对照 `Read-only file system`(EROFS)；SEC-12 则要求断链窗口里「agent 自己拿到 DATA_PLANE_OK 次数:」**仍在增长**（绝对数字每轮不同，看方向） + supervisor 日志出现 `OCSF NET:FAIL … os-a-openshell…` + 「含 sec12-gw-down 的 Sandbox CR: 0」；SEC-13 要求「[正对照] 自己的 supervisor:5500: CONNECTED」并且其余目标 `TIMEOUT`/`EAI_AGAIN`（正对照连不上就说明这次测的不是边界）；+ 收尾必须是 `✓ Deleted sandbox sec12-loop`（若是 transport error，说明端口转发被缩容带断了，见 §7.3 第 9 条——它会把配额泄漏带到下一轮） |

### 7.2 不跑脚本的最小复验命令（每条对应一个结论）

```bash
CTX=kind-agent-runtime-poc; NS=tenant-a-runtime
cd /root/poc2
CLI=vendor/openshell-cli-0.1.7/openshell
# ⚠ 先建端口转发(CLI 只走 mTLS，且必须是 127.0.0.1:18441)。没有它，每条 $CLI 都是
#   `Error: × connect error: transport error`；如果再把 stderr 丢进 /dev/null，
#   `sandbox delete` 会**静默失败**，配额一点没少(2026-11-09 踩过)。
pkill -f 'svc/os-a-openshell 1844' >/dev/null 2>&1
(setsid kubectl --context $CTX -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 </dev/null >/tmp/pf-a.log 2>&1 &)
sleep 4
$CLI -g poc2-a --workspace poc-shared sandbox list 2>&1 | head -5   # 先确认通道是通的，再往下复验
#   复验前先清场(每个沙箱 = 2 Service + 1 PVC，`Completed` 的也算):
#   for s in $(...); do $CLI -g poc2-a --workspace poc-shared sandbox delete "$s"; done   # 保留 stderr

# POC-01 两个 Gateway 的状态互不可见
kubectl --context $CTX auth can-i list sandboxes.agents.x-k8s.io -n tenant-b-runtime \
  --as=system:serviceaccount:tenant-a-gateway:os-a-openshell                    # 期望 no
kubectl --context $CTX -n tenant-a-gateway get cm -l app.kubernetes.io/name=openshell \
  -o 'jsonpath={.items[0].data.gateway\.toml}' | grep -E '^ *(gateway_id|db_url|namespace )'

# POC-02 租户不能越界命名 / 越界建 Pod
kubectl --context $CTX create ns tenant-b-steal --as=alice --as-group=tenant-a-owners   # 期望被拒
kubectl --context $CTX -n tenant-b-runtime run x --image=alpine --as=alice \
  --as-group=tenant-a-owners --dry-run=server -o name                                  # 期望被拒

# POC-06 准入：同一 ns 内只按身份区分（--dry-run=server，不落地对象）
kubectl --context $CTX -n $NS run gp1 --image=alpine --as=alice --as-group=tenant-a-owners \
  --dry-run=server -o name \
  --overrides='{"spec":{"containers":[{"name":"gp1","image":"alpine","securityContext":{"privileged":true}}]}}'
#   期望 [poc-tenant-pod-boundary] 拒绝；把 --as 换成平台 SA os-a-openshell 则应通过

# POC-03 / 配额：读**实际生效**的配额，不是 Tenant CR
kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 \
  -o jsonpath='{.status.used}{"\n"}{.spec.hard}{"\n"}'

# POC-04 / SEC-06 / SEC-07：三层证据要分开看
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-dev -- \
  sh -c 'touch /data/workspace/sec07 && echo DEV_WRITE_OK'
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-review-1 -- \
  sh -c 'cd /data/workspace/godotenv && git status --short'     # 期望看到 ?? poc_extra_test.go
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-review-1 -- \
  sh -c 'touch /data/workspace/sec06 2>&1'                      # 期望 Read-only file system
kubectl --context $CTX -n $NS get pvc shared-workspace \
  -o jsonpath='PV={.spec.volumeName} access={.spec.accessModes}{"\n"}'   # 三个 Pod 必须是同一个 PV

# POC-08 用正确的 service.name 查 trace
JAEGER=$(kubectl --context $CTX -n observability get svc jaeger -o jsonpath='{.spec.clusterIP}')
kubectl --context $CTX -n observability run q --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s "http://$JAEGER:16686/api/traces?service=pi-agent&limit=2" | head -c 400
#   期望 span: invoke_agent pi / chat <model>；按 service=pi 查也能查到（那是配置没生效时的默认名）

# POC-09 OCSF 是否真的导出到 OTLP
kubectl --context $CTX -n tenant-a-gateway exec deploy/os-a-openshell -- \
  sh -c 'wget -qO- localhost:8080/metrics' 2>/dev/null | grep ocsf_otlp
#   期望 openshell_ocsf_otlp_exported_total > 0，且没有 *_errors_total
kubectl --context $CTX -n observability logs deploy/otel-collector --tail=400 | grep -c openshell.ocsf

# POC-07 / POC-11 内核侧
kubectl --context $CTX -n kube-system exec ds/tetragon -c tetragon -- tetra tracingpolicy list
kubectl --context $CTX -n kube-system exec ds/tetragon -c tetragon -- sh -c \
  'timeout 12 tetra getevents -o compact --timestamps --namespace tenant-a-runtime' &
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-review-2 -- \
  sh -c 'timeout 8 curl -s -m 6 https://api.open.ai/ ; true'
#   期望 Tetragon 给出 pod.name=poc-shared--pi-review-2 + argv + uid=10001；
#   同一秒 supervisor 日志给出 OCSF NET:OPEN [MED] DENIED … [reason:transparent_tcp_policy_denied]
# ⚠ getevents 只直播不回放：**先起流再造事件**，且 kubectl exec 起流要 1–2s。

# SEC-04/08 归因：平台有没有租户网络策略（POC3 起**非空**，第二轮为空）
kubectl --context $CTX get tenant tenant-a -o jsonpath='{.spec.networkPolicies}{"\n"}'   # 期望 items[0].policyTypes=[Ingress]
kubectl --context $CTX get netpol -A -l capsule.clastix.io/network-policy           # 4 个租户 ns 各一条 capsule-tenant-<t>-0
kubectl --context $CTX -n $NS get netpol | grep -v capsule-tenant                  # 其余是 OpenShell 自己建的
# 端到端（N-02..N-05 的完整写法在 phases/14-identity-federation.sh 的 2b 节）：
#   tenant-a -> tenant-b: BLOCKED；tenant-b -> tenant-b(正对照): REACHED；
#   租户自建宽松策略后: REACHED（可加性）；撤掉后: BLOCKED
# ⚠ workloads 那条的 .spec.egress **本来就是空的**（声明了 Egress、没有规则 = 出网全 deny）。
#   只打印它会得到一列空白，等于没取证。要连 pair 那条的 egress[0].to 一起看：
kubectl --context $CTX -n $NS get netpol openshell-sandbox-workloads \
  -o jsonpath='workloads: policyTypes={.spec.policyTypes} egress={.spec.egress}{"\n"}'   # 期望 Egress 受管、egress 空
CN=$(kubectl --context $CTX -n $NS get netpol --no-headers | awk '/^os-control-/{print $1; exit}')
echo "$CN:"
kubectl --context $CTX -n $NS get netpol "$CN" \
  -o 'jsonpath=唯一 egress -> {.spec.egress[0].to[0].podSelector.matchLabels} port={.spec.egress[0].ports[0].port}{"\n"}'
#   ⚠ jsonpath 段要**单引号**: 双引号里 shell 会吃掉 {"\n"}，jsonpath 收到 {n} 就报错
#   ↑ 两条相加 = workload 只能到自己那个 supervisor:5500（这才是 POC-05 的实现机制）

# SEC-12 断链：数据面 vs 控制面。整段可复现的写法在 phases/13-security-matrix.sh 的 SEC-12 一节
# （它会自己建一个名为 sec12-loop 的沙箱并起循环；下面按手工步骤重做一遍）。
# ⚠ 不要用 `sandbox exec` 测数据面：它自己走 Gateway，断链期间必然 transport error（那是 CLI 断了）。
# ⚠ 不要用 NetworkPolicy 当"断链"：那掐的是 supervisor 出网，不是 supervisor↔Gateway。
$CLI -g poc2-a --workspace poc-shared sandbox create --name sec12-loop --from pi-agent:poc \
  --cpu 500m --memory 1Gi --detach --restart-policy never --provider poc-model -- sh -c 'sleep 3600'
$CLI -g poc2-a --workspace poc-shared sandbox exec sec12-loop -- sh -c \
  'sh /usr/local/pi/setup-agent-home.sh >/dev/null 2>&1; . /tmp/pi-home.env; rm -f /tmp/sec12-loop.log
   setsid sh -c "i=0; while [ \$i -lt 60 ]; do i=\$((i+1)); printf \"== %s %s\\n\" \$i \$(date -u +%T) >> /tmp/sec12-loop.log; timeout 90 pi --model poc-model/qwen3.8-flash-next -p \"Reply with exactly the token DATA_PLANE_OK\" </dev/null >> /tmp/sec12-loop.log 2>&1; sleep 20; done" & echo LOOP_STARTED'
sleep 70
POD=poc-shared--sec12-loop
SP=os-supervisor-$(kubectl --context $CTX -n $NS get pod $POD -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair}')
kubectl --context $CTX -n tenant-a-gateway scale statefulset/os-a-openshell --replicas=0   # 这才是"断链"
#   数据面：断链窗口内读**沙箱自己**那个循环的日志（读文件不依赖模型，也不依赖 Gateway）
kubectl --context $CTX -n $NS exec $POD -c agent -- \
  sh -c 'grep -c DATA_PLANE_OK /tmp/sec12-loop.log; tail -3 /tmp/sec12-loop.log'   # 期望**继续增长**
kubectl --context $CTX -n $NS logs $SP --tail=200 | grep os-a-openshell            # 期望 OCSF NET:FAIL
kubectl --context $CTX -n $NS get netpol openshell-sandbox-supervisors \
  -o jsonpath='{.spec.policyTypes} {.spec.egress}{"\n"}'                          # 期望 ["Egress"] [{}] = 全开
#   控制面：
timeout 90 $CLI -g poc2-a --workspace poc-shared sandbox create --name sec12-gw-down \
  --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never -- 'sleep 20'   # 期望失败
kubectl --context $CTX -n $NS get sandboxes.agents.x-k8s.io --no-headers | grep -c sec12-gw-down  # 期望 0
kubectl --context $CTX -n tenant-a-gateway scale statefulset/os-a-openshell --replicas=1
#   ⚠ 缩容 Gateway 会把它上面那条 port-forward 一起弄断 —— 收尾前先**重新**建一次(脚本 §7.2 开头那条)，
#     否则这里的 delete 只会得到 transport error，sec12-loop 继续占 2 个 Service 配额。
#   ⚠ Sandbox CR 的真名是 <workspace>--<name>（如 poc-shared--gw-q），不是 <name>。

# SEC-13 另一个进程不经工具调用直接出网（复用已存在的沙箱，不消耗配额）
SP_IP=$(kubectl --context $CTX -n $NS get svc --no-headers | awk '/^os-supervisor-/{print $1; exit}' | xargs -I{} \
  kubectl --context $CTX -n $NS get svc {} -o jsonpath='{.spec.clusterIP} {.spec.ports[0].port}')
DV=poc-shared--pi-dev   # ⚠ kubectl exec 用 Pod 名 = <workspace>--<沙箱名>（§7.3 第 10 条）
cat > /tmp/sec13.js <<'JS'
const net=require("net"), dns=require("dns");
const t=(host,port,label)=>new Promise(r=>{const s=net.connect({host,port,timeout:6000});
 s.on("connect",()=>{console.log(label+": CONNECTED");s.destroy();r()});
 s.on("timeout",()=>{console.log(label+": TIMEOUT");s.destroy();r()});
 s.on("error",e=>{console.log(label+": ERROR "+e.code);r()});});
(async()=>{
 const host=process.argv[2], port=+(process.argv[3]||0);
 if(!host||!port) return console.log("  ! 正对照缺失，这次结果不可用");
 await t(host,port,"[正对照] 自己的 supervisor:"+port);   // 必须 CONNECTED，否则整段无效
 await t("10.96.0.1",443,"kubernetes API :443");
 await t("1.1.1.1",443,"1.1.1.1:443 (写死 IP，跳过 DNS)");
 dns.lookup("api.openai.com",e=>console.log("DNS api.openai.com: "+(e?("ERROR "+e.code):"OK")));
})();
JS
kubectl --context $CTX -n $NS exec -i $DV -c agent -- sh -c 'cat > /tmp/sec13.js' < /tmp/sec13.js
# ⚠ 两个参数要分开传；拼成一个字符串传过去，正对照会读不到地址（实测踩过）
kubectl --context $CTX -n $NS exec $DV -c agent -- node /tmp/sec13.js "${SP_IP% *}" "${SP_IP##* }"
#   期望: supervisor CONNECTED；其余全部连不上（TIMEOUT / EAI_AGAIN 都可能，具体错误码**不必对齐** ——
#   11 号脚本里 pi 的 curl 得到的是几毫秒的 Couldn't connect，同一个 L4 阻断的另一种表现）。
#   拦它的是 L4(NetworkPolicy)，不是 L7；只有正对照必须稳定成立。

# POC-05 手工复现一条 NetworkPolicy 断言（含 OVS 侧）
kubectl --context $CTX -n kube-system exec <server 所在节点的 antrea-agent> -c antrea-agent -- \
  ovs-ofctl dump-flows br-int | grep -c cookie      # 加 deny-all 后必须增加，删除后回落
```

### 7.3 复验时最容易误判的 12 处

1. **`pi -p` 会等 stdin。** `sandbox exec` 保持 stdin 打开 → pi 永不退出、stdout/stderr 全空、rc=124。
   必须 `</dev/null`。这一度被误读成"模型连不上"。
2. **`service.name` 默认是 `pi`。** 按 `pi-agent` 查不到不等于没上报（见 §5.7）。
3. **`Completed` 的沙箱仍占配额**，必须 `sandbox delete`；而且 `sandbox list` 的 `PHASE` 是**第 4 列**
   （`CREATED` 里的日期和时间被空格分成两列），按 `$2`/`$3` 过滤永远匹配不到，看起来像"前置没跑"。
   同一张表的列是**空格补齐**的：用 `grep "^name$"` 锚到行尾也**永远匹配不到**（实测 `wait_ready`
   因此等到超时，而列表里明明是 `Ready`）。要写 `grep "^name[[:space:]]"`。
4. **`--dry-run=server` 测准入**落在 `admission_dryrun="true"` 序列上，看 metrics 要按 `admission_dryrun=false` 过滤；
   Gatekeeper **每个副本一套计数**，只看一个 pod 会漏。
5. **Tetragon 的判断只能以 `tetra tracingpolicy list` 的 STATE 为准**：`kubectl apply` 的退出码与 CRD status 都不能用
   （1.8.0 里加载失败的策略 status 也是空 `{}`）。0 事件先查 selector；JSON 里身份是 `process.pod`、
   五元组在 `args[].sock_arg`、`security_socket_connect` 的目的地在 `args[].sockaddr_arg`。
6. **kind 节点容器里没挂 securityfs** —— `cat /sys/kernel/security/lsm` 要在**宿主**上看，节点里读不到。
7. **这台宿主上 GitHub release asset 与 raw.githubusercontent.com 会超时**（503/504）。用
   `poc/scripts/gh-fetch.sh`（走 `api.github.com` 的 asset 端点）；helm repo 与 ghcr.io 不受影响。
   ⚠️ 从 Mac 直连该 IP 时，kubectl/helm（Go 二进制）会 `connect: no route to host`（本机 Clash TUN 路由问题），
   `curl`/`nc` 正常 —— 见 `poc/kind/README-external-access.md`，必要时走 `poc/kind/ssh-tunnel.sh`。
8. **NodePort 不会自动发布到宿主**：必须在 kind 配置里用 `extraPortMappings` 显式映射（`31686` 已配）。
   宿主上的 Tempo 用 `--net=host`，query 端口是 **3200**（不是 3100），探测写错会得到"没有 Tempo"。
9. **SEC-12 的两条 exec 通道都会给出假结论**：`openshell sandbox exec` 自己走 Gateway（断链必然
   `transport error`）；`kubectl exec` 环境不完整（无注入凭据/CA，pi 说"没有模型"）。测数据面用
   "沙箱内自循环 + `kubectl exec` 读日志文件"。见 §5.6。
   ⚠ 还有一个**会坑到脚本自己**的：把 Gateway 缩到 0 会把它底下那条 `port-forward` 一起带走，
   于是恢复之后脚本末尾的 `sandbox delete` 只做了一次 transport error 就过去了（若 stderr 进了
   `/dev/null` 就完全看不见）—— 实测 `sec12-loop` 因此没被删，白占 2 个 Service 配额，下一轮 create 撞配额。
   13 号脚本现在在收尾前显式重建端口转发（`PF` 函数），并把删除的 stderr 打出来。
10. **Sandbox CR 的真名是 `<workspace>--<name>`**（如 `poc-shared--gw-q`）。按 `get sandbox gw-q` 查会
    NotFound，把一次**成功的**创建读成失败的。
11. **每个沙箱占 2 个 Service + 1 个 PVC**（`os-boundary-*` / `os-supervisor-*` / `workspace-<ws>--<name>`），
    所以最先撞满的是 `count/services` 与 `persistentvolumeclaims`，**不是** `count/pods`。
    两种撞满的**症状不一样**（都是实测）：撞 `count/services` 会有明确报错
    （`services "os-boundary-…" is forbidden: exceeded quota …`，见 §5.9）；
    撞 PVC 时 create **不报原因**，要到下一步 exec 才暴露成 `sandbox not found`。
    实测：`sandbox delete` **会**连带删掉它自己的 PVC（8/9 → 7/9，删干净后 `services=0/12 pvc=3/9`），
    所以清理办法就是真的删沙箱；但 `Completed` 的沙箱仍然占着这三份，复验前先 `sandbox list` 清场
    （`Completed` 的也算）。⚠ 不要直接 `kubectl delete pvc`：pod 还在终止时 PVC 会卡在 Terminating。
    ⚠ **清理之前要先建端口转发**：没有它，`sandbox list/delete` 每条都是
    `Error: × connect error: transport error`，如果把 stderr 丢进 `/dev/null`，删除就**静默失败**、
    配额一点没少（实测：9 个 delete 全部无声失败，配额仍是 8/12）。要么 `2>&1` 留着错误，要么先
    `kubectl -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 &`。
12. **本地模型有时会返回空，而且退出码仍是 0**。复跑 11 号脚本时 `/tmp/rev-1.out` 是 0 字节、
    `rev-2.out` 有内容 —— 同一个 prompt、同一个模型、同一个沙箱配置。所以"两个 Agent 各自给出 review 结论"
    是**不确定**的（模型侧），不要把它写成平台能力；反过来，模型答得差/答空也不算平台缺陷。
    平台侧能确定的是：共享可见、只读强制、并行不互斥。

---

## 8. 复现环境

```bash
# 宿主：Ubuntu 24.04 / kernel 6.8.0-147（有 BTF，LSM 不含 bpf）/ 48C / 94G
ssh root@192.168.5.190 'cd /root/poc2 && bash phases/NN-*.sh'

# 01 之后必须补 apiserver SAN（kind 的字段名是 certSANs，写 extraSANs 会被**静默忽略**）
ssh root@192.168.5.190 'cd /root/poc2 && SAN=192.168.5.190 bash kind/fix-apiserver-sans.sh'
```

外部可访问的**两个**必要条件：证书 SAN 含宿主 IP、NodePort 用 `extraPortMappings` 显式发布。
完整说明见 [`poc/kind/README-external-access.md`](poc/kind/README-external-access.md)。

⚠️ **`/root/poc2` 是 `poc/` 的镜像，同步时不要用 `--delete`。** 宿主上的 `vendor/`
（OpenShell CLI 二进制、workspace chart）**不在 git 里**（`.gitignore` 有意忽略），
`rsync --delete` 会把它删掉，症状是每条 phases 脚本都在 `vendor/openshell-cli-0.1.7/openshell:
No such file or directory` 上失败。恢复办法就是它自己的取法：
`bash phases/08-gateway.sh` 的前四行（走 `scripts/gh-fetch.sh` 的 `api.github.com` asset 端点），
或单独跑 `bash scripts/gh-fetch.sh NVIDIA/OpenShell v0.1.7 openshell-x86_64-unknown-linux-musl.tar.gz openshell-cli-0.1.7.tar.gz`
再解压到 `vendor/openshell-cli-0.1.7/`。

⚠️ 反过来的一条：**rsync 不会打断正在跑的脚本，但也不会被它读到。**rsync 是"写新文件再改名"，
正在执行的 bash 仍然握着旧 inode（`/proc/<pid>/fd` 会显示 `… (deleted)`），所以改完脚本想让改动生效
必须**重跑**，不能指望跑到一半的进程用上新代码。


### 组件版本

| 组件 | 版本 |
|---|---|
| kind / Kubernetes | v0.33.0 / v1.37.0 |
| Antrea | 2.7.0 |
| Capsule | 0.15.2（cert-manager v1.20.2） |
| OPA Gatekeeper | 3.23.1 |
| agent-sandbox | v1.0.10（Sandbox API `agents.x-k8s.io/v1beta1`） |
| OpenShell | 0.1.7（chart 0.1.7 / CLI 同一版本） |
| Keycloak / OpenLDAP（POC3） | 26.4 / 1.5.0（`identity` ns，NodePort `31443`） |
| Tetragon | 1.8.0 |
| NFS Server Provisioner | 1.8.0 |
| OpenTelemetry Collector (contrib) / Jaeger | 0.155.0 / 1.69.0 |
| Pi Coding Agent / pi-otel | 1.5.0 / 0.3.0 |
| 模型 | 宿主本机 llama.cpp/Strata，OpenAI 兼容 `:8080`，`qwen3.8-flash-next` |

### 演示入口

- 宿主 Grafana（Tempo 数据源）：`http://<宿主IP>:3000`
- 集群内 Jaeger UI（NodePort，需 `extraPortMappings`）：`http://<宿主IP>:31686`
- OTLP 接入点：Collector `observability/otel-collector:4317`(gRPC) / `:4318`(HTTP)
- POC3 Gateway（OIDC）：`https://172.22.0.3:31444`；Keycloak：`https://172.22.0.3:31443`
- 查询手册：[`poc/usage/02-agent-visibility.md`](poc/usage/02-agent-visibility.md)

---

## 9. 仓库结构

```
README.md          结论(中文，唯一出处)
README.en.md       同一份结论(英文)—— 两份内容一一对应，改一处要同时改另一处
POC2.md            设计原文（第二轮）
POC3.md            设计原文（第三轮：LDAP → Keycloak → K8s/OpenShell 统一权限）
poc/
├── phases/        01→13（POC2）、14（POC3 身份链矩阵）可重复验证脚本（10 在 08 之前）
├── kind/          poc2-cluster.yaml · fix-apiserver-sans.sh · README-external-access.md · ssh-tunnel.sh
├── capsule2/      租户与配额（按实测重算，含配额算术的注释）
├── gatekeeper/    约束模板与约束实例
├── openshell2/    Gateway values（shared 模式，含 otlp.ocsf 的实测更正）
├── openshell3/    POC3 的 OIDC Gateway（values / NodePort / CLI device-flow 登录库）
├── openshell4/    POC4 Deployment + 外部 PostgreSQL（两个 release 共库 / HA / 验证矩阵）
├── identity/      POC3 身份链：LDAP 条目与种子 Job、Keycloak realm 脚本与 claim mapper、
│                  apiserver OIDC 补丁、按租户 ns 的 RBAC、自建 issuer CA
├── providers/     Provider profile（模型出口、GitHub 纯出权）
├── policies/      Developer / Reviewer 文件系统策略（只差一行，有 diff 断言）
├── pi/            Pi 镜像与运行期 agent home 初始化
├── observability2/ Collector 配置（双出口：集群内 Jaeger + 宿主 Tempo）
├── observability/ OTLP 自检 Pod
├── storage/       RWX PVC、探针、workspace PVC（含批准标签）
├── tetragon/      观测与强制策略
├── scripts/       gh-fetch.sh（绕开 release asset 超时）· bootstrap.sh
├── usage/         开通脚本 · Tetragon 查询手册 · 第一轮演示脚本
└── docs/          POC2-CONCLUSIONS.md（逐条原始输出）· FINDINGS.md（第一轮证据附录）
```

第一轮的资产（`agent/`、`capsule/`、`openshell/`、`agent-sandbox/`、`usage/01,03`）仍在仓库中，供对照与复用；
它们对应的结论文档已删除，只在 git 历史里保留。

---

## 10. 离生产还差什么

按"必须解决 → 应该解决"排序：

1. **租户网络隔离已补上，但它是"可加"的。** Capsule `networkPolicies` 已让跨租户普通 Pod `BLOCKED`
   （§5.4），但租户自建一条策略就能放宽（N-04）。生产要决定：接受（写进租户协议），或用 Capsule
   `spec.rules.enforce.policies` / Antrea ClusterNetworkPolicy 收紧。另：该字段在 Capsule 0.15.2 已 deprecated。
2. **观测后端的持久化与证据留存。** Jaeger all-in-one 是内存存储，两轮里各丢过一次证据；本轮改成双出口
   （集群内 Jaeger 供脚本断言、宿主 Tempo/Grafana 供演示），生产要换带存储与保留期的后端。
3. **Gateway 单副本 + SQLite。** POC2 §1.3 把 HA 排除在 PoC 外是对的，但"生产前必须解决"里要有：外部 PostgreSQL，
   以及 Gateway 证书轮转如何**持续**同步到 runtime ns 的 client-TLS 副本（不是一次性的平台步骤）。
4. **Tetragon 的强制能力取决于宿主内核**（LSM 需含 `bpf`），属于交付前提，要进开通检查。
5. **OCSF 的 chart 支持不完整。** v0.1.7 的 chart 没有把 `otlp.ocsf` 暴露成 values，现在靠直接写 TOML；
   升级时要断言这个键仍然存在（`openshell_ocsf_otlp_exported_total` 是最直接的哨兵指标）。
6. **配额模型要写进开通流程。** 按沙箱数算 `count/services`、`requests.*`、`limits.*`、`persistentvolumeclaims`
   （§5.9），并把"配额拒绝"做成可观测的一等事件 —— 否则运维看到的永远是别的产品的 timeout。
7. **多 Agent 协作目前只到"共享 + 只读 + 并行"**，没有 Agent 之间的消息/锁/合并语义；这属于产品层，不是平台缺口，
   但报告里不要把两者混为一谈。
8. **目录变更没有可靠的下游通道（POC3 最重要的生产缺口）。** Keycloak 26.4 的联邦用户是惰性导入 +
   本地副本，改目录组不会刷新 token，且**没有可用的 sync 端点**（§12.4）。POC 用"删本地副本"绕过；
   生产必须选：定期 full sync 的同步器 / 自定义 User Storage SPI（逐请求读目录）/ 接受 TTL 延迟。
9. **Workspace 成员资格不跟随目录组。** 需要"目录组 → Workspace 成员"的同步控制器，否则每个租户变更
   都要人工 `workspace member add`，而它没有任何审计闭环（§12.4 C-04）。
10. **身份链的可用性也是单点。** Keycloak / OpenLDAP 都是单副本；issuer NodePort 直接暴露。
    生产要决定 token 校验的离线性（JWKS 缓存与 TTL、issuer 高可用）以及 Keycloak 自身的高可用。

---

## 11. 历史

- **第一轮（2026-11-03）**：operator 模式，Mac + Docker Desktop + 两个 kind 集群。验证了预热池
  （warm claim 0.25s / 冷启动 0.92s / 需拉镜像 15.98s）、uid 10001、内核层快速拒绝（EPERM，立即）、
  OTLP 与内核事件对齐等。证据在 [`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md)。结论文档已删除，只在 git 历史中。
- **第二轮（2026-11-08 → 11-09）**：POC2 **shared 模式**，单租户单 Gateway。逐条原始输出在
  [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md)。⚠️ 其中 §5.4（网络隔离归因）已按第三轮实测更正。
- **第三轮（2026-11-10，POC3）**：LDAP → Keycloak → 一个 OIDC JWT → kube-apiserver 与 OpenShell Gateway。
  新增 `identity` ns（OpenLDAP + Keycloak 26.4）、apiserver OIDC flags、按租户 ns 的 RBAC、
  第三台 OIDC Gateway（两个 Workspace），并给两个 Capsule Tenant 补上 `networkPolicies`。
  结论见 **§12**，脚本 `phases/14-identity-federation.sh`。**这一轮不与第二轮冲突：POC2 的两台 Gateway 原样保留。**
- **第四轮（2026-11-11，POC4）**：Gateway 从 StatefulSet + SQLite 改为 Deployment + 外部 PostgreSQL；
  两个独立 Helm release（p4a/p4b）共用一套 PG，同 release 2 副本 HA。脚本 `openshell4/`，结论见 **§13**。
  它不改 POC2/POC3 的 Gateway。
- **当前有效结论**：第二轮的组件结论 + 第三轮的身份/权限与网络隔离更正 + **第四轮的存储形态（§13）**。
## 12. POC3（第三轮，2026-11-10）：一套权限体系统管 Kubernetes 与 OpenShell

> 设计原文见 [`POC3.md`](POC3.md)。整张矩阵由 `poc/phases/14-identity-federation.sh` 一条命令跑完，
> 末尾打印 `PASS=n FAIL=m`；本节引用的每个判定都来自这一次运行（远端原始输出 `/tmp/p14f.log`）。
> **POC2 的两台 Gateway 与第 1–11 节结论不受影响**：POC3 是第三台 Gateway（`poc3-gateway/p3-openshell`，
> NodePort `https://172.22.0.3:31444`），身份域是新的 `identity` namespace。

### 12.0 一句话结论

`自研 LDAP → Keycloak（用户联邦）→ 一个 OIDC JWT → kube-apiserver 与 OpenShell Gateway 各自授权`
**实测成立**，且两侧用的是**同一个** `sub`（目录 `entryUUID`）与**同一个** `groups` claim：

| 验收面 | 结论 | 证据 |
|---|---|---|
| 身份链路 | ✅ 实测通过 | 三个用户的 `sub` 全等于目录 `entryUUID`；`tenant` / `groups` 全部来自 LDAP 属性与组，Keycloak 与 K8s 里**没有**手工复制的用户/角色 |
| Kubernetes 隔离 | ✅ 实测通过 | `kubectl auth can-i` 矩阵 + **真实创建**双向验证；跨租户写被 RBAC 拒（不是只看 `can-i`） |
| OpenShell 隔离 | ✅ 实测通过 | 一台 Gateway、两个 Workspace；成员资格按 subject 绑定，拒绝原文明确到 `reason:not_workspace_member` |
| 跨系统一致性 | ⚠️ 有条件通过 | 两侧同 claim、同 subject；但**目录变更不会自动到 token**（C-02/C-03 要靠删本地副本），Workspace 成员资格**不随**目录组走（C-04） |
| 失败可观测 | ✅ 实测通过 | 每次拒绝都在 Gateway OCSF 里留下 `DENIED … reason:missing_role / not_workspace_member`，带 subject 与 gRPC 方法名 |
| 租户网络隔离（POC2 §5.4 更正） | ✅ 实测通过 | Capsule `networkPolicies` 已落到两个租户的 4 个 ns；跨租户 Pod `BLOCKED`，同租户正对照 `REACHED`；含可加性告警 |

**本轮最重要的两个"不是缺陷的限制"**（详见 §12.6）：

1. **kube-apiserver v1.37 只能读顶层 claim**，OpenShell 的 `rolesClaim` 却支持点分路径 ⇒ 两侧必须约成一个**扁平** claim（本项目用 `groups`）。
2. **Keycloak 26.4 的联邦用户是"惰性导入 + 本地副本"**：改了目录组，token 里不会变，且 26.4 **没有可用的同步端点**（`kcadm … sync` 报 `Missing action`，REST 返回 400 `Unknown action`）。唯一实测可行的是删掉本地副本让下次认证重导入 —— 生产上必须有一个同步器，否则权限变更永远慢一步。

---

### 12.1 一、身份与声明设计（配置文档）

#### 12.1.1 目录（LDAP）—— 唯一的真实来源

> ⚠ **2026-11-11 目录重建过**：LDAP 重新 seed 后 `entryUUID` 全变了（例如 alice 现在是
> `674f092a-71c7-1041-817c-7f0afac63416`）。本节里的 `3affaeaa-… / 3b008514-…` 等值属于 **11-10 那次运行**，
> 是当时的证据原文；**复验时按 token 现场读，不要抄常量**（§12.7）。2026-11-11 还修了 `realm-script.sh`
> 的 `find_id` 与 scope 挂载两个 bug，replay 现在能稳定产出 `aud/groups/tenant`。

模拟"我方 LDAP Server"（OpenLDAP 1.5.0，`identity/openldap`）。**租户身份只存在于目录里**：
租户标识是 `departmentNumber`，角色是 `ou=groups` 下的 `groupOfNames` 成员关系。
Keycloak 与 Kubernetes 都没有另外维护一份用户/组清单 —— 这是"隔离假象"能被测出来的前提。

| 用户 | 密码 | `departmentNumber` → `tenant` | 目录组（→ `groups`） | 用途 |
|---|---|---|---|---|
| `alice` | `poc3pass` | `tenant-a` | `tenant-a-users`, `os-user` | tenant-a 普通用户 |
| `tadmin` | `poc3pass` | `tenant-a` | `tenant-a-users`, `os-user`, `os-admin` | tenant-a 的 OpenShell 管理员 |
| `bob` | `poc3pass` | `tenant-b` | `tenant-b-users`, `os-user` | tenant-b 普通用户 |

条目示例（完整文件：[`poc/identity/ldif/tenant-users.ldif`](poc/identity/ldif/tenant-users.ldif)）：

```ldif
dn: uid=alice,ou=people,dc=aisanbox,dc=example
objectClass: inetOrgPerson
uid: alice
userPassword: poc3pass
departmentNumber: tenant-a        # ← tenant claim 的唯一来源

dn: cn=tenant-a-users,ou=groups,dc=aisanbox,dc=example
objectClass: groupOfNames
member: uid=alice,ou=people,dc=aisanbox,dc=example
member: uid=tadmin,ou=people,dc=aisanbox,dc=example

dn: cn=os-admin,ou=groups,dc=aisanbox,dc=example
objectClass: groupOfNames
member: uid=tadmin,ou=people,dc=aisanbox,dc=example
```

#### 12.1.2 Keycloak（唯一 OIDC 提供者）

**用户联邦**（`poc/identity/keycloak/30-ldap.json`，provider id `ldap-poc3`）：

| 配置项 | 值 | 为什么是这个值 |
|---|---|---|
| `connectionUrl` | `ldap://openldap.identity.svc.cluster.local:389` | 集群内直连，不经过 Keycloak 之外的任何身份层 |
| `usersDn` | `ou=people,dc=aisanbox,dc=example` | |
| `usernameLDAPAttribute` | `uid` | 登录名 |
| **`uuidLDAPAttribute`** | **`entryUUID`** | 联邦用户的稳定标识；`sub` 必须锚在这里，否则重导入后 subject 会变（§12.6-a） |
| `editMode` | `READ_ONLY` | Keycloak 不写回目录 |
| `importEnabled` | `true` | 惰性导入（也是 C-02 那个坑的来源） |
| `bindDn` / `bindCredential` | `cn=admin,dc=aisanbox,dc=example` / `pocadminpass` | 仅 POC 用 |

**claim 映射**（每个 mapper 一个文件，便于 diff 与复验）：

| Mapper（文件） | 类型 | 来源 | claim | 实测示例值 |
|---|---|---|---|---|
| `poc3-sub-from-ldap`（`24-claim-sub-from-ldap.json`） | `oidc-usermodel-attribute-mapper` | 用户属性 `LDAP_ID`（= entryUUID） | **`sub`** | alice `3affaeaa-70f6-1041-996a-41648389b70a`（11-10 那次运行的值；11-11 目录重建后已变，复验时从 token 现场读） |
| `poc3-tenant`（`21-claim-tenant.json`） | `oidc-usermodel-attribute-mapper` | 用户属性 `tenant`（由 LDAP mapper `tenant-attr` 从 `departmentNumber` 读入） | **`tenant`** | `tenant-a` |
| `poc3-roles`（`22-claim-roles.json`） | `oidc-usermodel-realm-role-mapper`，`multivalued=true` | realm roles（由 LDAP mapper `dir-roles` 从 `ou=groups` 载入，`mode=LDAP_ONLY`） | **`groups`**（扁平数组） | alice `["os-user","tenant-a-owners","tenant-a-users"]` |
| `poc3-audience`（`23-claim-audience.json`） | `oidc-audience-mapper` | `included.client.audience=openshell-cli` | `aud` | `openshell-cli` |

关键取舍：**`groups` 是顶层扁平数组**。Gateway 的 `rolesClaim` 可以写 `realm_access.roles`
（点分路径），但 kube-apiserver 的 `--oidc-groups-claim` **只能读顶层** —— 配成嵌套时
`kubectl auth whoami` 的 Groups 只剩 `system:authenticated`，**不报错、不告警**。所以两边统一读 `groups`。

**Client**：

| clientId | 类型 | 用途 | 关键属性 |
|---|---|---|---|
| `openshell-cli` | public | Keycloak 与 OpenShell CLI 共用 | `standardFlow` + `directAccessGrants`；`pkce.code.challenge.method=S256`；`oauth2.device.authorization.grant.enabled=true`（CLI 的 device flow **必需**，缺了登录直接失败） |
| `poc3-other-aud` | public | K-05 的**输入**：同一个人、`aud` 不对 | 无 default client scope（否则 realm 的 `poc3-claims` 会把 `aud` 改回 `openshell-cli`，这条用例就没有输入了） |

Issuer：`https://172.22.0.3:31443/realms/aisanbox`（Keycloak NodePort `31443`，自建 CA
`poc/identity/certs/issuer-ca.crt`）。**issuer 有三处消费者**（Keycloak `KC_HOSTNAME`、apiserver
`--oidc-issuer-url`、Gateway `server.oidc.issuer`），脚本从 ConfigMap `identity/kc-config` 读同一份，
不硬编码 —— 任一处不一致都会变成"某侧 token 验不过"的难查故障。

#### 12.1.3 kube-apiserver（正在生效的 flag，读自节点 manifest）

| flag | 值 | 说明 |
|---|---|---|
| `--oidc-issuer-url` | `https://172.22.0.3:31443/realms/aisanbox` | 与 Gateway 完全同一个 issuer |
| `--oidc-client-id` | `openshell-cli` | 同时由 `--oidc-required-claim=aud=openshell-cli` 强制校验 |
| `--oidc-ca-file` | `/etc/kubernetes/pki/oidc-issuer-ca.crt` | 自建 CA，进节点前先落盘（用进程替换会得到**空 CA**，报 `x509: certificate signed by unknown authority`） |
| `--oidc-username-claim` | `sub` | 用户名 = 目录 entryUUID；不做人类可读名 |
| `--oidc-username-prefix` | `-` | 不加前缀，保证与 Gateway 看到的 subject **逐字相同** |
| `--oidc-groups-claim` | `groups` | 顶层 claim，与 Gateway 的 `roles_claim` 相同 |
| `--oidc-signing-algs` | `RS256` | |
| `--oidc-required-claim` | `aud=openshell-cli` | v1.37 **没有** `--oidc-audience`；用 required-claim 达到同等效果（K-05 验证） |

#### 12.1.4 Kubernetes 侧授权（RBAC）

规则只写一次，按 namespace 各绑一次（[`poc/identity/50-rbac.yaml`](poc/identity/50-rbac.yaml)）：

```yaml
kind: ClusterRole
metadata: {name: poc3-tenant-member}
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
  # 故意不含 nodes / namespaces / secrets / 任何集群级资源
```

| RoleBinding | namespace | subject（Group） |
|---|---|---|
| `poc3-tenant-a-users` | `tenant-a-runtime` | `tenant-a-users` |
| `poc3-tenant-a-users` | `tenant-a-gateway` | `tenant-a-users` |
| `poc3-tenant-b-users` | `tenant-b-runtime` | `tenant-b-users` |
| `poc3-tenant-b-users` | `tenant-b-gateway` | `tenant-b-users` |
| `poc3-negative-control-b-in-a`（**正对照**，跑完即删） | `tenant-a-runtime` | `tenant-b-users` |

⚠️ 与 POC3.md 约束 1 的必要偏离：约束写"只能操作 namespace `tenant-a`"，但 Capsule 开了
`forceTenantPrefix`，一个租户拥有的是**一组带前缀的 ns**（`tenant-a-gateway` / `tenant-a-runtime`），
不存在名叫 `tenant-a` 的 namespace。所以按"每个 ns 一份 RoleBinding"授权；
用 ClusterRoleBinding 会**过度授权**（跨租户全部 ns 都通）。

#### 12.1.5 Capsule 租户与租户网络策略

```yaml
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata: {name: tenant-a}
spec:
  owners: [...]                 # 平台管理员
  forceTenantPrefix: true
  networkPolicies:
    items:
      - podSelector: {}
        policyTypes: ["Ingress"]
        ingress:
          - from:
              - namespaceSelector:
                  matchLabels: {capsule.clastix.io/tenant: tenant-a}   # 只允许同租户 ns 进来
```

两个租户（`poc/capsule2/tenants.yaml`，`tenant-a` / `tenant-b` 各一份对称配置）。生成的策略名
`capsule-tenant-<tenant>-0`，在每个租户 ns（`*-gateway` / `*-runtime`）各一份，ownerRef 指向 Tenant。

#### 12.1.6 OpenShell Gateway（一台，两个 Workspace）

[`poc/openshell3/gateway-oidc-values.yaml`](poc/openshell3/gateway-oidc-values.yaml)，关键项：

| values 键 | 值 | 说明 |
|---|---|---|
| `server.oidc.issuer` | `https://172.22.0.3:31443/realms/aisanbox` | 与 apiserver 相同 |
| `server.oidc.audience` | `openshell-cli` | 与 `--oidc-required-claim` 相同 |
| `server.oidc.rolesClaim` | `groups` | **与 apiserver 的 `--oidc-groups-claim` 是同一个 claim**（C-01） |
| `server.oidc.adminRole` | `os-admin` | 与目录 `cn=os-admin` 同名 |
| `server.oidc.userRole` | `os-user` | 与目录 `cn=os-user` 同名 |
| `server.oidc.scopesClaim` | `""` | POC 不用 Scope |
| `server.oidc.caConfigMapName` | `oidc-issuer-ca` | issuer 用自建 CA |
| `server.oidc.jwksTtl` | `600` | 重建 Keycloak 后旧 JWKS 不会长期生效 |
| `server.auth.allowUnauthenticatedUsers` | `false` | 开成 true 会让所有用例"成功"，隔离测试全部作废 |
| `server.tls.enableMtls` | `false` | 这台走 OIDC；POC2 的两台仍走 mTLS |
| `server.drivers.kubernetes.workspaceMode` | `shared` | 两个 Workspace 同处 `poc3-runtime` |

可见的 `gateway.toml` 实测片段：`roles_claim = "groups"`、`admin_role = "os-admin"`、
`user_role = "os-user"`、`audience = "openshell-cli"`、`issuer = "…/realms/aisanbox"`。
issuer 的 CA **不在 TOML 里**，而是进程级 `SSL_CERT_FILE` + `oidc-ca` 卷挂载。

Workspace 与成员（数据只有目录里的 entryUUID）：

| Workspace | 成员 | 角色 |
|---|---|---|
| `ws-tenant-a` | `tadmin`(=`3b001764-…`), `alice`(=`3affaeaa-…`) | admin(user os-admin) / user |
| `ws-tenant-b` | `tadmin`, `bob`(=`3b008514-…`) | admin / user |

---

### 12.2 二、Kubernetes 侧验证方案（用例表）

所有命令在 `root@192.168.5.190` 的 `/root/poc2` 下执行；`K="kubectl --context kind-agent-runtime-poc"`。
每个用户的 kubeconfig **只含 token、不含客户端证书** —— 复用默认 kubeconfig 时客户端证书会盖过 token
（`whoami` 显示 `kubernetes-admin`、`can-i` 全 yes），整张矩阵作废。

| 用例编号 | 操作者 | 目标系统 | 命令 | 预期结果 | 失败判定 | 实测 |
|---|---|---|---|---|---|---|
| K-01 | alice | Keycloak token | 解 JWT payload，读 `sub` | `sub` == 目录 `entryUUID` = `3affaeaa-70f6-1041-996a-41648389b70a` | `sub` 是 Keycloak 本地 id / 为空 / 与 entryUUID 不等 | ✅ PASS |
| K-02 | bob | Keycloak token | 同上 | `sub` = `3b008514-70f6-1041-996c-41648389b70a` | 同上 | ✅ PASS |
| K-03 | alice | Keycloak token | 读 `groups` | 同时含 `os-user`、`tenant-a-users`、`tenant-a-owners` | 缺任一，或靠 grep 前缀导致顺序误判 | ✅ PASS |
| K-03b | tadmin | Keycloak token | 读 `groups` | 含 `os-admin` | 不含 | ✅ PASS |
| K-03c | bob | Keycloak token | 读 `groups` | **不含**任何 `tenant-a-*` 组 | 出现 `tenant-a` 组 | ✅ PASS |
| K-04 | alice | Keycloak token | 读 `tenant` | `tenant-a` | 缺失或值为空 | ✅ PASS |
| K-05 | alice | kube-apiserver | 用 client `poc3-other-aud` 签发 token（同 issuer/同用户/同 claim，仅 `aud` 不同），`kubectl --kubeconfig=… auth whoami` | 被拒：`Unauthorized` / `doesn't have required claim` | 以该 token 仍能通过认证 | ✅ PASS |
| K-05b | alice | kube-apiserver | 正对照：`client_id=openshell-cli` 的 token 走同一命令 | 接受，`whoami` 显示 entryUUID | 连正对照都失败 ⇒ K-05 无意义 | ✅ PASS |
| K-10 | alice/bob | kube-apiserver | `kubectl auth can-i list pods -n <ns>` ×4 + `list nodes` | 见下表矩阵 | 任一越界为 yes；或正对照不是 yes | ✅ PASS |
| K-11 | alice/bob | kube-apiserver | `kubectl run … -n tenant-a-runtime` / `tenant-b-runtime`（真实创建） | 自己租户 `created`；对方租户 `Forbidden` | 用 `can-i` 代替真实写入，或 `-n` 写在 `--` 之后（请求发到 default） | ✅ PASS |
| K-12 | alice/bob | kube-apiserver | `auth can-i list nodes` | `no` | `yes` | ✅ PASS |
| X-01 | alice | Gatekeeper | RBAC **允许**的前提下 `kubectl run --overrides='{"spec":{"hostNetwork":true}}'` | 被 `[poc-tenant-pod-boundary]` 拒 | 被 RBAC 拒（那不是 Gatekeeper 的作用） | ✅ PASS |

**读权限矩阵（实测，`auth can-i list pods`）：**

| 操作者 | tenant-a-runtime | tenant-a-gateway | tenant-b-runtime | tenant-b-gateway | nodes |
|---|---|---|---|---|---|
| alice | yes | yes | **no** | **no** | no |
| bob | **no** | **no** | yes | yes | no |

正对照（把 `tenant-b-users` 绑进 `tenant-a-runtime` 后）：bob 对 `tenant-a-runtime` 变 **yes**，
对 `tenant-a-gateway` 仍是 **no** —— 证明矩阵里的 no 不是"claim 没读进来"，而是 RBAC 真的按组生效。

**真实写入（不是推测）：**

```
alice create pod tenant-a-runtime -> pod/poc3-alice-tenant-a-runtime created
alice create pod tenant-b-runtime -> Forbidden: User "3affaeaa-…" cannot create resource "pods"
bob   create pod tenant-a-runtime -> pod/poc3-bob-tenant-a-runtime created      ← 正对照绑定的结果
bob   create pod tenant-b-runtime -> pod/poc3-bob-tenant-b-runtime created
```

四条里三条是"自己租户通、对方租户被 RBAC 拒"，第四条（bob → tenant-a-runtime）是正对照。
另外要记住：**RBAC 允许不等于一定能建** —— 资源配额与准入会先拒（本轮早一轮就出现过
`Forbidden: exceeded quota: capsule-tenant-b`）；判断"隔离"时要区分这两种拒绝（X-01 同理）。

**租户网络隔离（修正 POC2 §5.4 的实测，用例 N-01..N-05）：**

| 用例编号 | 操作者 | 目标系统 | 命令 | 预期结果 | 失败判定 | 实测 |
|---|---|---|---|---|---|---|
| N-01 | 平台 | Capsule/Antrea | `kubectl get networkpolicy -A -l capsule.clastix.io/network-policy` | 两个租户 4 个 ns 各有一条 `capsule-tenant-<t>-0` | 0 条，或只覆盖部分 ns | ✅ PASS |
| N-02 | 集群内 Pod | Antrea | 在 tenant-a 起客户端 `wget` tenant-b 的服务端 Pod IP:8080 | `BLOCKED`（超时/拒绝） | `REACHED` | ✅ PASS |
| N-03 | 集群内 Pod | Antrea | 正对照：tenant-b 客户端 → tenant-b 服务端 | `REACHED` | 不通 ⇒ N-02 只是"网络本来就断" | ✅ PASS |
| N-04 | 租户 owner | Antrea | 租户自己在 tenant-a 建一条宽松 Ingress 策略后再测 N-02 | 变 `REACHED`（**可加性**，必须写进告警） | 无变化 ⇒ 说明之前看的不是策略 | ✅ PASS |
| N-05 | 租户 owner | Antrea | 撤掉自建策略 | 恢复 `BLOCKED` | 不恢复 | ✅ PASS |

⚠️ **可加性**是这条隔离的固有性质：NetworkPolicy 语义是并集，租户自己建一条就能把边界放宽。
要"画了就不能改"，得用 Capsule `spec.rules.enforce.policies` 或 Antrea ClusterNetworkPolicy
（见 §10 与 §12.6）。

---

### 12.3 三、OpenShell Gateway 侧验证方案（用例表）

连接方式一律是 **NodePort `https://172.22.0.3:31444`**（kind 的节点就是宿主机上的容器，
`172.22.0.3` 是 control-plane 容器 IP）。**不用 `kubectl port-forward`**：它会在多次调用之间被回收，
断掉后每个调用都返回 `connect error: transport error` —— 那看起来像"被拒绝"，实际是隧道没了。

| 用例编号 | 操作者 | 目标系统 | 命令 | 预期结果 | 失败判定 | 实测 |
|---|---|---|---|---|---|---|
| G-01 | alice/bob/tadmin | Gateway | `openshell -g p3-<user> whoami -o json`，读 `subject` | 与 apiserver 的 Username 逐字相同 | 任一不同 | ✅ PASS（三者全同） |
| G-02 | 未登录 profile | Gateway | 注册一台只填 endpoint、从不登录的 gateway，`workspace list` | `OIDC credentials are missing` | 返回数据 | ✅ PASS |
| G-03 | tadmin | Gateway | `workspace create --name ws-tenant-a` | `Created workspace` | 任何错误（注意上一轮是残留的 Terminating workspace） | ✅ PASS |
| G-04 | tadmin | Gateway | `workspace create --name ws-tenant-b` | `Created workspace` | 同上 | ✅ PASS |
| G-05 | alice | Gateway | `workspace create --name ws-by-alice` | `role 'os-admin' required` | 创建成功 | ✅ PASS |
| G-06 | tadmin | Gateway | `workspace member add --workspace ws-tenant-a --subject 3affaeaa-… --role user` | `added`（或 `already exists`） | 其他错误 | ✅ PASS |
| G-07 | tadmin | Gateway | 同上，`ws-tenant-b` + bob 的 subject | `added` | 同上 | ✅ PASS |
| G-08 | alice | Gateway | `workspace list` | 只有 `ws-tenant-a` | 出现 `ws-tenant-b` | ✅ PASS |
| G-09 | bob | Gateway | `workspace list` | 只有 `ws-tenant-b` | 出现 `ws-tenant-a` | ✅ PASS |
| G-10 | alice | Gateway | `--workspace ws-tenant-a sandbox create --name p3-a1 --from alpine:latest --detach --restart-policy never` | `created` | 失败或"已存在"（先清场） | ✅ PASS |
| G-10b | alice | Gateway | `--workspace ws-tenant-a sandbox list` | 含 `p3-a1` | 列表为空 | ✅ PASS |
| G-11 | alice | Gateway | 同上但 `--workspace ws-tenant-b`，`--name p3-a2` | `not a member of workspace 'ws-tenant-b'` | 创建成功 | ✅ PASS |
| G-12 | tadmin 加成员后 alice | Gateway | `workspace member add ws-tenant-b alice`，再 `workspace list` | alice 现在看到两个 Workspace | 仍只看一个 | ✅ PASS |
| G-12b | alice（已是成员） | Gateway | `--workspace ws-tenant-b sandbox create --name p3-a3` | `created` —— 边界随成员资格移动的**正对照** | 仍被拒 ⇒ G-11 的"被拒"可能只是永远拒 | ✅ PASS |
| G-13 | tadmin 移出后 alice | Gateway | `workspace member remove ws-tenant-b alice`，再 `workspace list` | 只剩 `ws-tenant-a` | 仍能看/建 | ✅ PASS |

拒绝原文（来自本轮运行，`§五 失败可观测` 一节也会打印）：

```
Error: × code: 'The caller does not have permission to execute the specified operation',
       message: "role 'os-admin' required"
Error: × code: 'The caller does not have permission to execute the specified operation',
       message: "not a member of workspace 'ws-tenant-b'; ask a platform admin to run:
                 openshell workspace member add --workspace 'ws-tenant-b' --subject '3affaeaa-…' --role user"
```

⚠️ 阅读注意：CLI 0.1.7 把 `WARN openshell_sdk::transport: TLS certificate verification is disabled`
打到 **stdout**，`-o json` 时会污染解析（`PARSE-FAIL: Extra data`）；而真正的 `Error: ×` 块在 **stderr**，
并且**不保证**进入命令替换管道。断言必须读"落到文件里的 stdout+stderr"，否则会把正确的拒绝判成 FAIL。

---

### 12.4 四、跨系统一致性验证（用例表）

| 用例编号 | 操作者 | 目标系统 | 命令 | 预期结果 | 失败判定 | 实测 |
|---|---|---|---|---|---|---|
| C-01 | 平台 | apiserver + Gateway | `grep -- --oidc-groups-claim=groups /tmp/p3/flags.txt`；`grep 'roles_claim = "groups"'` 跑着的 gateway.toml | 两侧读**同一个** claim 名 | 两侧各用一个 claim（一致性就成了配置巧合） | ✅ PASS |
| C-02 | 平台（改目录） | Keycloak token | 往 `cn=tenant-b-users` 加 `uid=alice` → 删 alice 的本地副本（见下）→ 重新签发 token | `groups` 立刻含 `tenant-b-users` | 不含；或复用旧 token 得到 `Unauthorized`（那是过期，不是没生效） | ✅ PASS |
| C-03 | alice | kube-apiserver | 用新 token 建 kubeconfig，`auth can-i list pods -n tenant-b-runtime` | `yes`（只改目录、不改任何 RBAC） | `no` | ✅ PASS |
| C-04 | alice | Gateway | 重新登录后 `workspace list` | **仍只有 `ws-tenant-a`** —— Workspace 成员资格**不随**目录组走 | 自动出现 `ws-tenant-b` | ✅ PASS（与预期一致，是限制不是缺陷） |

C-02/C-03 的操作步骤（也是生产缺口，见 §12.6-h）：

```bash
# 1) 改目录（必须带 -i，否则 stdin 被丢掉、ldif 是 0 字节而命令仍返回 0）
kubectl -n identity exec -i deployment/openldap -- sh -c 'cat > /tmp/chg.ldif' <<'EOF'
dn: cn=tenant-b-users,ou=groups,dc=aisanbox,dc=example
changetype: modify
add: member
member: uid=alice,ou=people,dc=aisanbox,dc=example
EOF
kubectl -n identity exec deployment/openldap -- \
  ldapmodify -x -H ldap://openldap.identity.svc.cluster.local:389 \
             -D cn=admin,dc=aisanbox,dc=example -w pocadminpass -f /tmp/chg.ldif

# 2) 丢掉 alice 的本地联邦副本，让下一次认证按目录重新导入
KC=$(kubectl -n identity get pods -o name | grep keycloak- | grep -v realm | head -1 | sed 's|pod/||')
kubectl -n identity exec -i "$KC" -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://keycloak-admin.identity.svc.cluster.local:8080 --realm master \
  --user pocadmin --password pocadminpass
UID_=$(kubectl -n identity exec -i "$KC" -- /opt/keycloak/bin/kcadm.sh get users -r aisanbox -q search=alice \
       | grep -m1 '"id"' | sed 's/.*"id" : "//;s/".*//')
kubectl -n identity exec -i "$KC" -- /opt/keycloak/bin/kcadm.sh delete "users/$UID_" -r aisanbox
```

**为什么"只改目录"不够**（实测，多轮）：Keycloak 26.4 的联邦用户是"惰性导入 + 本地副本"，
副本存在时改目录**不会**刷新 token；重跑整个 realm Job 也不会（它只删除 `federationLink`
与当前 provider 不一致的副本）。26.4 可用的同步入口只有：
`kcadm create user-storage/<id>/sync` → `Missing action`；REST `POST …/sync?action=import|changedUsersSync`
→ HTTP 400 `{"error":"Unknown action: …"}`；`serverinfo` 里该 provider 只有 `importEnabled` /
`syncRegistrations` 两项，**没有** `fullSyncPeriod`/`changedSyncPeriod`。

---

### 12.5 五、POC 验收标准

| 验收项 | 判据（必须全部为"是"） | 结论 |
|---|---|---|
| **身份链路** | 三个用户的 `sub` == 目录 entryUUID；`groups` 全部由目录组映射；`tenant` 来自目录属性；Keycloak/K8s 无手工用户与手写角色绑定 | ✅ 通过 |
| **K8s 隔离** | 每租户用户对**自己租户的每个 ns** `can-i` = yes 且**真实创建成功**；对对方租户每个 ns = no 且**真实创建被拒**；集群级资源 = no | ✅ 通过 |
| **OpenShell 隔离** | 同租户 Workspace 内可建/可列；对方 Workspace 建/列均被拒，拒绝原文含 `not_workspace_member`；`os-admin` 独占 Workspace 创建 | ✅ 通过 |
| **一致性** | 两侧**同一个** `groups` claim、**同一个** `sub`；只改目录后 K8s 侧授权跟着变 | ⚠️ 有条件通过（需删本地副本；Gateway 成员不跟目录组，见 §12.6-e/h） |
| **失败可观测** | 每次拒绝都有可 grep 的记录（Gateway OCSF JSONL/日志 + apiserver 审计），且能区分"配置写错"与"策略未生效" | ✅ 通过 |
| **租户网络隔离** | Capsule 为两个租户下发策略；跨租户 `BLOCKED`；同租户正对照 `REACHED`；可加性有记录 | ✅ 通过（修正 POC2 §5.4） |

汇总（本轮脚本）：`PASS=49 FAIL=0`（上一轮 `PASS=46 FAIL=3` 的三个 FAIL 全部是
`ws-tenant-a` 卡在 `Terminating` 造成的残留，见 §12.7 第 1 条）。

---

### 12.6 架构约束里的漏洞与修正建议

POC3.md 的四条约束里，有六处会导致"隔离无法验证"或"看起来通过实际没隔离"的漏洞。
前五处本轮已经用配置绕开，第六处是产品边界，必须由平台补控制器。

| # | 约束原文/隐含假设 | 实测到的漏洞 | 修正（本轮已做 / 生产要做） |
|---|---|---|---|
| a | Keycloak 联邦用户的 `sub` 可以直接当身份 | 默认 `sub` 是 Keycloak 的本地 user id，**每次重导入都会变**；用它当 RBAC 主体名，目录一同步授权就全断 | 已做：联邦 `uuidLDAPAttribute=entryUUID` + mapper `24-claim-sub-from-ldap` 把 `sub` 映射成 `LDAP_ID`（entryUUID）。生产必须保持这条，且把它写进开通检查 |
| b | 两侧各自配置 claim 即可 | kube-apiserver v1.37 的 `--oidc-groups-claim` **只能读顶层** claim；OpenShell 的 `rolesClaim` 支持点分路径。各配各的会让"一致性"变成巧合，且 apiserver 侧**静默失效**（Groups 只剩 `system:authenticated`，不报错） | 已做：两侧统一读顶层扁平 `groups`。**禁止**改成 `realm_access.roles` |
| c | 用 `--oidc-client-id` 就够校验 audience | v1.37 **没有** `--oidc-audience`；只配 client-id 时，同 issuer 下其他 client 签出的 token 也能通过（本 POC 第二台 client `poc3-other-aud` 就是反例） | 已做：`--oidc-required-claim=aud=openshell-cli`。注意 required-claim 是"所有 token 必须具备"，换 audience 时要同时改三处（Keycloak mapper / apiserver / Gateway） |
| d | "tenant-a 用户只能操作 namespace `tenant-a`" | 这个 ns **不存在**：`forceTenantPrefix` 下一个租户是一组带前缀的 ns（`tenant-a-gateway`、`tenant-a-runtime`、未来的 `tenant-a-*`）。按单一 ns 授权会漏，按 ClusterRoleBinding 会过度授权 | 已做：每个 ns 一份 RoleBinding。生产要在开通流程里**枚举租户全部 ns** 生成绑定（ns 是动态的，必须有控制器跟随） |
| e | Workspace 成员资格会跟随目录组 | 不会。Workspace 成员是按 subject 显式写入的资源成员表；只改 LDAP 组，Gateway 侧看不到变化（C-04 实测） | 生产要做：一个"目录组 → Workspace 成员"的同步控制器（或在 Workspace 创建时按组展开成员）。POC 里由 `workspace member add/remove` 显式维护 |
| f | NetworkPolicy 画了边界就固定 | NetworkPolicy 语义是**并集**，租户自己建一条 Ingress 策略就能把边界放宽（N-04 实测 `BLOCKED → REACHED`） | 已做：接受并写进告警。生产要用 Capsule `spec.rules.enforce.policies`（限制租户可创建的策略范围）或 Antrea ClusterNetworkPolicy（平台独占） |
| g | OIDC device flow 是 CLI 的事，与权限无关 | 它**是身份链的一部分**：client 缺 `oauth2.device.authorization.grant.enabled=true` 或 PKCE S256，CLI 根本登不上，后续用例全部无法执行（而且现象是"登录失败"，不是"权限不足"） | 已做：`10-client.json` 两个属性都设。生产上放进 client 注册模板 |
| h | 改目录 → 下一次请求就生效 | Keycloak 26.4 联邦用户有本地副本；**没有可用同步 API**（见 §12.4）。改目录后 token 不变 | POC 用"删本地副本触发重导入"。生产要选：① 定期 full sync 的同步器；② 把 claim 来源改成逐请求读目录（自定义 User Storage SPI）；③ 接受 TTL 级延迟并把它写进 SLA |

---

### 12.7 手工复验（NodePort，不用 port-forward）

```bash
ssh root@192.168.5.190
cd /root/poc2

# 一次跑完整张矩阵（末尾必须 PASS=49 FAIL=0；FAIL 先看是不是清场残留）
bash phases/14-identity-federation.sh 2>&1 | tee /tmp/p14f.log

# 单看某一段
sed -n '/1. 身份与声明/,/2. Kubernetes/p' /tmp/p14f.log
sed -n '/3. OpenShell/,/4. 跨系统/p'       /tmp/p14f.log

# 手工拿 token 看 claim（alice / tenant-a）
CA=/tmp/issuer-ca.crt; cp identity/certs/issuer-ca.crt $CA 2>/dev/null
curl -sS --cacert $CA -X POST https://172.22.0.3:31443/realms/aisanbox/protocol/openid-connect/token \
  -d grant_type=password -d client_id=openshell-cli -d username=alice -d password=poc3pass \
  | python3 -c 'import sys,json,base64
t=json.load(sys.stdin)["access_token"]; p=t.split(".")[1]
print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"===")),indent=2,ensure_ascii=False))'

# K8s 侧（只用 token，不能带客户端证书）
K="kubectl --context kind-agent-runtime-poc"
# 从上面的 token 生成 kubeconfig 后：
kubectl --kubeconfig=/tmp/p3/kc-alice.yaml auth whoami
kubectl --kubeconfig=/tmp/p3/kc-alice.yaml auth can-i list pods -n tenant-b-runtime   # 必须是 no

# OpenShell 侧（CLI 的 device flow 已在脚本里做过一次，profile 留在 ~/.openshell）
CLI=vendor/openshell-cli-0.1.7/openshell
OPENSHELL_GATEWAY_INSECURE=true $CLI -g p3-alice whoami -o json
OPENSHELL_GATEWAY_INSECURE=true $CLI -g p3-alice workspace list
```

**复验时最容易误判的 5 处（都在本轮实际踩过）：**

1. `workspace` 删除是**异步**的，且"还有 sandbox"时删除会停在 `Terminating` —— 名字仍被占用，
   下一轮 `create` 得到 `workspace already exists`、`member add` 得到 `workspace … is being deleted`。
   **先 `sandbox delete --all`，再删 workspace，并等它从 `list` 里消失**（§12.7 第 1 条）。
2. 复用默认 kubeconfig ⇒ 客户端证书盖过 token，`whoami` 显示 `kubernetes-admin`。必须单独建 token-only kubeconfig。
3. 复用旧 token 测 C-02/C-03 ⇒ `Unauthorized`（过期），会被误读成"目录改动没生效"。每次改目录后**重新签发**。
4. `kubectl exec` 不带 `-i` ⇒ stdin 丢弃、文件 0 字节、退出码 0。改 LDAP 时务必读回目录确认。
5. CLI 的 WARN 在 stdout、Error 在 stderr，且不保证进管道 —— 断言要读落到文件的完整输出。

---

## 13. POC4（第四轮，2026-11-11）：Gateway 改 Deployment + PostgreSQL，多 Gateway 共用一库

> 脚本：[`poc/openshell4/80-gateway-pg.sh`](poc/openshell4/80-gateway-pg.sh)（装 PostgreSQL + 两个 Helm release）、
> [`81-shared-db-verify.sh`](poc/openshell4/81-shared-db-verify.sh)（验证矩阵）、
> [`82-cli-login.sh`](poc/openshell4/82-cli-login.sh)（device flow 登录）。
> 远端原始输出 `/tmp/p4-81f.log`，末尾 `PASS=33 FAIL=0`。
> 身份链沿用 POC3（Keycloak NodePort 31443），本轮只改 Gateway 的存储形态。

### 13.0 一句话结论

**能。** `workload.kind: deployment` + `server.externalDbSecret` 让 Gateway 把控制面状态放进外置
PostgreSQL；**两个独立 Helm release（p4a / p4b）共用同一套 PG 后，确实读到同一份状态**：
A 上建的 workspace / member / provider，B 立刻可读；删掉 p4a 的全部 Pod 状态不丢；非成员 bob
在 B 上仍被拒。同一 release 扩到 2 副本也成立：杀掉 1 个副本，连续 10 次调用全部成功，副本自动补回。

但有三个必须一起满足的前提，否则"共库"只是连上了同一个端口：

| 前提 | 为什么 | 本轮怎么验的 |
|---|---|---|
| 两个 release 共用同一个 **KEK Secret** | 凭据在库里是 AES-256-GCM 密文；KEK 默认每个 release 各生成一个 | K-04/K-05 断言两台的 Secret 引用与值逐字节相同；**解密失败路径未测**（§13.3） |
| 两个 release 的 **OIDC 配置一致** | 身份来自 token；issuer / audience / role 映射不一致会让同一用户在两台权限不同 | 两个 release 用同一份 values 渲染（§13.1） |
| 共享 **runtime namespace**（本轮 `poc4-runtime`） | Sandbox 是 Kubernetes 对象，不是 PG 行；两台 Gateway 的 Kubernetes driver 都从这个 ns 列 Sandbox | `kubectl -n poc4-runtime get sandboxes`；PG 的 `objects` 里**没有** sandbox 行 |

⚠ 第 3 条最容易被误读成"PG 共享了 sandbox 状态"。**不是**：本轮 sandbox 跨 Gateway 可见，
来自共享 runtime ns + Kubernetes driver；PG 共享的是 workspace / member / provider / provider profile
这些**控制面对象**。两件事必须分开取证。

| 验收面 | 结论 | 证据 |
|---|---|---|
| 形态 | ✅ Deployment，不是 StatefulSet | D-01/D-02；`kubectl get deploy,sts` 只有 deploy |
| 存储入口 | ✅ `OPENSHELL_DB_URL` 来自 Secret，启动参数里没有 `--db-url` | D-03..D-06 |
| PG schema | ✅ Gateway 启动时自动建表 | `_sqlx_migrations` 7 条；p4b 日志 `relation "_sqlx_migrations" already exists, skipping` |
| 控制面共享 | ✅ A 写 B 读 | S-02/S-03、K-01/K-02/K-03 |
| 重启不丢 | ✅ 删 p4a 全部 Pod 后 B 仍可读，p4a 重建后自己也能读回 | S-08..S-10 |
| 权限仍生效 | ✅ 非成员 bob 在 B 上被拒 | S-06/S-07 |
| chart 硬约束 | ✅ 负向对照有精确报错 | S-11..S-14 |
| 同 release 多副本 | ✅ 2 副本，杀 1 个后 10/10 调用成功并自愈 | S-15..S-18 |
| 凭据共库 | ✅ PG 里有该 provider 行，两台读到同一条 id；KEK 配置一致 | K-01..K-05（含 K-02a） |
| 凭据解密失败 | ⚠️ **未测**（不伪造） | §13.3 |

---

### 13.1 配置文档

#### 13.1.1 chart 0.1.7 的硬约束：两个值必须成对出现

这不是"两个独立开关"。`workload.kind` 和 `server.externalDbSecret` 有代码级耦合：

| 配置 | 结果（helm 原文） | 用例 |
|---|---|---|
| `workload.kind=statefulset` + `replicaCount=2`，无 externalDbSecret | `Error: execution error at (helm-chart/templates/supervisor.yaml:1:4): replicaCount > 1 requires server.externalDbSecret; multiple gateway replicas cannot share the default per-pod SQLite database.` | S-11 |
| `workload.kind=deployment`，无 externalDbSecret | `Error: execution error at (helm-chart/templates/supervisor.yaml:1:4): workload.kind=deployment requires server.externalDbSecret; use workload.kind=statefulset for the default SQLite database.` | S-12 |
| `workload.kind=deployment` + `server.externalDbSecret=p4-db-uri` | 渲染出 `OPENSHELL_DB_URL`（来自 Secret key `uri`），且**不渲染** `--db-url` | S-13/S-14 |

另外，chart 0.1.7 **不再自带 PostgreSQL**：`postgres.enabled` 已删除，平台必须自备一台。

#### 13.1.2 PostgreSQL（本轮最小形态）

[`poc/openshell4/postgres.yaml`](poc/openshell4/postgres.yaml)：`poc4-db` namespace、单副本
`postgres:16-alpine`、2Gi PVC（`subPath: pgdata`）、`pg_isready` 探针、Service `postgres:5432`。
密码在 `postgres-credentials` Secret。**这是 POC 形态，不是生产形态**（无 HA / 备份 / 连接池 / TLS）。

连接串放进两个 Gateway namespace 各自的 Secret（Secret 不能跨 ns 引用，所以是两个同名同值的
`p4-db-uri`，key `uri`）：

```
postgresql://openshell:poc4pass@postgres.poc4-db.svc.cluster.local:5432/openshell
```

#### 13.1.3 两个 release 的差异只有名字/ns/端口

| 项 | p4a | p4b |
|---|---|---|
| Helm release | `p4a` | `p4b` |
| namespace | `poc4-gw-a` | `poc4-gw-b` |
| DB Secret | `p4-db-uri`（同值） | `p4-db-uri`（同值） |
| KEK Secret | `p4-credential-kek` | 同值复制一份 |
| runtime namespace | `poc4-runtime` | 同一个 |
| workspace chart | `os-ws-p4a`（SA `p4a-openshell` / `p4a-openshell-sandbox`） | `os-ws-p4b`（SA `p4b-...`） |
| NodePort | 31445 | 31446 |
| OIDC | 同 issuer / audience / rolesClaim | 同 |

workspace chart 装两遍是为了给每台 Gateway 各自的 ServiceAccount 与 NetworkPolicy；
`server.sandboxNamespace` 都指向 `poc4-runtime`（shared 模式）。Gateway 生成的
`openshell-client-tls` 只需复制一份到共享 runtime ns（POC2 起的老坑：缺了 supervisor 卡
`ContainerCreating`）。

#### 13.1.4 本轮 values 的关键项

```yaml
workload:
  kind: deployment

server:
  externalDbSecret: "p4-db-uri"      # Secret key: uri（与 deployment 成对，见 13.1.1）
  credentialStorage:
    existingSecret: "p4-credential-kek"   # 两台必须同值；默认是每 release 各生成一个
  oidc: { issuer: "__ISSUER__", audience: "openshell-cli", rolesClaim: "groups",
          adminRole: "os-admin", userRole: "os-user", caConfigMapName: "oidc-ca" }
  drivers:
    kubernetes:
      workspaceMode: shared
      allowDriverConfig: true
```

完整文件：[`poc/openshell4/gateway-pg-values.yaml`](poc/openshell4/gateway-pg-values.yaml)。

---

### 13.2 实测结果（`PASS=33 FAIL=0`）

**本轮先从空库重建再验证**：删掉 PG 的 Deployment/PVC/Service 后重建 —— `information_schema` 里
**0 张表**、数据库 7.5 MB（空模板）；再启动两台 gateway，schema 完全由 gateway 启动时自动建出
（7 条 `_sqlx_migrations`），此时 `objects` 里只有默认 workspace、2 条 `gateway_member`、1 条
`reconciler_lease`。在这个空库上重跑整套矩阵，结果仍是 `PASS=33 FAIL=0`：状态完全由 PostgreSQL
提供，不依赖上一轮的残留。

**形态与存储（D）**：两个 release 都是 Deployment；`OPENSHELL_DB_URL` 都指向 `p4-db-uri`；
容器 args 只有 `--config /etc/openshell/gateway.toml`（没有 `--db-url`）。PG 里只有两张表：

```
_sqlx_migrations    7 行
objects             workspace / workspace_member / gateway_member /
                    provider / provider_profile / credential.gateway-encrypted /
                    reconciler_lease（序列化 payload，按 object_type + workspace 存）
```

p4a 先启动并建表；p4b 启动日志出现
`sqlx::postgres::notice: relation "_sqlx_migrations" already exists, skipping` —— 两个 release
共用同一份 schema，不是各建各的。两台的启动日志都打印
`sizing Postgres connection pools max_connections=10 lock_max_connections=4`；但池是**按需打开**的：
3 个 gateway Pod（p4a 两副本 + p4b）同时在线时，`pg_stat_activity` 里总共只有 11–14 条会话
（本轮 D-07 实测 11 条），不是 3×14 的上限。

**控制面共享（S）**：p4a 创建 workspace → p4b `workspace list` 立即可见；把 alice 加为成员 →
p4b-alice 可见；p4a 创建的 sandbox 在 p4b 的 `sandbox list` 里可见。在 p4b 上建同名 workspace
返回 `already exists`；非成员 bob 在 p4b 上既看不到、也进不去（拒绝原文为
`not a member of workspace '...'`）。

**重启不丢（S-08..S-10）**：删掉 p4a 的**全部** Pod 后，p4b 仍能读到 workspace 与 sandbox；
p4a 重建后自己也能读回。状态不在 Pod 本地 SQLite 里。

**chart 负向对照（S-11..S-14）**：见 §13.1.1 的三条报错原文；正向渲染包含
`OPENSHELL_DB_URL`、不包含 `--db-url`。

**同 release 多副本（S-15..S-18）**：`replicaCount` 1 → 2 成功，两副本 Running；杀掉其中
1 个后连续 10 次 `whoami` 全部成功（另一副本在服务），副本数自动补回 2。

**凭据（K）**：导入一个最小自定义 provider profile（`id: poc4-kek`，credential `API_KEY`），
在 A 上 `provider create` 返回 `✓ Created provider p4-kek`；接着直接查 PG：`objects` 表里存在
该 workspace 下 `object_type='provider'`、`name='p4-kek'` 的一行（K-02），说明凭据密文确实落在
PostgreSQL 而不是 A 的本地。B 上 `provider get` 返回**同一条 id**——本轮 A/B 实测都是
`b9b12042-8ca8-4bcb-9868-419e17164313`（K-03；每次重跑会新建 workspace，id 随之变化，
要比的是「两台相同」而不是某个固定值），`Credential keys: API_KEY` 也一致。两台的
`OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY` 都引用 `p4-credential-kek`，
两个 ns 里的值逐字节相同。

---

### 13.3 多个 Gateway 共用一套 PostgreSQL：能到什么程度

分三层说，结论不一样：

1. **同一个 release 的多个副本：支持，且实测可用。**
   chart 明确要求 `replicaCount>1` 时必须给 `externalDbSecret`（否则拒绝，见 S-11）；本轮用
   Deployment + externalDbSecret 跑 2 副本、杀 1 个后 10/10 成功。适合做 Gateway 的 HA。

2. **两个独立 release 共用一个库：技术上成立，但不是 chart 的契约。**
   本轮 p4a / p4b 是两个独立 Helm release、两个 namespace、两个 NodePort，连同一个库；
   控制面对象互通。库里有且只有一条 `reconciler_lease`；本轮结束时一台 gateway 打印过
   `acquired reconciler lease` 并一直持有，另一台只打印 `reconciler lease coordinator started`
   —— 说明多 Gateway 的 reconciler 用库里的租约做互斥（谁抢到取决于启动顺序：重建 PG 后
   第一次启动是 p4a 抢到，重启一轮后换成了 p4b）。
   ⚠ 证据边界：S-08 删掉的旧 Pod 日志随 Pod 消失，回看不到更早的竞争；是否完全避免重复
   reconcile 也没有做压力验证。但 chart 没有"多 release 共库"的文档或
   校验，以下都要自己保证：
   - **KEK 必须共用**，否则 A 写的凭据 B 解不开（设计约束，见下）。
   - **OIDC 配置必须一致**（issuer/audience/rolesClaim/角色名），否则同一用户在两台权限不同。
   - **版本必须一致**（同一套 sqlx migration）；滚动升级时建议先升一台、确认 migration 成功再升另一台。
   - **容量**：每个 Gateway 进程的池容量是 10 条普通连接 + 4 条锁连接（启动日志），多台共库要按
     `PostgreSQL max_connections` 预留上限；实测池按需打开——本轮 3 个 Pod 在线时实测 11–14 条会话（D-07 为 11）。
     注意这是**本轮观察值**，不是上限，压力下会向 10+4/进程 增长。
   - **并发写**：`objects` 表有 `resource_version` 字段；它是否被用作乐观锁、两个 Gateway 同时改
     同一个对象会返回什么，本轮**没有压测**，不要把它当强一致协调器用。

3. **KEK 解密失败：本轮没有测出来，不记 PASS。**
   chart 把凭据以 AES-256-GCM 加密存库，KEK 默认是 per-release Secret —— 所以"共库必须共 KEK"
   是**设计约束**。但实测里：把 p4b 的 KEK 换成另一个值并重启后，`provider get` 仍然成功
   （它只读元数据，不触发解密）；用最小自定义 profile 建 sandbox 也没构造出"解密失败"的
   可观测面。因此本报告只把 K-04/K-05 记作**配置一致**，不声称"测到了解密失败"。

**一句话**：把多个 Gateway 指向同一个 PG，状态确实共享；但它是"**共享数据库的多个控制面**"，
不是"一个无状态服务随便扩容"。KEK、OIDC、版本、连接数四件事必须一起管。

---

### 13.4 从 SQLite 迁到 PostgreSQL 的真实成本

- **没有迁移工具**：CLI 没有 `migrate` / `export` 子命令（`openshell --help` 只有 sandbox /
  provider / profile / gateway 等）；Gateway 启动时用 sqlx 自动建 schema，但**不会**把旧
  SQLite 里的对象搬过来。
- **SQLite 数据是 per-Pod 的**：默认 StatefulSet 每个 Pod 一个库，换 Deployment 后旧库不再被挂载。
  现有 workspace / member / provider 需要**重新创建**；sandbox 本身是运行态对象，重建即可。
- **KEK 换了就解不开旧凭据**：如果沿用旧 KEK，把它做成 Secret 挂给新 Deployment；换新 KEK
  等于所有已存凭据作废，需要重新录入。
- **可接受的迁移姿势**：先起 PG 与新 Gateway（新 NodePort），用 CLI 把 workspace/member/provider
  重新声明一遍，验证后再切流量；不要期望原地升级自动搬数据。

---

### 13.5 手工复验（NodePort，不用 port-forward）

```bash
ssh root@192.168.5.190
cd /root/poc2

# 0) 前置：POC3 身份链已就绪（Keycloak 31443）
kubectl --context kind-agent-runtime-poc -n identity get cm kc-config

# 1) 装 PG + p4a/p4b（可重复执行）
bash openshell4/80-gateway-pg.sh

# 2) CLI device-flow 登录（每个 profile 一次）
bash openshell4/82-cli-login.sh

# 3) 跑矩阵；末尾必须是 PASS=33 FAIL=0
bash openshell4/81-shared-db-verify.sh 2>&1 | tee /tmp/p4-81f.log

# 3b) 想从空库重来（⚠ 清空全部 workspace/provider/凭据，不可恢复）
#     顺序：停 gateway → 删 PG → 建空库 → 清 runtime ns 里的孤儿 sandbox → 再启 gateway
CFG="--context kind-agent-runtime-poc"
kubectl $CFG -n poc4-gw-a scale deploy/p4a-openshell --replicas=0
kubectl $CFG -n poc4-gw-b scale deploy/p4b-openshell --replicas=0
kubectl $CFG delete -f openshell4/postgres.yaml
kubectl $CFG apply -f openshell4/postgres.yaml
kubectl $CFG -n poc4-db rollout status deploy/postgres --timeout=180s
kubectl $CFG -n poc4-runtime delete sandboxes.agents.x-k8s.io --all
kubectl $CFG -n poc4-gw-a scale deploy/p4a-openshell --replicas=1
kubectl $CFG -n poc4-gw-b scale deploy/p4b-openshell --replicas=1
#     启动后应看到 gateway 自动建表：psql -c 'select count(*) from _sqlx_migrations' → 7

# 单看 PG 里到底存了什么
P=$(kubectl --context kind-agent-runtime-poc -n poc4-db get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl --context kind-agent-runtime-poc -n poc4-db exec $P -- \
  psql -U openshell -d openshell -c "select object_type,count(*) from objects group by 1 order by 1"

# 看两个 release 的 DB 入口（应该都是 p4-db-uri，且 args 没有 --db-url）
kubectl --context kind-agent-runtime-poc -n poc4-gw-a get deploy p4a-openshell \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}{"\n"}'
kubectl --context kind-agent-runtime-poc -n poc4-gw-b get deploy p4b-openshell \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}{"\n"}'
```

**复验时最容易误判的 5 处（本轮都踩过）：**

1. **workspace 删除会被 provider/profile 卡住**。只删 sandbox 不够：workspace 里还有
   provider 或 provider profile 时，`workspace delete` 返回
   `still contains resources: provider profile`，workspace 留在 `Terminating`；下一轮
   `workspace create` 得到 `already exists`，后续 `profile import` / `sandbox create` 全部
   `FAILED_PRECONDITION`。清场顺序必须是 **sandbox → provider → profile → workspace**。
   本脚本每轮用新的 workspace 名，避免把上一轮的状态当成本轮成功。
2. **`sandbox` 不在 PG 里**。跨 Gateway 看到 sandbox 是共享 runtime ns 的功劳，不是数据库
   共享的证据；不要把 D/S 的结论写成"PG 存了 sandbox"。
3. **CLI 的 WARN 与结果在不同行**。把输出 `tr '\n' ' '` 再 `grep -v WARN` 会把结果一起删掉，
   证据行变成空；要按行过滤，或直接断言落到文件的完整输出。
4. **`profile import` 是 workspace 级的**。在 A 的 workspace 里导入的 profile，不会自动出现在
   别的 workspace；`provider create` 报 `provider profile '...' not found` 时先看导入到哪了。
5. **KEK 的 Secret 值不能再 base64 一次**。`jsonpath` 读出来已经是 base64；用
   `--from-literal` 重建会把 base64 文本再编码，Gateway 报
   `key_encryption_key_env value must decode to exactly 32 bytes`。要么 `base64 -d`，要么
   直接 patch `data` 字段。

---

### 13.6 生产部署方案（设计与渲染完成，未在 POC 集群实跑）

POC4 回答的是"能不能"；真正上生产用 [`poc/openshell4/production/`](poc/openshell4/production/)：

| 文件 | 作用 |
|---|---|
| `README.md` | 生产 runbook：容量公式、升级/迁移流程、备份恢复、安全与验收清单 |
| `values-gateway-prod.yaml` | 3 副本 Deployment、外置 PG、边缘 TLS 终止 + OIDC、资源/反亲和 |
| `postgres-cnpg.yaml` | CloudNativePG 3 实例 + PgBouncer(session) + S3 备份（托管 PG 见 runbook §3.1） |
| `deploy-prod.sh` | 幂等部署脚本（前置检查 → workspace 资源 → gateway → PDB/监控 → 断言） |
| `secrets-external-secrets.yaml` | DB URI / KEK 用 External Secrets 从 Vault/KMS 注入 |
| `networkpolicy.yaml`、`pdb-gateway.yaml`、`certificate-edge-tls.yaml` | 网络隔离、可用性、边缘证书 |
| `servicemonitor.yaml`、`prometheusrule.yaml` | 抓取与告警（指标名取自 POC4 实抓） |

与 POC4 的关键差别：

- **单 release 3 副本**，不是一个库上挂两个独立 release（后者不是 chart 契约，见 §13.3）。
- 外置 PG 要求 **TLS + 多 AZ + PITR**：托管 PG（首选）或 CNPG 3 实例；
  PgBouncer 必须 **session** 模式（sqlx 用服务端 prepared statements）。
- 边缘由 Gateway API 终止 TLS，gateway 在集群内明文 + OIDC（chart 明确支持），
  不再向每个 CLI 分发 mTLS 客户端证书。
- KEK 由 Vault/KMS 注入且**终身不换**；PG 备份里只有密文凭据，恢复演练必须连 KEK 一起恢复。
- 升级顺序：**缩到 1 副本 → 升镜像/values → 验证 `_sqlx_migrations` → 扩回 3**，避免多副本并发 DDL。

**验证边界**：`values-gateway-prod.yaml` 已用 `helm template` 渲染通过
（Deployment/3 副本、`OPENSHELL_DB_URL` 来自 Secret、args 无 `--db-url`、
GRPCRoute/Gateway HTTPS、OIDC 写入 TOML、连接池 10+4、Service 暴露 metrics 9090）；
但托管 PG、CNPG、cert-manager、External Secrets、NetworkPolicy、备份恢复、
并发迁移与 HPA **都没有在本 POC 集群跑过**，逐条列在 `production/README.md` §12。
这些是部署方案，不是已验证结论。
