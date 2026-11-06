# 总结：我们在做什么，为什么这么做，收益在哪

> 一页说明。要证据去 [`FINDINGS.md`](FINDINGS.md)，要动手去 [`DEMO.md`](DEMO.md)，
> 要录视频直接跑 [`../usage/03-agent-otel-demo.sh`](../usage/03-agent-otel-demo.sh)。

---

## 1. 在做什么

给**每个租户**一个 AI agent 沙箱，满足四件事，而且这四件事是同一条链：

```
开通租户 → agent 跑起来 → 越界当场被拦 → 事后能查（还能查得清清楚楚）
```

不是四个产品拼在一起。四个开源组件各管一段，中间只接一根线：

| 层 | 组件 | 它只管这一件事 |
|---|---|---|
| 租户合同 | Capsule | 命名空间归谁、配额上限、策略自动下发 |
| 沙箱本体 | agent-sandbox（SIG Apps） | 稳定身份、持久工作盘、生命周期、预热池 |
| 行为边界 | OpenShell | agent 能碰哪些文件/域名/凭据，以及**为什么**放行 |
| 真相与拦截 | Tetragon（eBPF） | 内核里真实发生了什么，并能当场拒绝 |

`openshell sandbox create` 一条命令，落到一个 ns 里就是：Sandbox CR + agent 容器（非 root，uid 10001）+ 配对的 supervisor；
上面叠着 Capsule 与 OpenShell 各自下发的网络策略，以及按租户标签选中的内核策略。

---

## 2. 为什么这么做

**① 这条链是官方设计路径，不是硬凑。**
OpenShell 的文档写得很直接：*"OpenShell uses the Agent Sandbox Kubernetes SIG project to provision sandbox pods. Install the Agent Sandbox controller and its CRDs on your cluster before installing the OpenShell Helm chart."*
（`docs.nvidia.com/openshell/latest/kubernetes/setup`）也就是说 OpenShell 创建 `Sandbox` CR、由 agent-sandbox 控制器落地 Pod，是它自己的实现方式，不是我们接的胶水。

我们要接的只有"命名空间由谁决定"这一件事：OpenShell 用 `workspace_mode = operator`，按标签发现平台预先建好的 ns。
**这一根线本身只有两处配置** —— 租户侧 `namespaceOptions.additionalMetadata.labels` 打一个标签，控制面 `operatorNamespaceLabel` 按这个标签认。
（开通一个租户仍然是 5 个动作，见 `poc/usage/01-onboard-tenant.sh`；这里说的是"接上租户体系"这一步的工程量。）

**② 每层只做它那一层才做得到的事。**
这一点不是设计理念，是实测出来的（§3 收益二 的对照表，以及 §4 里几条真实边界）。三层的盲区正好互补，所以少任何一层都会漏一整类越界。

**③ agent 开发者不需要为平台写任何代码。**
agent 只发标准 OTLP、只用标准 SDK；平台只看内核。两边都不认识对方。这是能不能推广出去的关键 —— 平台不能要求每个 agent 都用某个框架。

---

## 3. 这个组合的收益

### 收益一：租户身份贯穿始终，不需要映射表

同一个键 `projectcapsule.dev/tenant=<tenant>` 出现在三处：Capsule 的配额与策略下发、OpenShell 的 namespace 发现与审计标签、内核事件里的 pod label。实测过用这一个 selector 选中某租户全部 ns 的策略，也实测过按这个维度聚合内核事件。

所以"这个租户花了多少 / 试了哪些不该试的地址 / 谁改了它的策略"这三个问题，都能在同一个维度上聚合。平台不需要维护"agent ↔ 租户 ↔ 容器"的对照表 —— 那类表一多就一定会腐化。

### 收益二：每个控制点能做什么是清楚的，盲区也是清楚的

| 想做这件事 | 谁能做 | 谁做不到 |
|---|---|---|
| "这个租户最多用 2 CPU，超了就拒" | Capsule 配额 | 其余三层都不管这件事 |
| "这个 agent 只准连这个域名，而且只准读" | OpenShell L7 策略（会返回拒绝**理由**，可审计、可热更新） | 按 IP 直连**不经过它** |
| "这个进程不许连这个地址" | Tetragon（内核层，按进程+地址判定） | 网络策略不知道"是谁发起的" |
| "agent 试过连哪儿"（包括没连上的） | 只有 Tetragon | 网络层只知道成不成功 |

未放行的连接，NetworkPolicy 是**静默丢包**（实测到 40s 仍未返回，失败时间取决于 agent 自己的超时）；内核层是 **0.00–0.08s 返回 EPERM**。对 agent 来说，快速失败远比挂起好处理 —— 它会立刻改道。

### 收益三：可观测性不用改 agent 就能拿到，而且两边对得上

一次真实运行，两个互不相干的视角：

```
[trace] tool.run_shell  {"cmd": "cat /etc/hostname"}
[内核 ] cat             /etc/hostname              <- 对上
```

