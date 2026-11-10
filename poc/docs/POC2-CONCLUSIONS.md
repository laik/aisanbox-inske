# POC2 模式结论 · 每租户独立 Gateway + 共享 Workspace / POC2 Pattern Conclusions — Per-Tenant Gateway + Shared Workspace

> **一句话 / In one sentence:** POC2 这套模式在 2026-11-08 的 kind(3 节点 / K8s v1.37 / Ubuntu 24.04 宿主)上
> **跑通了主干**，并在 **2026-11-09 补完了原本没验证的卖点本身**: 三个 Sandbox 挂同一份 Workspace 且权限不同
> (POC-04)、一个 Agent 改代码另两个并行只读 Review(POC-10)、按 `openshell.sandbox.id` 把 Trace / OCSF /
> 内核事件关联到同一个沙箱(POC-11)。**仍未验证的只剩 Tetragon 的强制能力**(受宿主内核 LSM 限制)。
>
> On 2026-11-08 this pattern **ran its main chain end to end** on a kind cluster (3 nodes / K8s v1.37 / Ubuntu 24.04 host),
> and on **2026-11-09 the claims that had been left unverified were completed**: three Sandboxes on one Workspace with
> different permissions (POC-04), one Agent changing code while two others review it read-only in parallel (POC-10), and
> Trace / OCSF / kernel events correlated to the same sandbox through `openshell.sandbox.id` (POC-11). **What remains
> unverified is Tetragon's enforcement capability** (blocked by the host kernel's LSM list).
>
> ⚠ **本轮最值得注意的是"验证方法"的错误，不是功能的缺失。** 原本判为"没通过"的三条里:
> POC-08 是按**错误的 service.name** 查 Trace; POC-09 是**把 chart 没暴露的键当成产品不支持**;
> POC-04/SEC-06 是**策略文件本身没有强制内容**(YAML 与 developer 版完全一样)。
> 每条在下面单独标出 —— 它们都是"测法"问题，改对之后功能本身是通的。
> The most notable finding this round is about **how things were measured, not what is missing.** Of the three verdicts
> originally recorded as failures: POC-08 queried traces by the **wrong service.name**; POC-09 treated **a key the chart
> does not expose as unsupported by the product**; POC-04/SEC-06 used a **policy file with no enforcing content** (its YAML
> was identical to the developer's). Each is called out below — they were measurement errors, and the features work once measured correctly.
>
> 与第一轮(operator 模式，其结论文档已移除、仅在 git 历史中保留)的区别：那一轮验证的是
> **operator 模式**(平台预建 namespace、按标签让 OpenShell 认领)。**这一轮验证的是 POC2 §2.3 的 shared 模式**——
> 一个 Gateway 只服务一个租户、该租户所有 Sandbox 落在它专属的 runtime namespace。
> 两条路的结论**不通用**，下面会逐条说明差异在哪里。
>
> Difference from round 1 (operator mode; its conclusions document was removed and survives only in git history): that round
> validated **operator mode** (the platform pre-creates namespaces and OpenShell claims them by label).
> **This round validates the shared mode of POC2 §2.3** — one Gateway serves
> exactly one tenant, and all of that tenant's Sandboxes live in its dedicated runtime namespace. The two paths'
> conclusions **do not transfer** to each other; the differences are called out item by item below.

> **文档约定 / Document conventions:** 每段中文后紧跟对应的英文段落；表格每个单元格内中文在上、英文在下；状态标记
> `✅ 通过 / PASS`、`⚠️ 部分 / PARTIAL`、`❌ 未验证 / NOT VERIFIED`。
> Each Chinese passage is followed by its corresponding English passage; in tables the Chinese text is on top and the English
> below within each cell; status labels are `✅ 通过 / PASS`, `⚠️ 部分 / PARTIAL`, `❌ 未验证 / NOT VERIFIED`.

**目录 / Table of Contents**

- [1. 这个模式实际是什么(以及和第一轮的差别) / What the pattern actually is](#c1)
- [2. 验证结果(按 POC2 的编号) / Verification results](#c2)
- [3. 关于这个模式的 6 条结构性结论 / Six structural conclusions](#c3)
- [4. 对 POC2 文档本身的修订建议 / Recommended revisions to POC2](#c4)
- [5. 这个模式离生产还差什么 / What production still needs](#c5)
- [6. 怎么复现本轮 / How to reproduce this round](#c6)

---

<a id="c1"></a>
## 1. 这个模式实际是什么(以及和第一轮的差别) / What the pattern actually is (and how it differs from round 1)

| | 第一轮(operator) / Round 1 (operator) | **本轮 POC2(shared) / This round (shared)** |
|---|---|---|
| namespace 归谁<br>Who owns the namespace | 平台建、打 `openshell.ai/workspace=true`，Gateway 按标签认领<br>The platform creates it, labels it `openshell.ai/workspace=true`, and the Gateway claims it by label | 平台建一个专属 runtime ns，Gateway 配置里写死 `namespace =`<br>The platform creates one dedicated runtime ns and the Gateway hard-codes `namespace =` |
| Sandbox 名字<br>Sandbox name | 裸名(namespace 提供隔离)<br>Bare name (the namespace provides isolation) | `{workspace}--{name}`(namespace 不提供隔离)<br>`{workspace}--{name}` (the namespace provides no isolation) ← 源码 `driver-kubernetes/config.rs` / source `driver-kubernetes/config.rs` |
| client-TLS 怎么到 Supervisor<br>How client-TLS reaches the Supervisor | 驱动自己塞进每次生成的 bootstrap Secret<br>The driver injects it into each generated bootstrap Secret | **必须由平台把 Secret 复制进租户 runtime ns**(见 §4.1)<br>**The platform must copy the Secret into the tenant runtime ns** (see §4.1) |
| 一个 Gateway 覆盖<br>What one Gateway covers | 多个 ns<br>Multiple namespaces | 一个 ns<br>One namespace |
| 与 Capsule 的接法<br>Integration with Capsule | 标签契约<br>Label contract | **namespace 归属契约**(更直接)<br>**Namespace ownership contract** (more direct) |

**模式判断：shared 模式与 Capsule 的组合更简单、可解释性更好**——一个租户 = 一个
Capsule Tenant = 一个 Gateway = 两个 namespace(gateway / runtime)。第一轮的 operator
模式多出一层"标签发现"，排查时多一处看不见的手。代价是 shared 模式**要求平台自己做两件
事**：把 client-TLS bundle 落到 runtime ns，以及把外部 PVC 的授权标签管住(§4)。

**Pattern verdict: shared mode composes with Capsule more simply and is easier to reason about** — one tenant = one
Capsule Tenant = one Gateway = two namespaces (gateway / runtime). Round 1's operator mode adds a layer of "label discovery",
which is one more invisible hand during troubleshooting. The price is that shared mode **requires the platform to do two
things itself**: place the client-TLS bundle in the runtime ns, and govern the authorization labels of external PVCs (§4).

---

<a id="c2"></a>
## 2. 验证结果(按 POC2 的编号) / Verification results (by POC2 ID)

> 规则(POC2 §14.3 明确要求)：**不把设计预期写成测试结果**。下面"证据"一栏只写实际看到的输出。
> Rule (explicitly required by POC2 §14.3): **do not write design expectations as test results.** The "evidence" column
> below contains only output actually observed.

| 编号 / ID | 结论 / Verdict | 证据 / 缺口<br>Evidence / gap |
|---|---|---|
| POC-01 每租户独立 Gateway<br>Per-tenant independent Gateway | ✅ 通过 / PASS | 两个 Gateway 各自 mTLS 认证、各自 `gateway_id`、各自 SQLite PVC；两边都建出同名 workspace `poc-shared` 且互不可见；`auth can-i` 显示 A 的 SA 在 B 的 runtime ns 里是 `no`<br>Each Gateway authenticates over its own mTLS, has its own `gateway_id` and its own SQLite PVC; both create a workspace named `poc-shared` yet neither sees the other; `auth can-i` shows A's SA as `no` in B's runtime ns |
| POC-02 Capsule 租户隔离<br>Capsule tenant isolation | ✅ 通过(比预期更强) / PASS (stronger than expected) | 归属只在创建时由 webhook 注入(不能事后追认)；`ForceTenantPrefix` 拦住跨租户命名；**配额真的管住了 OpenShell 创建的沙箱**：`exceeded quota: capsule-tenant-a-0, requested: limits.memory=1Gi, used: 2Gi, limited: 2560Mi`<br>Ownership is injected by the webhook only at creation time (no retroactive adoption); `ForceTenantPrefix` blocks cross-tenant naming; **the quota really did govern sandboxes created by OpenShell**: `exceeded quota: capsule-tenant-a-0, requested: limits.memory=1Gi, used: 2Gi, limited: 2560Mi` |
| POC-03 Gateway 管理多个 Sandbox<br>One Gateway manages multiple Sandboxes | ✅ 通过(3 个并发) / PASS (3 concurrent) | 2026-11-09: 同一个 Gateway 下 `pi-dev` + `pi-review-1` + `pi-review-2` 同时 Ready。**之前挡住第 3 个的是两个配额维度**，都不是 OpenShell 的问题: ① `count/services` —— 每个沙箱会建 **两个 Service**(`os-boundary-<pair>` + `os-supervisor-<pair>`)，报错直接进 CLI; ② `requests.memory` —— 一个 Pi 沙箱的 **requests** 是 1Gi(agent) + 128mi(它自己的 supervisor) ≈ **1.15Gi**，CLI 只说 `timed out waiting for gated workload Pod`。算术见 `capsule2/tenants.yaml`。<br>On 2026-11-09, `pi-dev` + `pi-review-1` + `pi-review-2` were Ready at the same time under one Gateway. **Two separate quota dimensions had blocked the third**, neither an OpenShell defect: (1) `count/services` — every sandbox creates **two Services** (`os-boundary-<pair>` + `os-supervisor-<pair>`), and this one does surface in the CLI; (2) `requests.memory` — a Pi sandbox's **requests** are 1Gi (agent) + 128mi (its own supervisor) ≈ **1.15Gi**, while the CLI only says `timed out waiting for gated workload Pod`. Arithmetic is in `capsule2/tenants.yaml` |
| POC-04 多 Sandbox 共享 Workspace<br>Multiple Sandboxes share a Workspace | ✅ 通过(含跨节点) / PASS (incl. cross-node) | `phases/11-pi-scenario.sh` 已写并跑通: `pi-dev` 用 RW 挂 `shared-workspace`，clone 项目、跑 `go test`、让 Pi 写了一个**真的能过的新测试**(`poc_extra_test.go`); 两个 Reviewer 用 RO 挂同一个 PVC，**都看到了这个文件**(`git status` 里可见、`wc -l` 有内容)，写入被拒。跨节点也成立: dev 在 `worker2`，被 `node_selector` 强制到 `worker` 的沙箱读到同一个文件、写入同样被拒。<br>**之前判 ❌ 的直接原因: `policies/pi-reviewer.yaml` 的 YAML 与 developer 版一字不差** —— `/data/workspace` 还在 `read_write` 里，注释却已经写成"只读"。测法与文件都错，不是平台不行。<br>`phases/11-pi-scenario.sh` is written and ran: `pi-dev` mounts `shared-workspace` RW, clones the project, runs `go test`, and has Pi write a **new test that actually passes** (`poc_extra_test.go`); both Reviewers mount the same PVC read-only, **both see that file** (visible in `git status`, `wc -l` non-empty), and their writes are denied. Cross-node holds too: dev ran on `worker2` while a sandbox forced by `node_selector` onto `worker` read the same file and was likewise denied. **The direct reason for the earlier ❌: the reviewer policy's YAML was byte-identical to the developer's** — `/data/workspace` was still under `read_write` while the comments already claimed read-only. Both the file and the test were wrong; the platform was not. |
| POC-05 Antrea 网络隔离<br>Antrea network isolation | ✅ 通过 / PASS | 9/9：无策略通、deny-all 拦、白名单只放行被选中的 Pod；并进了 Antrea 控制面与 OVS 流表(123→135→123)，跨节点路径<br>9/9: traffic passes with no policy, deny-all blocks it, and the allow-list admits only the selected Pod; verified in the Antrea control plane and OVS flow tables (123→135→123) across nodes |
| POC-06 Gatekeeper 准入<br>Gatekeeper admission | ✅ 通过(且作用域精确) / PASS (with precise scope) | privileged / hostNetwork / hostPID / hostPath / 借用平台 SA 全部被 `[poc-tenant-pod-boundary]` 拒；**同一个 ns 内**平台 SA 身份通过、租户身份被拒 —— 没有任何 ns 级豁免<br>privileged / hostNetwork / hostPID / hostPath / borrowing a platform SA are all rejected by `[poc-tenant-pod-boundary]`; **within the same ns** the platform SA identity passes while the tenant identity is rejected — no namespace-level exemption |
| POC-07 Tetragon 行为观测<br>Tetragon behavior observability | ✅ 观测通过 / ⚠️ 强制受限<br>PASS for observation / PARTIAL for enforcement | exec、exit、connect(五元组)、parent、pod/namespace/容器/镜像身份都在事件里。但**这台宿主的内核 LSM 列表没有 `bpf`**(`lockdown,capability,landlock,yama,apparmor`)，基于 lsm hook 的策略加载失败<br>exec, exit, connect (5-tuple), parent, pod/namespace/container/image identity all appear in events. But **this host's kernel LSM list lacks `bpf`** (`lockdown,capability,landlock,yama,apparmor`), so policies based on lsm hooks fail to load |
| POC-08 Pi 的 OTel Trace<br>Pi OTel traces | ✅ 通过 / PASS | `GET /api/traces?service=pi-agent` 返回完整 trace: `invoke_agent pi` / `chat qwen3.8-flash-next` / `pi.turn`，resource 里有 `openshell.sandbox.id`、`openshell.telemetry.source=agent`、`host.name=poc-shared--pi-*`、`process.*`。**之前判 ⚠️ 的真正原因是查错了名字**: `pi-otel` 只从 `~/.pi/agent/settings.json` 或 `<cwd>/.pi/settings.json` 读配置，而 `setup-agent-home.sh` 写的是 agent 目录根 → 配置被静默忽略，`service.name` 退回默认 **`pi`**，于是按 `pi-agent` 查永远 0 条(按 `pi` 查一直是有)。修好后 span 名变成 POC2 §6.3 期望的 `invoke_agent pi`/`chat <model>` —— 这本身就是 settings 被读到的证据。<br>另一个坑: `pi -p` **会等 stdin**。`sandbox exec` 保持 stdin 打开 → pi 永不退出、stdout/stderr 全空、rc=124。必须 `</dev/null`。这一度被误读成"模型连不上"。<br>`GET /api/traces?service=pi-agent` returns a full trace: `invoke_agent pi` / `chat qwen3.8-flash-next` / `pi.turn`, with `openshell.sandbox.id`, `openshell.telemetry.source=agent`, `host.name=poc-shared--pi-*` and `process.*` in the resource. **The earlier ⚠️ was a wrong query key**: `pi-otel` reads config only from `~/.pi/agent/settings.json` or `<cwd>/.pi/settings.json`, while `setup-agent-home.sh` wrote it at the agent-dir root — the config was silently ignored, `service.name` fell back to the default **`pi`**, so querying `pi-agent` always returned 0 (querying `pi` always returned data). Once fixed, span names become the `invoke_agent pi` / `chat <model>` shape POC2 §6.3 expects, which is itself proof settings were read. Second trap: **`pi -p` waits on stdin.** `sandbox exec` keeps stdin open, so pi never exits, prints nothing, and dies at rc=124 — `</dev/null` is required. This was misread as "the model is unreachable". |
| POC-09 OpenShell 遥测<br>OpenShell telemetry | ✅ 通过(OCSF 走 OTLP 已证) / PASS (OCSF over OTLP proven) | Gateway / driver / supervisor 的 trace 进两个后端；OCSF 决策在 Supervisor 日志里完整。**并且 `[openshell.gateway.otlp.ocsf] enabled = true` 是有效的**: 加上并重启后 gateway 起来正常(`ocsf_endpoint=…` 出现在它的启动日志里)，gateway 自己的指标 `openshell_ocsf_otlp_exported_total 3`(无 error)，Collector 收到 scope 为 `openshell.ocsf` 的日志记录，带 `ocsf.class_uid: Int(3002)` 等结构化属性。**之前那句"未验证"是把 chart 没暴露这个键当成了产品不支持** —— 二进制里能直接看到 `otlp needs an endpoint, or otlp.ocsf or otlp.agent with enabled = true` 和 `openshell_ocsf_otlp_*` 指标。<br>注意两点: OCSF 走的是 Collector 的 **logs** pipeline(不是 traces)；`ocsf_log`(JSONL) 是**并行**的第二条通道，保留它做 POC2 §14.2 的离线证据。<br>Gateway/driver/supervisor traces reach both backends and OCSF decisions are complete in the Supervisor logs. **And `[openshell.gateway.otlp.ocsf] enabled = true` does work**: after enabling it and restarting, the Gateway starts fine (its startup log shows `ocsf_endpoint=…`), its own metrics show `openshell_ocsf_otlp_exported_total 3` (no errors), and the Collector receives records with scope `openshell.ocsf` carrying structured attributes such as `ocsf.class_uid: Int(3002)`. **The earlier "not verified" confused a key the chart does not expose with a feature the product lacks** — the binary itself contains `otlp needs an endpoint, or otlp.ocsf or otlp.agent with enabled = true` and the `openshell_ocsf_otlp_*` metrics. Two caveats: OCSF flows through the Collector's **logs** pipeline, not traces; and `ocsf_log` (JSONL) is a **parallel** second channel, worth keeping as offline evidence for POC2 §14.2. |
| POC-10 多 Agent 协作<br>Multi-Agent collaboration | ✅ 通过 / PASS | `pi-dev` 改代码(新增一个能过的测试) → `pi-review-1` 与 `pi-review-2` **并行**读同一份工作区并各自给出带 file:line 的 review 结论(两个结论内容不同，各自发现断言强度/命名/冗余守卫等问题)；结束后 `git status` 仍只有 dev 那一个未跟踪文件 —— **两个 Reviewer 一个字节都没写**。<br>要诚实区分: 平台侧(共享 + 只读 + 并行)是**确定**的；"review 质量"取决于本地这台模型的能力，不要把模型答得不好算作平台缺陷。<br>`pi-dev` changes code (one new passing test) → `pi-review-1` and `pi-review-2` read the same workspace **in parallel** and each return findings with file:line references (different findings, each spotting assertion strength / naming / a redundant guard); afterwards `git status` still shows only dev's one untracked file — **neither Reviewer wrote a single byte**. To be honest about it: the platform side (sharing + read-only + parallelism) is certain; review *quality* depends on the local model, and a weak model answer must not be counted as a platform defect. |
| POC-11 安全事件关联<br>Security event correlation | ✅ 通过 / PASS | 关联键就是 `openshell.sandbox.id`，而且**三条流上都齐**: ① Trace —— supervisor 的 span 有 `sandbox.id`/`sandbox.name`，Pi 的 span resource 有 `openshell.sandbox.id`(relay 补的，源码 `otlp_relay/enrichment.rs`)；② Kubernetes —— 同一个 UUID 是 workload Pod 和 supervisor Pod 的标签 `openshell.ai/boundary-pair`；③ 内核/OCSF —— 由 Pod 名对上，实测同一次 curl: Tetragon 给出 `binary=/usr/bin/curl`、`argv`、`uid=10001`、`pod.name=poc-shared--pi-review-2`、`pod.uid`、容器与镜像，同一秒 Supervisor 给出 `OCSF NET:OPEN [MED] DENIED /usr/bin/curl(0) -> api.openai.com:443 [reason:transparent_tcp_policy_denied]`。<br>join 路径: `trace(sandbox.id)` == `pod label boundary-pair` == `pod name` == Tetragon 的 `pod.name` == 该 supervisor 的 OCSF 行。**之前判 ❌ 是因为按 `pi-agent` 查不到 trace(见 POC-08)**，不是没有关联键。<br>The correlation key is `openshell.sandbox.id`, and **all three streams carry it**: (1) traces — supervisor spans carry `sandbox.id`/`sandbox.name`, and Pi span resources carry `openshell.sandbox.id` (added by the relay, source `otlp_relay/enrichment.rs`); (2) Kubernetes — the same UUID is the `openshell.ai/boundary-pair` label on both the workload and the supervisor Pod; (3) kernel/OCSF — matched by Pod name, shown for one and the same curl: Tetragon gives `binary=/usr/bin/curl`, argv, `uid=10001`, `pod.name=poc-shared--pi-review-2`, `pod.uid`, container and image, and in the same second the Supervisor gives `OCSF NET:OPEN [MED] DENIED /usr/bin/curl(0) -> api.openai.com:443 [reason:transparent_tcp_policy_denied]`. The join path is `trace(sandbox.id)` == `pod label boundary-pair` == `pod name` == Tetragon's `pod.name` == that supervisor's OCSF lines. **The earlier ❌ came from not finding traces under `pi-agent` (see POC-08)**, not from a missing key. |

**关于沙箱生命周期(实测，值得写进模式结论) / On sandbox lifetime (observed; worth recording as a pattern conclusion):**
沙箱的存活期 = 我们传给它的命令的存活期。
`-- sleep 1800` 到期之后沙箱 phase 变 `Completed`，之后任何 `sandbox exec` 都是
`Error: sandbox 'x' is not ready (phase: Completed)`。不是超时、不是被回收。
对"跑一段任务再查观测"的用法，这意味着要么给足够长的 keepalive，要么用
`--restart-policy` 与真正的长驻进程。这个行为对**证据留存**影响很大: 观测后端里的数据
还在，但产生它的那个工作负载已经不能回去查了。

A sandbox lives exactly as long as the command passed to it. After `-- sleep 1800` expires, the sandbox phase becomes
`Completed`, and every subsequent `sandbox exec` returns `Error: sandbox 'x' is not ready (phase: Completed)`. It is not a
timeout and it was not reclaimed. For the "run a task, then inspect observability" workflow this means either supplying a
long enough keepalive, or using `--restart-policy` with a genuinely long-lived process. This matters a great deal for
**evidence retention**: the data remains in the observability backend, but the workload that produced it can no longer be
queried.

### 安全用例(POC2 §11) / Security cases (POC2 §11)

| 用例 / Case | 结果 / Result | 实测 / Observed |
|---|---|---|
| SEC-01 Pi 直接 curl 未授权域名<br>Pi curls an unauthorized domain directly | ✅ | `api.openai.com` / `example.com` **4–6 ms** 内失败(`Couldn't connect`，不是超时)<br>Fails within **4–6 ms** (`Couldn't connect`, not a timeout) |
| SEC-02 经 Supervisor 访问批准的端点<br>Accessing an approved endpoint through the Supervisor | ✅ | `192.168.5.190:8080/v1/chat/completions` 被 supervisor 记为 `OCSF HTTP:POST ALLOWED … engine:l7`<br>Recorded by the supervisor as `OCSF HTTP:POST ALLOWED … engine:l7` |
| SEC-03 未批准域名<br>Unapproved domain | ✅ | 同 SEC-01；策略名在事件里可见(`_provider_poc_model`)<br>Same as SEC-01; the policy name is visible in the event (`_provider_poc_model`) |
| SEC-05 Agent 访问 Kubernetes API<br>Agent accesses the Kubernetes API | ✅ | `kubernetes.default.svc:443` 被拒<br>`kubernetes.default.svc:443` is denied |
| SEC-09 不安全 Pod<br>Unsafe Pod | ✅ | 见 POC-06<br>See POC-06 |
| SEC-10 租户直接创建 Sandbox CR<br>Tenant creates a Sandbox CR directly | ✅ | 两层分开测：RBAC 先拒；**故意把权限给租户之后**，`[poc-managed-cr-only-platform]` 仍然拒<br>Tested as two layers: RBAC denies first; **after deliberately granting the tenant the permission**, `[poc-managed-cr-only-platform]` still denies |
| SEC-11 Agent 读不到 Provider Token<br>Agent cannot read the Provider token | ✅ | 沙箱里 `OPENAI_API_KEY=openshell:resolve:env:v7305…_OPENAI_API_KEY`，是**代理占位符**；真实 key 只在边界上注入(请求能成功即证明)<br>Inside the sandbox `OPENAI_API_KEY=openshell:resolve:env:v7305…_OPENAI_API_KEY`, a **proxy placeholder**; the real key is injected only at the boundary (a successful request proves it) |
| SEC-13 另一个进程绕过工具调用直接出网<br>Another process reaching the network without tool calls | ✅ 成立(比预期更强) / holds (stronger than expected) | 被测进程 = 镜像里的 `node`，直接开**原始 socket**(不经 Pi、不经任何工具调用)。**正对照**: 连自己的 `supervisor:5500` = `CONNECTED`(缺这条整段不可用——踩过：Service clusterIP 取空会得到 ECONNREFUSED，看着像被拦)。其余全断：`10.96.0.1:443` TIMEOUT；`1.1.1.1:443`(写死 IP、跳过 DNS) TIMEOUT；`dns.lookup` = `EAI_AGAIN`。拦它的是 §5.4/§3.4 那两条 NetworkPolicy(**L4**)，不是 OpenShell 的 L7 策略 —— 所以"绕过 Agent 工具层"这条路不存在。<br>The process under test is `node` from the image, opening a **raw socket** (no Pi, no tool call). **Positive control**: connecting to its own `supervisor:5500` = `CONNECTED` (without it the run is unusable — measured: an empty Service clusterIP yields ECONNREFUSED, which looks like a denial). Everything else is denied: `10.96.0.1:443` TIMEOUT; `1.1.1.1:443` (literal IP, DNS skipped) TIMEOUT; `dns.lookup` = `EAI_AGAIN`. What blocks it is the two NetworkPolicies of §5.4/§3.4 (**L4**), not OpenShell's L7 policy — so "bypass the Agent tool layer" is not a path that exists. |
| SEC-14 使用未批准的 PVC<br>Using an unapproved PVC | ✅ | 无标签 / 标签值不匹配 → `external resource not admitted by required labels`；标签匹配 → 允许<br>No label / mismatched label value → `external resource not admitted by required labels`; matching label → allowed |
| SEC-06 / SEC-07 Reviewer 只读 / Developer 可写<br>Reviewer read-only / Developer writable | ✅ 通过(两层分别验证) / PASS (each layer verified separately) | `phases/13-security-matrix.sh`。**两条独立的强制链，errno 不同**: 只关策略(挂载 rw) → `mount_flags=rw,relatime` 但写被拒 **EACCES**(OpenShell 策略层)；只关挂载(策略 rw) → **EROFS** `Read-only file system`(Kubernetes 挂载层)。Reviewer 默认两层都关。<br>**别按固定列号读 mountinfo** —— 字段 4 是挂载根不是选项，实测两种情况都打印 `/`，这一列证据等于没测。正确 awk 见脚本注释。<br>`phases/13-security-matrix.sh`. **Two independent enforcement chains with different errnos**: policy off only (mount rw) → `mount_flags=rw,relatime` yet the write is denied **EACCES** (OpenShell policy layer); mount ro only (policy rw) → **EROFS** `Read-only file system` (Kubernetes mount layer). The Reviewer has both off by default. Do **not** read mountinfo by fixed field number — field 4 is the mount root, not the options; measured output was `/` in both cases, i.e. that column of evidence was dead. Correct awk is in the script comments. |
| SEC-04 / SEC-08 跨租户网络<br>Cross-tenant networking | ⚠️ **通过，但归因要改**（2026-11-10 POC3 更正：已是平台能力）<br>PASS, attribution changes (POC3 2026-11-10: now a platform capability) | `phases/13-security-matrix.sh` 实测三件事: ① Capsule Tenant 的 `spec.networkPolicies` 是**空的**；② 两个**普通 Pod** 跨租户 `tenant-a/p-a -> tenant-b/p-b:8080` = **REACHED**；③ OpenShell 沙箱跨租户/跨 namespace = TIMEOUT。→ 阻断来自 **OpenShell 自己生成的 NetworkPolicy**，**不是**平台的租户网络隔离。机制是**两条策略相加**(实测 spec): `openshell-sandbox-workloads` 的 `policyTypes=[Ingress,Egress]` 却**只定义 ingress** ⇒ 它自己把 workload 出网全 deny；`os-control-<boundary-pair>` 再放行**唯一**一条 egress = 同一 `boundary-pair` 的 `supervisor:5500`。⚠ 取证时只打印前者的 `.spec.egress` 会得到**空白一列**(它本来就是空的)，必须连后者的 `.spec.egress[0].to` 一起取。"Agent 不能绕过 Supervisor 出网"(POC-05)成立；"租户之间网络隔离"是边界的副作用，换掉 OpenShell 或只跑普通 Pod 就不存在，要补 Capsule networkPolicies 或 Antrea ClusterNetworkPolicy。<br>两个坑叠在同一条测试上，都会给出**假的"隔离生效"**: 目标 Pod 必须**在被测端口真有监听**；busybox 的 `nc -l` **只服务一条连接**就退出，所以"先自证在监听"会自己把 listener 用掉。正确写法是 `while true; do nc -l -p 8080 </dev/null; done`，自证只打 127.0.0.1 且放在跨租户测试**之后**。<br>Three measured facts: (1) Capsule Tenant `spec.networkPolicies` is **empty**; (2) two **plain Pods** across tenants `tenant-a/p-a -> tenant-b/p-b:8080` = **REACHED**; (3) OpenShell sandboxes across tenants/namespaces = TIMEOUT. So the block comes from **OpenShell's own generated NetworkPolicies**, **not** from platform tenant isolation. The mechanism is **two policies composed** (specs measured): `openshell-sandbox-workloads` declares `policyTypes=[Ingress,Egress]` but defines **only ingress** ⇒ all workload egress is denied by that policy alone; `os-control-<boundary-pair>` then allows the **single** egress = `supervisor:5500` of the same `boundary-pair`. ⚠ Collecting only the first policy's `.spec.egress` yields a **blank column** (it is legitimately empty); read the second one's `.spec.egress[0].to` as well. "The Agent cannot bypass the Supervisor to reach the network" (POC-05) holds; "tenant-to-tenant network isolation" is a side effect of the boundary and disappears if OpenShell is swapped out or plain Pods run — you'd need Capsule networkPolicies or an Antrea ClusterNetworkPolicy. Two traps stack on the same test and both yield a **false "isolation works"**: the target Pod must **actually listen on the tested port**, and busybox's `nc -l` **serves one connection** then exits, so self-verifying the listener consumes it. Correct form: `while true; do nc -l -p 8080 </dev/null; done`, with the self-check on 127.0.0.1 only and **after** the cross-tenant test. |
| SEC-12 Supervisor 断链 fail-closed<br>Supervisor fail-closed on lost connection | ✅ 已实测(控制面/数据面分开) / measured (control vs data plane) | 断链的正确做法是把 **StatefulSet** `os-a-openshell` 缩到 0(它是 StatefulSet，`scale deployment/` 会 NotFound)。**数据面不 fail-closed**: 沙箱内每 20s 调一次模型的循环，在停机窗口里**仍持续拿到回复**(两次实测 3→5→9 / 3→4→8，时间戳都在窗口内)；该 supervisor 的「OCSF HTTP:POST」计数同期上涨(一次 6→14)。**控制面 fail-closed**: `sandbox create` 失败，`sandboxes.agents.x-k8s.io` 里**连对象都没有**(0)。supervisor **察觉**断链(自己日志 `OCSF NET:FAIL [LOW] os-a-openshell.tenant-a-gateway.svc.cluster.local:8080`，恢复后 `NET:OPEN`)，但仍继续代理**已批准的** L7 流量 —— 与 `openshell-sandbox-supervisors` 那条 netpol 一致(`policyTypes=[Egress]`、`egress=[{}]` = 全开)。<br>⚠ 测法比结论更容易错(四个坑，脚本注释里都有): ① 不要用 NetworkPolicy 当"断链"(那掐的是 supervisor 出网)；② `openshell sandbox exec` **自己走 Gateway**，断链必然 `connect error: transport error`，用它测数据面会得到假结论；③ `kubectl exec` 的环境**不完整**(没有注入的 `OPENAI_API_KEY` 占位符与 supervisor CA → pi 报 `apiKey: must not have fewer than 1 characters`，那是"没有模型"不是"网络不通")；④ Sandbox CR 的真名是 `<workspace>--<name>`，按 `<name>` 查会 NotFound；⑤ 把 Gateway 缩到 0 会把它上面的 `port-forward` 一起弄断，所以**恢复之后**脚本收尾的 `sandbox delete` 只剩一条 transport error（stderr 丢了就完全看不见），实测 `sec12-loop` 因此没删掉、白占 2 个 Service 配额，下一轮 create 撞配额。<br>The correct disconnect is scaling the **StatefulSet** `os-a-openshell` to 0 (it is a StatefulSet; `scale deployment/` returns NotFound). **The data plane does not fail closed**: a loop inside the sandbox calling the model every 20 s keeps getting answers through the outage (3→5→9 and 3→4→8 in two runs, timestamps inside the window); that supervisor's `OCSF HTTP:POST` count rises in the same window (6→14 in one run). **The control plane does fail closed**: `sandbox create` fails and there is not even an object in `sandboxes.agents.x-k8s.io` (0). The supervisor **notices** the break (`OCSF NET:FAIL … os-a-openshell…:8080`, back to `NET:OPEN` when restored) and still proxies **approved** L7 traffic — consistent with the `openshell-sandbox-supervisors` policy (`policyTypes=[Egress]`, `egress=[{}]` = unrestricted).<br>⚠ The method is easier to get wrong than the conclusion (four traps, all in the script comments): (1) do not use a NetworkPolicy as "the disconnect" — that cuts the supervisor's egress; (2) `openshell sandbox exec` **goes through the Gateway itself**, so during the outage it always returns `connect error: transport error` — measuring the data plane that way gives a false conclusion; (3) `kubectl exec` has an **incomplete** environment (no injected `OPENAI_API_KEY` placeholder, no supervisor CA → pi reports `apiKey: must not have fewer than 1 characters`, which is "no model", not "no network"); (4) the real Sandbox CR name is `<workspace>--<name>`, so looking it up by `<name>` returns NotFound; (5) scaling the Gateway to 0 also tears down the `port-forward` tunnelled through it, so the `sandbox delete` the script runs **after** the restore only yields a transport error (invisible if stderr is dropped) — measured: `sec12-loop` survived that way, held 2 Service quota units, and the next round's `create` hit the quota. |

---

<a id="c3"></a>
## 3. 关于这个模式的 6 条结构性结论 / Six structural conclusions about the pattern

这一节才是"模式"层面的东西——不是某个组件的 bug，而是**这套组合的固有性质**。

This section is about the pattern itself — not a bug in any component, but **inherent properties of this combination**.

### 3.1 平台默认值的覆盖范围，决定了你要写多少策略 / The coverage of platform defaults determines how many policies you must write

OpenShell 不给文件系统策略时，基线是
`/bin /usr /lib /proc /dev/urandom /etc /var/log` 只读、`/tmp /dev/null` 读写。
**不含 `/opt`，也不含 `/data`。** 后果是同一类报错在两个地方出现：

When OpenShell is given no filesystem policy, the baseline is `/bin /usr /lib /proc /dev/urandom /etc /var/log` read-only and
`/tmp /dev/null` read-write. **It includes neither `/opt` nor `/data`.** The consequence is the same class of error appearing
in two places:

- Pi 的 agent 目录放在 `/opt` → 沙箱里 `Permission denied`，而 `ls -ld` 显示 mode 是
  `0755 root`(uid 10001 本该能读)——**报错指向 Unix 权限，实际是策略边界**；
  Pi's agent directory lives under `/opt` → `Permission denied` inside the sandbox, while `ls -ld` shows mode `0755 root`
  (uid 10001 ought to be able to read it) — **the error points at Unix permissions but is really the policy boundary**;
- 共享 PVC 挂在 `/data/workspace` → 同样 `Permission denied`，而**同一个 PVC 挂进普通
  Pod** 时 uid 10001 读写都正常(`UID_WRITE_OK`)。
  The shared PVC is mounted at `/data/workspace` → the same `Permission denied`, while **the same PVC mounted into an
  ordinary Pod** is read-write for uid 10001 (`UID_WRITE_OK`).

**结论：这个模式里"策略基线覆盖了哪些路径"是平台契约的一部分。** 任何放在基线之外的路径
(agent 目录、工作区、缓存)都必须显式进策略，且要在开通流程里生成，不能靠调镜像。
POC2 §5.3 已经写了"每个 Sandbox 使用自己的 OpenShell 策略"，但没写**为什么必须**——
上面就是为什么。

**Conclusion: in this pattern, "which paths the policy baseline covers" is part of the platform contract.** Any path outside
the baseline (agent directory, workspace, cache) must be added to the policy explicitly and generated by the provisioning
flow — not papered over by adjusting the image. POC2 §5.3 already says "each Sandbox uses its own OpenShell policy", but it
does not say **why it must** — the two cases above are why.

### 3.2 沙箱以 uid 10001 运行，镜像里的 `USER` 会被覆盖 / Sandboxes run as uid 10001, overriding the image's `USER`

POC2 §6.1 的 Dockerfile 用 `USER node`。实际沙箱里是 `uid=10001`。因此：

The Dockerfile in POC2 §6.1 uses `USER node`. The actual sandbox runs as `uid=10001`. Therefore:

- 镜像里 `chown node` 的目录在沙箱里不可写；
  Directories `chown`ed to `node` in the image are not writable in the sandbox;
- 镜像的 `ENV PI_CODING_AGENT_DIR` **不会**传进沙箱(要靠运行期给)。
  The image's `ENV PI_CODING_AGENT_DIR` is **not** passed into the sandbox (it must be supplied at runtime).

所以 Pi 镜像的正确做法是：构建期把 agent 目录(含扩展)准备好并设成**所有 uid 可读**，
运行期复制成可写副本(`/usr/local/pi/setup-agent-home.sh`)。同一个坑在 `USER node`
之后的 `/opt` 上也出现过一次(构建期 `unable to find user node`)。

So the correct approach for the Pi image is: prepare the agent directory (including extensions) at build time and make it
**readable by every uid**, then copy it to a writable location at runtime (`/usr/local/pi/setup-agent-home.sh`). The same
trap appeared once with `/opt` after `USER node` (`unable to find user node` at build time).

### 3.3 凭据与网络是同一个控制点，不是两层 / Credentials and network are one control point, not two layers

Provider profile 同时声明 **endpoint + 哪个二进制能去 + 凭据放哪儿**。实测：

A Provider profile declares **the endpoint, which binaries may reach it, and where the credential lives** all at once.
Observed:

- OpenShell **不把任何 provider profile 编进发行版**(源码注释原话)。
  `provider create --type openai` 必然报 `provider profile 'openai' not found`——
  **平台必须自己声明允许哪个主机**。这不是缺陷，是这个模式的前提。
  OpenShell **ships no provider profile in the distribution** (the source comment says so verbatim).
  `provider create --type openai` necessarily returns `provider profile 'openai' not found` —
  **the platform must declare which hosts are allowed itself.** This is not a defect; it is a premise of the pattern.
- 官方 `providers/openai.yaml` 的注释明确要求：**另一个主机上的 OpenAI 兼容服务要另建一个
  profile 命名那个主机**，不要改官方的。本轮就是照这个做的(`providers/poc-model.yaml`)。
  The comment in the official `providers/openai.yaml` explicitly requires: **an OpenAI-compatible service on another host
  needs its own profile naming that host**; do not edit the official one. This round followed exactly that
  (`providers/poc-model.yaml`).
- 凭据的存储键是 profile 里声明的 **`env_vars` 名**(`OPENAI_API_KEY`)，不是逻辑名
  (`api_key`)。写 `--credential api_key=…` 会得到
  `provider credentials are not declared by profile 'poc-model': api_key`。
  The storage key for a credential is the **`env_vars` name declared in the profile** (`OPENAI_API_KEY`), not the logical
  name (`api_key`). Writing `--credential api_key=…` returns
  `provider credentials are not declared by profile 'poc-model': api_key`.
- **不需要凭据的纯出权也能表达**(`credentials: []` + `--provider poc-git`)，这让
  "沙箱能访问 GitHub"成为**显式声明**而不是默认允许。
  **Pure egress with no credential can also be expressed** (`credentials: []` + `--provider poc-git`), which turns "the
  sandbox may reach GitHub" into an **explicit declaration** instead of a default allowance.

### 3.4 Agent 侧的 OTLP 是"免费"的，但要理解它接到哪儿 / Agent-side OTLP is "free", but understand where it connects

创建沙箱后，OpenShell 自动注入：

After a sandbox is created, OpenShell automatically injects:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://192.0.0.8:4318   # 这个沙箱自己的 supervisor relay
                                                     # this sandbox's own supervisor relay
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
NODE_EXTRA_CA_CERTS=/run/openshell-supervisor-ca/material/ca.crt
```

pi-otel 正好读这两个环境变量，所以 **agent 不需要知道 Collector 地址、也不需要任何
Collector 凭据**——POC2 §8.2 想要的效果是现成的(且 relay 默认关闭，`otlp.agent.enabled=true`
一开就有)。实测 relay 说 OTLP/HTTP protobuf(发 JSON 会得到 415 并明确告诉你
`send application/x-protobuf`)。

pi-otel happens to read exactly these two environment variables, so **the agent needs neither the Collector address nor any
Collector credential** — the effect POC2 §8.2 wants is already available (the relay is off by default; setting
`otlp.agent.enabled=true` turns it on). In practice the relay speaks OTLP/HTTP protobuf (sending JSON yields a 415 that
explicitly says `send application/x-protobuf`).

**但**：这条链在 POC 里只证明了"到 Collector"，没证明"到可查询的后端并带上可关联的身份"。
relay 会不会给 span 补 `openshell.sandbox.id`，未验证。**这正是 POC-11 的入口，也是这套
模式能不能产生审计价值的关键一环。**

**However:** in this POC the chain proved only "reaches the Collector", not "lands in a queryable backend carrying
correlatable identity". Whether the relay adds `openshell.sandbox.id` to spans was not verified. **This is exactly the entry
point for POC-11 and the key link that decides whether this pattern produces audit value.**

### 3.5 失败路径很长，跨产品 / Failure paths are long and cross product boundaries

三个实测例子，报错都**不在**产生问题的地方：

Three observed examples where the error is **not** where the problem originates:

| 现象 / Symptom | 报错在哪 / Where the error appears | 真实原因在哪 / Where the real cause is |
|---|---|---|
| 第 3 个沙箱起不来<br>The third sandbox would not start | CLI: `timed out waiting for gated workload Pod` | agent-sandbox 控制器日志: Capsule **配额**已满<br>agent-sandbox controller logs: the Capsule **quota** was full |
| Supervisor 卡在 ContainerCreating<br>Supervisor stuck in ContainerCreating | kubelet: `secret "openshell-client-tls" not found` | shared 模式下**平台要自己把 Secret 复制到 runtime ns**(驱动只在多 ns 模式下自己塞)<br>In shared mode **the platform must copy the Secret into the runtime ns itself** (the driver only injects it in multi-ns mode) |
| `ls /data/workspace` 被拒<br>`ls /data/workspace` is denied | 沙箱内 `Permission denied`<br>`Permission denied` inside the sandbox | OpenShell **策略基线**不含 `/data`<br>The OpenShell **policy baseline** excludes `/data` |

**结论：这套模式对可观测性的要求不是"锦上添花"，而是可用性前提。** §12 的关联设计要优先
覆盖"配额拒绝""策略基线""Secret 缺失"这三类，因为运维第一次撞到它们时看到的都是别的
产品的错误。

**Conclusion: in this pattern, observability is not a nice-to-have but a precondition for usability.** The correlation design
in §12 should cover "quota denial", "policy baseline" and "missing Secret" first, because the first time an operator hits
them, what they see is another product's error.

### 3.6 配额要按"一个沙箱的真实开销"设计 / Size quotas by the real cost of one sandbox

一个沙箱不止 agent 容器：还有它自己的 supervisor Pod 和一个 workspace PVC。实测一个沙箱
(带 PVC)让租户配额涨到 `limits.memory=1536Mi / count/pods=2`。`scope: Tenant` 让配额是
**跨该租户所有 namespace 聚合**的——gateway Pod 也算。

A sandbox is more than its agent container: it also brings its own supervisor Pod and a workspace PVC. Measured, one
sandbox (with a PVC) raised tenant usage to `limits.memory=1536Mi / count/pods=2`. `scope: Tenant` makes the quota
**aggregate across all of that tenant's namespaces** — the gateway Pod counts too.

按这个算，3 个沙箱的场景至少要 `limits.memory ≥ 512Mi + 3×1Gi`。`capsule2/tenants.yaml`
已按实测重算，并把上面那段报错留在注释里。

By that arithmetic, a three-sandbox scenario needs at least `limits.memory ≥ 512Mi + 3×1Gi`. `capsule2/tenants.yaml` has
been recalculated from the measurements, with the quota error above kept in a comment.

---

<a id="c4"></a>
## 4. 对 POC2 文档本身的修订建议 / Recommended revisions to POC2 itself

| POC2 位置 / Location | 现状 / Current text | 应改成 / Should become |
|---|---|---|
| §4.3 | 只说 workspace chart 负责 SA/Role/RoleBinding/NetworkPolicy<br>Only says the workspace chart owns SA/Role/RoleBinding/NetworkPolicy | **补一步**：shared 模式还要把 `openshell-client-tls` 复制到租户 runtime ns(否则 supervisor 永远起不来)<br>**Add a step**: shared mode must also copy `openshell-client-tls` into the tenant runtime ns (otherwise the supervisor never starts) |
| §4.2/§4.3 顺序<br>§4.2/§4.3 order | 先 Gateway 后 workspace chart<br>Gateway first, then the workspace chart | **必须反过来**(或至少让 RBAC 先到位)，否则 Gateway CrashLoop：`sandboxes.agents.x-k8s.io is forbidden … in the namespace "tenant-a-runtime"`<br>**Must be reversed** (or at least ensure RBAC lands first), otherwise the Gateway CrashLoops: `sandboxes.agents.x-k8s.io is forbidden … in the namespace "tenant-a-runtime"` |
| §4.4 | `required_labels` 用 `openshell.ai/sandbox-attachable-workspace: "${workspace}"` | 语法可用(`${workspace}` 是整值替换)，但**必须同时有一个不含 `${workspace}` 的固定标签**，否则启动校验拒绝(`must include a shared approval label`)<br>The syntax works (`${workspace}` is a whole-value substitution), but there **must also be a fixed label without `${workspace}`**, otherwise startup validation rejects it (`must include a shared approval label`) |
| §6.1 | Dockerfile 里 `ARG` 写在 `FROM` 之前<br>`ARG` before `FROM` in the Dockerfile | **版本根本没锁上**：stage 里 `${PI_VERSION}` 展开为空，装的是 latest。`ARG` 必须在 `FROM` 之后<br>**The version is not pinned at all**: `${PI_VERSION}` expands empty in the stage and `latest` is installed. `ARG` must come after `FROM` |
| §6.1 | `USER node` + `ENV PI_CODING_AGENT_DIR` | 沙箱以 uid 10001 运行、镜像 ENV 不注入 → 需要运行期的可写 agent home<br>The sandbox runs as uid 10001 and image ENV is not injected → a writable agent home must be created at runtime |
| §6.2 | `pi install npm:pi-otel` 在运行期<br>`pi install npm:pi-otel` at runtime | 必须**构建期**装(运行期出不了网)；且手工拷扩展会缺依赖(`Cannot find module '@opentelemetry/api'`)，要用 Pi 自己的 installer<br>Must install **at build time** (no network at runtime); copying the extension by hand misses dependencies (`Cannot find module '@opentelemetry/api'`) — use Pi's own installer |
| §8.3 | `[openshell.gateway.otlp.ocsf] enabled = true` | v0.1.7 的 chart 只暴露 `ocsf_log`(JSONL 落盘)。**OTLP 形式的 OCSF 未验证**，文档要把这条标成待验证<br>The v0.1.7 chart exposes only `ocsf_log` (JSONL on disk). **OTLP-form OCSF was not verified**; the document should mark this as pending verification |
| §7.3 | "Tetragon 提供 eBPF 观测"<br>"Tetragon provides eBPF observability" | 要加前提：**宿主内核的 LSM 列表必须含 `bpf`**(`lsm=bpf`)，否则基于 lsm hook 的策略全部加载失败；另外 1.8.0 的 `kprobe_multi` 默认值会拒绝同符号重复/Overrides，需要 `--disable-kprobe-multi`<br>Add the precondition: **the host kernel's LSM list must include `bpf`** (`lsm=bpf`), otherwise every lsm-hook policy fails to load; also, 1.8.0's `kprobe_multi` default rejects duplicate symbols/Overrides, requiring `--disable-kprobe-multi` |
| §3.5 | "要求 Runtime 工作负载有资源 requests/limits"<br>"Runtime workloads must have resource requests/limits" | 要写明**这条在带 LimitRange default 的 ns 里永远不会触发**：Capsule 的 mutating webhook 在 Gatekeeper 之前就把值补上了。这是顺序决定的，不是规则写错<br>State that **this rule never fires in a namespace with LimitRange defaults**: Capsule's mutating webhook fills the values in before Gatekeeper sees them. This is a matter of ordering, not a wrong rule |
| §5.2 | 用 Kind 默认 storageClass 不行<br>Kind's default storageClass will not do | 已验证：要装 NFS + Subdir Provisioner。并且**同样的 RWX 声明放在 local-path 上会被 API 接受但停在 Pending**——§5.2 那句警告是对的，值得加一句"这就是它的表现"<br>Confirmed: install NFS + Subdir Provisioner. And **the same RWX claim on local-path is accepted by the API but stays Pending** — §5.2's warning is correct; add "this is what it looks like" |

---

<a id="c5"></a>
## 5. 这个模式离生产还差什么 / What this pattern still needs before production

按"必须解决 → 应该解决"排序：

Ordered from "must fix" to "should fix":

1. **租户之间的网络隔离不是平台能力**(见 §2 SEC-04/08)。现在"跨租户不通"是 OpenShell
   执行边界的副作用。要在平台层成立，必须补 Capsule `spec.networkPolicies` 或 Antrea
   ClusterNetworkPolicy(按 ns label)。POC2 §9 与 §11 里这是两件事，要分开写。
   ⚠️ **2026-11-10 更正(POC3)**: 两个 Tenant 已补上 `spec.networkPolicies`，同一条测试现在
   跨租户普通 Pod = `BLOCKED`、同租户正对照 = `REACHED`(用例 N-01..N-05)；可加性仍在
   (租户自建策略能放宽)。详见 `README.md` §5.4 与 §12。
   **Tenant-to-tenant network isolation is not a platform capability** (§2 SEC-04/08). Today "cross-tenant fails" is a
   side effect of the OpenShell execution boundary. For it to hold at the platform layer you must add Capsule
   `spec.networkPolicies` or an Antrea ClusterNetworkPolicy (by namespace label). POC2 §9 and §11 mix two different
   things; write them apart.
   ⚠️ **2026-11-10 更正 / corrected in POC3**: 两个 Tenant 已补上 `spec.networkPolicies`，同一条测试现在
   跨租户普通 Pod = `BLOCKED`、同租户正对照 = `REACHED`（用例 N-01..N-05）；NetworkPolicy 可加性仍在
   （租户自建策略能放宽）。详见 `README.md` §5.4 与 §12。
   Both tenants now carry `spec.networkPolicies`; the same test now yields `BLOCKED` cross-tenant and `REACHED` for
   the same-tenant positive control (cases N-01..N-05). Additivity remains (a tenant can widen it). See `README.md`
   §5.4 and §12.
2. **读写分权要两层都留**(§2 SEC-06/07)。OpenShell 策略(EACCES)与 Kubernetes 挂载(EROFS)是
   **两条独立**的强制链。只依赖一条，另一条配置漂移时就失效；报告里也要按 errno 说清是哪层。
   **Keep both layers for read/write separation** (§2 SEC-06/07). The OpenShell policy (EACCES) and the Kubernetes mount
   (EROFS) are **two independent** enforcement chains. Relying on one alone fails the moment the other drifts, and the
   report should name the layer by errno.
3. **每个沙箱占 2 个 Service、requests≈1.15Gi，`Completed` 仍占配额。** 最先撞到的配额是
   `count/services` 不是 `count/pods`(本轮实测 10/12 时新建沙箱只报错、不给原因)。配额要按
   沙箱数反算，并且清理必须是真 `sandbox delete`。
   **Each sandbox takes 2 Services and ~1.15Gi of requests, and a `Completed` one still counts.** The first quota you hit
   is `count/services`, not `count/pods` (at 10/12 a new sandbox just errors, with no reason given). Size quotas from
   the sandbox count, and cleanup has to be a real `sandbox delete`.
4. **OCSF 走 OTLP 已验证，但 chart 没暴露它**(§2 POC-09)。v0.1.7 的 values 只有 `ocsf_log`(JSONL)，
   OCSF over OTLP 要**直接写 gateway.toml**。生产上这条要么等上游 values，要么在交付清单里写明"手工 TOML +
   升级时要重新断言"(哨兵指标: `openshell_ocsf_otlp_exported_total`)。另外 OCSF 走 Collector 的 **logs**
   pipeline，日志管道的保留/采样策略要单独定。
   **OCSF over OTLP is verified, but the chart does not expose it** (§2 POC-09). The v0.1.7 values only offer
   `ocsf_log` (JSONL); OCSF over OTLP requires **writing gateway.toml directly**. In production either wait for upstream
   values or put "manual TOML, re-assert after upgrades" in the delivery checklist (sentinel metric:
   `openshell_ocsf_otlp_exported_total`). Also note OCSF flows through the Collector's **logs** pipeline, so log-pipeline
   retention and sampling need their own policy.
5. **观测后端的持久化与证据留存。** Jaeger all-in-one 内存存储在两轮里各丢过一次证据；
   本轮已改成双出口(集群内 Jaeger 供脚本断言、宿主 Tempo/Grafana 供演示)，但生产要换成
   带存储的后端，并且给 trace 设保留期。
   **Observability backend persistence and evidence retention.** Jaeger all-in-one's in-memory storage lost evidence once in
   each round; this round switched to dual export (in-cluster Jaeger for scripted assertions, host Tempo/Grafana for the
   demo), but production needs a backend with storage and a retention period for traces.
6. **Gateway 仍是单副本 + SQLite。** POC2 §1.3 把 HA 排除在 PoC 外是对的，但报告的
   "生产前必须解决"里要有：外部 PostgreSQL、Gateway 的证书轮转如何同步到 runtime ns 的
   client-TLS 副本(§3.1 那条平台步骤必须是**持续**的，不是一次性的)。
   **The Gateway is still a single replica on SQLite.** POC2 §1.3 rightly excludes HA from the PoC, but the report's
   "must fix before production" must include: external PostgreSQL, and how Gateway certificate rotation is synced to the
   client-TLS copy in the runtime ns (the platform step in §3.1 must be **continuous**, not one-off).
7. **Tetragon 的强制能力取决于宿主内核配置**，属于交付前提，要在开通检查里。
   **Tetragon's enforcement capability depends on host kernel configuration**; this is a delivery precondition and belongs
   in the provisioning checks.

---

<a id="c6"></a>
## 6. 怎么复现本轮 / How to reproduce this round

```bash
# 宿主 / Host: Ubuntu 24.04 / 内核 kernel 6.8.0-147 (有 BTF / has BTF, LSM 无 bpf / no bpf in LSM) / 48C / 94G
ssh root@192.168.5.190 'cd /root/poc2 && bash phases/NN-*.sh'

# 01-cluster 之后必须补 apiserver SAN(kind 的 kubeadmConfigPatches 里字段名是 certSANs，
# 写 extraSANs 会被**静默忽略**):
# After 01-cluster, the apiserver SAN must be added (in kind's kubeadmConfigPatches the field is certSANs;
# writing extraSANs is **silently ignored**):
ssh root@192.168.5.190 'cd /root/poc2 && SAN=192.168.5.190 bash kind/fix-apiserver-sans.sh'

# 顺序 / Order: 01→12。其中 10(观测栈 / observability stack)必须在 08(Gateway)之前装好，
# 否则 gateway 的 OTLP 第一屏全是失败，会被误读成"OpenShell 没配好"。
# Otherwise the Gateway's first OTLP screen is all failures and gets misread as "OpenShell is misconfigured".
```

外部可访问(kind 配置里 `apiServerAddress: 0.0.0.0` + `apiServerPort: 6443`)的完整条件见
`poc/kind/README-external-access.md`：**两个**必要条件——证书 SAN 要有宿主 IP，
NodePort 要用 `extraPortMappings` 显式发布。

The complete conditions for external access (`apiServerAddress: 0.0.0.0` + `apiServerPort: 6443` in the kind config) are
in `poc/kind/README-external-access.md`: **two** necessary conditions — the certificate SAN must include the host IP, and
NodePorts must be published explicitly with `extraPortMappings`.

### 已经补跑的部分 / Now completed

`phases/11-pi-scenario.sh`(§10 业务流程: git clone → 修改 → go test → 两个 Reviewer 并行只读)
与 `phases/13-security-matrix.sh`(SEC-04/06/07/08/12/**13**)**都已编写并跑过**，POC-04/10/11 与
SEC-04/06/07/08 的结论见上面 §2 的表。**13 号脚本现在能独立跑**(它会自己建 Reviewer，
因为 11 号脚本结束时会把它们删掉 —— 那是它 §7 的断言本身)。

SEC-12 的**数据面已经实测**(先前那句"没有再现"是**测法错了**，不是测不到 —— 见 §2 该行的几个坑)。
结论: 数据面**不** fail-closed、控制面**是**，两条都在 13 号脚本里可复现。
SEC-13 是本轮**新补**的一条(先前两份结论文档都漏了它，而 POC2 §11 有定义) —— 见 §2 该行与 13 号脚本的 SEC-13 一节。

`phases/11-pi-scenario.sh` (§10 business flow: git clone → modify → go test → two Reviewers reading in parallel,
read-only) and `phases/13-security-matrix.sh` (SEC-04/06/07/08/12/**13**) **have both been written and run**; their verdicts
are in the tables above. **Script 13 now runs standalone** — it creates its own Reviewers, because script 11 deletes
them at the end (that deletion is its own §7 assertion).

The SEC-12 **data plane is now measured**: the earlier "not reproducible" was a wrong method, not something
unmeasurable (see the traps listed in that §2 row). The result — the data plane does **not** fail closed, the control
plane does — is reproducible in script 13.
SEC-13 is **newly added** this round: both earlier conclusion documents omitted it even though POC2 §11 defines it. See
that §2 row and the SEC-13 section of script 13.