同一个 pod、同一个 uid、同一条命令行。trace 里有模型调用、token 计数、每次工具执行与退出码；内核记录里有每次 exec、每个打开的敏感路径、每次出网尝试。没有一行"对接"代码 —— agent 用的是 OpenTelemetry 官方 SDK 和 Anthropic SDK，平台用的是 eBPF。

顺带一件有用的事：把 trace id 放进命令行参数，内核记录里就会原样出现那个 id（`arguments: "tid=…"`）。不需要任何厂商集成。

### 收益四：策略是版本化、可回滚的，改边界不用重启动 agent

同一个运行中的沙箱上：OpenShell 策略 v2→v4，每次带 hash，`Status: Effective`；Tetragon 策略装/撤，`pip --version` 立刻在 `Operation not permitted` 和 `pip 25.0.1` 之间来回。不重启沙箱、不重建镜像、不改 agent。

### 收益五：延迟是可以被量化的

数字（第一轮 2026-11-03 实测，本轮未重测 —— 预热池要重建才有数）：
预热池认领到就绪 **0.25s**；冷启动 0.92s（镜像已在节点）/ 15.98s（要拉 20MB 镜像）。注意一个尚未解决的取舍：从预热池认领出来的沙箱**不带** OpenShell supervisor 与凭据注入，
所以"最低延迟"与"有 L7 策略"目前二选一（`FINDINGS.md` §4）。这里想说的是：成本被算清楚了 —— 能算清楚才谈优化。

---

## 4. 这个组合现在真实的边界（不是缺陷清单，是要如实告诉别人的形状）

1. **一个沙箱 = 两个计入配额的容器**：agent + 配对的 supervisor（supervisor 由 LimitRange 兜到 500m/512Mi）。做容量规划时，每沙箱成本约是"agent 的两倍"。
2. **`binaries` 只在 L7 规则上参与判定。** 一条没有 `protocol` 的 L4 规则里 `binaries` 只写 `/bin/tar`，`python3.12` 照样连得过去。"哪个进程连哪个地址"这类边界只能由内核层承担。
3. **"按参数强制"当前在这条链上做不到**（Tetragon 1.8.0 上实测）。按可执行文件建白名单有固有边界：agent 被 `pip install` 拒了（rc 126），会换 `python3 -m pip` 成功（rc 0）。
   内核层**看得到它换了路** —— 被拒那次有 `process_lsm` 记录，成功那次是 `-m pip install requests` 的 exec 记录；但拦不住，因为相关钩子上没有参数可匹配（见 FINDINGS §R2.2）。
   一个排查上的注意：LSM 记录里的 `process.binary/arguments` 是**发起方**（那个 `sh -c "pip …"`），不是被拒的目标路径；要按目标路径检索得靠 kprobe 侧的 `sys_execve`。
4. **沙箱 DNS 到边界的这一段仍未通**（`FINDINGS.md` §R2.4 已把变量分离干净：L3/L4 补齐后域名解析仍超时，缺的一环不在网络策略层）。后果：L7 出网策略拿不到官方文档里那种"代理 403"的行为，本轮 demo 因此用 IP 字面量。**这是这条链目前最大的一个未解项。**
5. **隔离强度不是 hypervisor 级。** 现在是 非 root + seccomp + drop ALL caps + 网络策略 + supervisor。跑真正不可信的 LLM 生成代码之前，要上 gVisor / Kata。
   而按租户限制 runtimeClass 这一项**不能只依赖 Capsule**：第一轮（2026-11-03）给 acme 设了 `runtimeClasses.allowed: [gvisor]`，用 tenant owner 建 `runtimeClassName: kata-containers` 的 Pod **仍被接受**，到 kubelet 才失败；当时该项标的是"未定论"（`matchLabels` 形式的测试超时）。**本轮没有重测这一项** —— 上 gVisor/Kata 之前要先把这条确认掉，必要时自己补一层 CEL/Kyverno。
6. **一条容易误判成"漏采"的观察（其实是分层正确）。** `mount()`、以 root 运行这类"能力型越权"，在系统调用进内核之前就被 seccomp + drop ALL caps 挡住了，所以内核层根本看不到它们。
   这不是监控缺口：本来就不该靠策略去挡的事，挡在更早的层上更便宜也更可靠。策略只补"挡不住但可疑"的行为。

---

## 5. 一句话

**租户合同、沙箱本体、行为边界、内核真相 —— 四段各管一段，靠同一个租户标签串成一条链。**
收益是：平台能管（配额、边界、可回滚的策略）、能查（内核级真相，包括没成功的尝试）；
agent 开发者不用为平台写一行代码。
代价是：每个沙箱除 agent 外还有一个配对的 supervisor，它也计入租户配额（容量要按这个算）；
各层都有自己的能力边界，其中"沙箱 DNS 到边界"这一段还没打通。
