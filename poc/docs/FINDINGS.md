# 多租户 AI Sandbox POC — 实测结论

> 证据附录：第一轮逐项验证、报错原文与踩坑记录。
> 结论摘要见 [index.html](index.html)（看图版）/ [SUMMARY.md](SUMMARY.md)（文字版）。

日期: 2026-11-03 ｜ 环境: macOS + Docker Desktop 29.2.1(VM kernel 6.12.72-linuxkit, 8C/8G) ｜ kind v0.33.0 × 2, K8s v1.37.0

## 0. 结论

三者不是"拼装"，而是有天然的分层依赖，可以直接组成一个多租户 AI sandbox 平台：

| 层 | 组件 | 职责 | 版本 |
|---|---|---|---|
| 租户契约 | **Capsule** | 谁拥有什么、配额上限、命名空间生命周期、策略下发 | 0.15.2 |
| 工作负载编排 | **agent-sandbox** (SIG Apps) | Sandbox CR: 稳定身份 + 持久存储 + 生命周期(含休眠/预热池) | v1.0.9 |
| 策略与网络边界 | **OpenShell** | agent 能碰什么文件/网络/凭据，内核级强制 + 形式化验证策略变更 | 0.1.4 (chart 0.1.4) |
| 可观测与运行时强制 | **Tetragon** | eBPF: agent 行为的独立真相 + 内核层拦截 | 1.8.0 |

关键事实（来自 OpenShell 官方文档，非推断）: **OpenShell 的 Kubernetes compute driver 本身就构建在 agent-sandbox 之上** —— 它创建 `Sandbox` CR 并由 agent-sandbox 控制器落地 Pod。所以"用这 3 个项目"是官方设计路径。

## 1. 核心粘合点: `workspace_mode = "operator"`

OpenShell 的 K8s driver 有三种 workspace→namespace 映射:

- `shared`(默认): 所有 sandbox 落在一个 ns —— 隔离最弱
- `managed`: OpenShell 自己按 workspace 建 ns
- **`operator`: 每个 workspace 映射到"平台预先建好、按 label selector 发现的 ns"** ← 这就是 Capsule 的位置

实测打通:
```
Capsule Tenant(labels: openshell.ai/workspace=true)
  → tenant owner 建 ns → Capsule webhook 注入标签/ResourceQuota/LimitRange/NetworkPolicy
  → OpenShell driver 日志: "operator namespace allowlist replaced from full relist total=2"
  → openshell sandbox create --workspace acme
  → acme ns 出现: Sandbox CR(agent-sandbox) + workload Pod + os-supervisor Pod
```
Pod 上同时带 `capsule.clastix.io/tenant=acme`(Capsule 注入) 与 `openshell.ai/sandbox-workspace=acme`(OpenShell)。
**租户身份贯穿三层，是这一组合最有价值的性质。**

## 2. 已验证的能力

| 验证项 | 结果 |
|---|---|
| 端到端创建 agent sandbox | ✅ `openshell sandbox create` → agent 执行命令，非 root(UID 10001) |
| Capsule 配额真实拦截 | ✅ `pods "overquota-2" is forbidden: exceeded quota: capsule-globex-0` |
| 配额释放 | ✅ 删除 sandbox 后 `status.used` 回落 |
| 运行时隔离(强) | ✅ OpenShell 三层 NetworkPolicy 叠加: agent 连 kube-apiserver / gateway 均超时，只保留到 supervisor 的边界端口 5500；DNS 由本地解析器接管 |
| 运行时隔离(弱/CNI) | ✅ kindnet 执行 NetworkPolicy(满足 OpenShell 硬前提)。⚠️ 注意: 租户级 ns-wide egress 策略与 workload 的 `podSelector` NP 是**按 pod 取并集**，ns-wide 策略会把 egress 扩大到全部 pod —— 见 §4 风险 |
| 预热池 vs 冷启动 | ✅ warm claim **0.25s** / 冷启动(镜像已在节点) **0.92s** / 冷启动(需拉镜像) **15.98s** |
| Tetragon 观测 agent | ✅ `PROCESS_EXEC/EXIT/KPROBE`，带 `namespace=acme, pod=poc-acme-1, binary=/bin/sleep` 等 K8s 身份 |
| Tetragon 运行时强制 | ✅ `exec /bin/sh: operation not permitted`，且 python 不受影响(可精确到单个可执行文件) |
| 按租户下发安全策略 | ✅ `TracingPolicyNamespaced` / cluster-scoped `TracingPolicy` 用 `projectcapsule.dev/tenant: acme` 选择 |
| 策略自动化(单一来源) | ✅ Capsule `GlobalTenantResource` 自动把 Tetragon 策略下发进租户 ns(`gtr ... READY=True`) |
| 跨集群可观测 | ✅ plane-b 的 Prometheus 抓取 plane-a 的 Capsule / Tetragon / OpenShell 三处指标，全部 `up` |
| 租户契约可移植 | ✅ 同一 `tenants.yaml` 在 plane-b 复现完全相同的标签与配额 |

## 3. 实测踩到的坑(全部已修，写进 manifests 注释)

1. **Capsule 0.15 的 Tenant schema 大改**: `namespaces` / `quotas` / `quotaScopedLimitRanges` / `forceNamespaceSuffix` 等字段已不存在；`namespaceOptions.maxNamespaces` → `quota`(int32)。`resourceQuotas`/`limitRanges`/`networkPolicies`/`additionalMetadata` 标记 deprecated，迁移方向是 `rules` 与 `TenantReplication`/`GlobalTenantResource`。
2. **Capsule 0.15 不再按 `spec.namespaces` 自动建 ns**: 由 tenant owner 创建，Capsule 通过 webhook 注入归属。需要注册 `TenantOwner` 或让请求带 `projectcapsule.dev` 组，否则 `alice` 连 `create ns` 的权限都没有(默认 owner 只拿到 `admin` + `capsule-namespace-deleter`，不含 `capsule-namespace-provisioner`)。
3. **`sandboxNamespace` 在 operator 模式下不能指向租户 ns**: 它同时是 gateway Secret(如 `openshell-client-tls`)的复制源；指错会得到 `Secret openshell-client-tls does not exist in source namespace acme`。留空(= release ns)。
4. **operator 模式必须每个租户 ns 装 `openshell-workspace` chart**: 该 Role 是 gateway 在该 ns 内唯一的 Secret 权限来源。
5. **chart 版本看起来"倒退"**: `docs.nvidia.com/openshell/latest` 讲 v0.1.6，而 GHCR tag 列表首页最高是 `0.0.42` —— 因为 registry 分页。真实最新稳定是 `0.1.4`。**GHCR 取 tag 必须分页拉全再排序**。
6. **Tetragon v1.8 schema 变了**: 不是 `hooks`/`matchers`，而是 `kprobes: [{call, syscall, args, selectors}]`；LSM 用 `lsmhooks[].hook`(不是 `call`)；`args[].return` 不存在(用 `returnCopy`)；`resolve: "bprm->filename"` 会报 `attribute "bprm->filename" not found in structure "linux_binprm"`。
7. **`bprm_check_security` 上匹配"将被执行的目标"必须用 `matchArgs`(index 0)**，不能用 `matchBinaries`(那是调用者)。
8. **路径匹配针对解析后的真实可执行文件**: Alpine 里 `/bin/sleep → /bin/busybox`，按 `/bin/sleep` 写策略永不命中。→ 平台需要一条规范: 策略按镜像形态(是否 busybox/symlink)表达，或用 digest 固定的运行时镜像。
9. **warm pool 会吃掉租户配额**: template 不写 `resources` 时 Capsule LimitRange 的 default 会被补上，实际占用 = `replicas × default`。池太大时 agent-sandbox 控制器会被配额拒绝(`exceeded quota: capsule-acme-0`)——行为正确(租户边界)，但**池容量必须纳入租户容量规划**，且 template 必须显式声明 resources。
10. **`SandboxTemplate` 不是独立可创建对象**(POC 里对已存在 template 的 update 被拒)，改 template 要重建 pool。
11. **YAML 多行脚本必须用块标量**，否则 `command: [...,"import time\nwhile..."]` 会被折行成语法错误(踩过一次)。
12. **Capsule 指标需要 `serviceMonitor` 或手工 NodePort 暴露**；`prometheus-community` 的 `extraScrapeConfigs` 要 `--set-file`(传布尔会类型错误)，且改 ConfigMap 后老 pod 不会自动 reload(需 rollout)。

## 4. 未验证 / 风险(需要下一步处理)

- **`runtimeClasses` 白名单未拦住**: 给 acme 设 `runtimeClasses.allowed: [gvisor]`，用 tenant owner 身份创建 `runtimeClassName: kata-containers`(集群中存在)的 Pod **被接受了**，直到 kubelet 侧才失败。Capsule 的 `pods.validating` webhook 存在，但这条规则没有生效(`matchLabels` 形式测试超时，未定论)。**→ 若要按租户限制 microVM/gVisor，暂不能只依赖 Capsule 这一项**，需自研 CEL ValidatingPolicy/Kyverno 补一层，或向上游确认。
- **NetworkPolicy 的并集语义**: ns-wide 的 Capsule egress 策略会让 sandbox workload 也能直连 kube-system:53，绕过 OpenShell supervisor。生产上应把租户级默认策略限定到"非 sandbox" pod selector，或把 DNS 也纳入受控边界。
- **没有 gVisor/Kata**: kind + Docker Desktop 上没有现成的 `kindest/node` gVisor 镜像；本 POC 的隔离强度来自 OpenShell supervisor + NetworkPolicy + 非 root + user-namespaces 能力，**不是 hypervisor 级**。真正的"不可信 LLM 代码"场景需要 runOnGvisor 这类运行时。
- **agent-sandbox 与 OpenShell 的 sandbox 是两条独立路径**: 预热池认领出来的 sandbox 不带 OpenShell supervisor/policy(无网络边界、无凭据注入)。要么只用 OpenShell 路径并接受其创建延迟，要么需要 OpenShell 支持从池认领(`resource_admission`/`allow_driver_config` 目前不提供该语义)。
- **OpenShell 是单集群**: K8s driver 用 in-cluster client，没有 kubeconfig/多集群选项。多集群只能靠"每集群一套 gateway"(联邦)或按租户分片。
- **HA**: 默认 StatefulSet + 单副本 + SQLite 只适合 POC。生产要 `workload.kind=deployment` + 外部 PostgreSQL(且 PostgreSQL 自身另做 HA)。
- **Capsule 0.15 声明的最低 K8s 是 v1.36**；本 POC 用 1.37 可用，但生产选版本时要把这个约束和 agent-sandbox/OpenShell 的支持矩阵放在一起看。

## 5. 建议的目标形态

1. **控制面/数据面分离**: 每个租户集群(plane-a 型)只放 Capsule + agent-sandbox + Tetragon + 可选 per-cluster gateway；观测/Golden signals 汇总到平台集群(plane-b 型)。已在 POC 里跑通跨集群抓取。
2. **租户契约即代码**: `Tenant` + `TenantOwner` + `GlobalTenantResource` 一套 YAML 就是"开通一个租户"的全部动作。已在两个集群验证可移植。
3. **策略分层**: Capsule 定边界(配额/可申请的 storageClass/网络护栏) → OpenShell 定 agent 能做什么(文件/网络/凭据，带形式化验证的变更审批) → Tetragon 定"实际做了什么"并在内核层拦截越界。三者都用同一个租户标签作为锚点。
4. **容量规划要显式计入预热池**，并把池大小与租户配额绑定(池是租户的，不是集群的)。
5. 迁移方向注意: Capsule 的 `resourceQuotas`/`limitRanges`/`networkPolicies` 已 deprecated，新设计优先用 `rules` + `*TenantResource` 复机制。

---

# 第二轮 (2026-11-06) —— agent 侧 OTel + 运行时安全加深

> 这一轮的目标是"给外部的人演示：怎么开发 agent，以及 agent 的 runtime 安全性/可观测性怎么被平台看到"。
> 做法：一个真实调模型的 agent(Python，标准 OTel，无框架)跑进 OpenShell 沙箱，
> 同时看 Jaeger 里的 trace 和 Tetragon 里的内核记录。
> 产物：`poc/agent/`(agent.py · Dockerfile · policy.yaml · egress-allow.yaml)、
> `poc/observability/trace-backend.yaml`、`poc/usage/03-agent-otel-demo.sh`(+ `03-demo-views.py`)、
> `poc/tetragon/values.yaml`、`poc/tetragon/experiments/60-enforce-args-ATTEMPT.yaml`。

## R2.0 一句话结论

**能演示，而且不需要任何"对接"代码。** agent 发的是标准 OTLP，平台看的是内核；
两边的记录天然对得上 —— 同一个 pod、同一个 uid 10001、同一条命令行。
同时这一轮暴露出两处**真实边界**(见 R2.3 / R2.4)，都不是配置失误，是机制本身的形状。

> **对第一轮 §"6s 超时" 的更正(2026-11-06 复测)**: 那个 6s 在当前配置(kindnet + 容器内 Python `create_connection`)下**复现不出来** ——
> 未放行的目标一直是静默丢包，测到 40s 仍没返回。第一轮观察到的 6s 很可能是当时客户端/栈的超时设置，
> 不是 kindnet 的丢包行为。结论方向不变(**内核层快速失败远优于挂起**)，但**具体倍数不要引用**。

## R2.1 已实测通过

| 项 | 结果 |
|---|---|
| agent 进沙箱端到端 | ✅ `openshell sandbox create --from aisanbox-agent:0.3` → 真模型调用 + 真工具执行，agent 以 uid 10001 运行 |
| OTel 插桩 | ✅ 一个 `agent.run` 根 span，下挂 SDK 自带的 `anthropic.messages.create`(带 `gen_ai.usage.input/output_tokens`) 与自写的 `tool.run_shell`(带 argv 与 exit code) |
| 观测后端在集群内 | ✅ Jaeger 2.19 作为 plane-a 内 Deployment(`observability` ns)，NodePort 31681/31682；沙箱直连 Service ClusterIP 出 trace |
| 两侧对照 | ✅ trace 里 `{"cmd": "cat /etc/hostname"}` ⇄ 内核 `sh -c "cat /etc/hostname"` + `cat /etc/hostname`，uid 一致、参数一致(`03-demo-views.py join` 自动对齐并标 "<- 对上") |
| 内核层快速拒绝(运行时强制) | ✅ 同进程内连 `8.8.8.8:53` / `169.254.169.254:80` → `PermissionError` **0.00–0.08s**；对照组(已放行端点) 0.01s 通过。对比: 只靠 NetworkPolicy 拦同类目标是**静默丢包**，实测到 **40s 仍未返回**(失败时间取决于 agent 自己的超时) |
| 策略热更新 | ✅ 同一沙箱内 policy v1→v4，`Status: Effective`，不重启沙箱 |
| 用 trace id 关联内核记录 | ✅ **可行做法是把 id 放进 argv**：内核 `arguments` 字段原样导出(`arguments: "tid=6cb99dc6…"`)，可直接和 trace 对齐 |
| Capsule 配额真实拦截 | ✅ 第二次并发建沙箱被拒: `pods "probe-x" is forbidden: exceeded quota: capsule-acme-0, requested: limits.memory=768Mi, used: 1792Mi, limited: 2Gi` |

## R2.2 Tetragon 1.8 的"更深"能力：哪些是真可用的

先把结论摆前面：**默认安装缺三个开关**，缺了就是加载失败或静默少能力；另外两个"看起来支持"的能力实际不可用。

需要打开(chart 里前三个有 values，后两个只能走 `extraArgs`)：

```yaml
# poc/tetragon/values.yaml
tetragon:
  enableProcessCred: true
  enableProcessNs: true
  processAncestors: {enabled: base,kprobe,lsm}   # helm --set 要写成 base\,kprobe\,lsm
  extraArgs:
    parents-map-enabled: ""
```

实测可用(加载 + 命中)：

| 能力 | 用途 | 注意 |
|---|---|---|
| `matchParentBinaries` | 按"谁启动的谁"归因 | **必须** `--parents-map-enabled`，否则报 `matchParentBinaries selector can be used only with parents map enabled`。`maxItems: 1` |
| `matchCmdArgs` (kprobe) | 按参数拦，例如 `python3 -m pip` | `index` 从 0 开始且**不含 argv[0]**(argv[0] 由 binary 表示)。同一 selector 内与 matchArgs 是 AND |
| `ip_output` + `Protocol/DPort/NotDAddr` | 把 DNS 钉在受控解析器上 | 上游 example 写法可用；UDP 也能拿到 |
| `security_inode_follow_link` / `sys_linkat` | 软/硬链接逃逸到工作区外 | `type: dentry` 可解析 |
| `lsmhooks file_open` | 打开即拒(比 openat 更早的控制点) | 可用 |
| `security_bprm_creds_from_file` | 拿"最终 ELF"，绕开 busybox 符号链接 | 可用 |
| `lists` + `enforcers` + `NotifyEnforcer` | 按进程做连接/系统调用强制 | ⚠️ 危险：范围一大就把整个 pod 的正常 syscall 也拒了(实测把 `dup2` 拒掉，pod 里所有 shell 立刻坏) —— 见 R2.5 |
| `rateLimit` + `rateLimitScope` | 把高噪声策略变成可用的检测原语 | scope 只接受 `thread`/`process`/`global`(小写)。写 `Process` 或 `CombinedWithSelectors` 会加载失败 |
| `selectorsMacros` | 复用一组 selector | 是 **map**(名字 → selector)，不是带 `name` 的数组 |
| `matchCEL` | 复杂条件表达式 | 只对**定宽整数**参数可用(`int32/int64/uint32/uint64`，字面量要写成 `0u` 这类)。`string/char_buf/const_buf/size_t` 在 CEL 里是 `unsupported` 类型，比较直接编译失败 |
| `GetUrl` / `DnsLookup` / `UpdateState`+`matchStates` | 富化 / 跨事件状态 | 字段名与直觉不同: `argUrl`(不是 `argURL`)；`matchStates` 用 `value`(不是 `values`)；state 只有 `name` |

**不可用(实测)：**

* `enable-process-environment-variables`：开(且配了 `filter-environment-variables=TRACEPARENT`)之后，`PROCESS_EXEC` 里**没有** `process_env` 字段 —— `grep -c process_env /var/log/tetragon/tetragon.log → 0`，而启动 config 里确实是 true。1.8.0 不导出。→ 用 argv 携带 id 代替。
* LSM 事件里的 `process.binary` / `arguments` 是**发起方**，不是被拒的目标。
  实测：`sh -c "pip --version"` 被策略拒之后，`process_lsm` 记录里 `binary=/bin/sh`、`arguments=-c "pip --version"`，
  而被拒的 `/usr/local/bin/pip3` 这个路径**不在该记录里**。
  含义：按"谁试图做什么"排查是对的；要按**目标可执行文件路径**检索，得靠 kprobe `sys_execve` 的 `args[0]`
  （那是调用者**请求**的路径，不是解析后的真实文件 —— 见第一轮 §3 关于 busybox 的坑）。
  另注：`process_lsm` 事件的 `msg` 与 `policy[]` 字段在这个版本/配置下为空，别用它们做归因。
* `matchCmdArgs` 放在 **lsmhooks** 上：策略加载无报错，但**不产生事件**。之前一次"命中 1 次"是我 grep 命令行自身被内核记录造成的假阳性。原因可解释(内核时序)：`bprm_check_security` 早于 argv 被写进 `bprm`。→ "按参数强制"目前只能在 kprobe 侧**观测**；要强制就改容器安全上下文，或接受"二进制白名单 + agent 会找旁路"是现实。

## R2.3 真实边界①：`binaries` 只在 L7 上生效

对照实验(同一个沙箱、同一条规则、只有一个变量)：

```
规则: endpoints: [{host: 10.96.80.216, port: 18080}]        binaries: [{path: /bin/tar}]
      → python3.12 连过去: ALLOWED           (L4 规则不做 binary 判定)
规则: endpoints: [{host: 10.96.80.216, port: 18080,
                  protocol: rest, access: read-only, enforcement: enforce}]
      → python3.12 走 HTTP: 仍然通过         (L7 判定在"请求"上，不在"这个 binary 能不能连")
```

含义：**OpenShell 的网络边界是"按域名/按请求"的控制点，不是按进程的控制点。**
`binaries` 是 L7 规则里用来定位"哪些请求属于哪个 binary"的标签，
它**不会**把一条 L4 直连拒掉。想把"哪个进程连哪个地址"变成硬边界，就是 Tetragon 那一层
(R2.1 里 0.01s 的 `PermissionError` 就是它)。这两层不是冗余，是互补 —— 这也正是本轮最想演示的东西。

顺带两个 CLI 坑(已踩)：
* `openshell policy update --binary 'path=/usr/…'` 会把字面量 `path=` 写进策略，得到 `binaries: [{path: "path=/usr/…"}]`。**传裸路径** `--binary /usr/local/bin/python3.12`。
* `--add-endpoint` 的 `protocol: tcp` 不能带 access/enforcement(`full:tcp` 会报错)；一条命令里 `--rule-name` 只能出现一次。

## R2.4 真实边界②：沙箱 DNS 走不通 —— 第一轮 §06 的准确定位(仍未解)

把变量分离干净后，这一条现在可以说清楚了：

```
沙箱内 resolv.conf      -> nameserver 127.0.0.53 (本地 stub)
stub 的上游             -> 需要到 supervisor 的 policy DNS
但没有任何 NetworkPolicy 放行 workload -> supervisor   ⇒ 所有查询超时(gaierror)
```

* `openshell-sandbox-workloads` 的 `policyTypes: [Ingress, Egress]` 里 **egress 是空的** ——
  即这条策略对"允许出网"贡献 0；沙箱实际 egress = `capsule-<tenant>-0`(只到 kube-system:53) ∪ 其它。
  连**自己配对的 supervisor** 都不在允许集合里(:53/:5500/:5501 全超时)。
* 补上 `poc/agent/egress-allow.yaml`(workload→supervisor 的 53/5500/5501)后，DNS **仍然**超时。
  所以链路还差一环(不在 NetworkPolicy 层)，未定位。
* 期间会看到边界的结构化拒绝：`OCSF NET:REFUSE [MED] DENIED host.docker.internal [reason:policy_dns_trusted_gateway_unavailable]`
  —— 这条 reason 本身就是有用的信号：**它告诉你被拒是"名字不在策略里"，而不是"网络不通"**。
* 影响：`protocol: rest` 这类 L7 策略拿不到官方教程里的 `403 from proxy after CONNECT`；
  本轮 demo 因此改用 **IP 字面量**端点(不经过策略 DNS)。这不是绕过问题，是把问题标出来：
  **要让 L7 出网策略真正生效，必须先修沙箱到 supervisor 的解析路径。**
* 另一个独立事实：`169.254.169.254` 与 loopback/link-local 是 OpenShell 网络策略**永远不允许**的目标
  (文档明确)，想禁云元数据不必写策略；写 `host.openshell.internal` 才能在边界内访问网关主机上的服务。

## R2.5 踩到的坑(第二轮)

1. **自建策略把整个 pod 废掉**：`lists`+`enforcers`+`NotifyEnforcer` 挂在 `sys_dup/dup2/dup3` 上，
   于是 pod 内所有进程 `dup2(10,2): Operation not permitted` 刷屏，沙箱"起不来/一执行就死"。
   排查花了一轮，因为症状看起来像策略或镜像问题。**教训：作用域先收到最小(单 pod + 单 syscall)再放大。**
2. **`--policy` 里写 `filesystem_policy` 要写全**：不写时 OpenShell 会补一份 baseline
   (`openshell policy get <sb> --base` 可见: `/bin /usr /lib /proc /dev/urandom /etc /var/log` 只读，`/tmp /dev/null` 读写)。
   脚本别放在 baseline 之外的目录 —— 本轮曾把 agent 放到 `/agent`，一度误判为"baseline 不含 /bin"，
   实际那次 EPERM 是坑 1 的 `dup` 策略造成的。**误判来源要写下来。**
3. **一个 OpenShell 沙箱 = 两个计入配额的容器**：agent + 配对的 supervisor
   (supervisor 由 Capsule LimitRange 兜到 500m/512Mi)。租户配额按 `count/pods`/`limits.*` 算，
   所以**每沙箱实际成本约是"agent 的两倍"**。demo 脚本现在先打印 used/hard 再建沙箱。
4. `default` 镜像 `nvcr.io/nvidia/base/ubuntu:24.04` **没有 python**；不带 `--from` 建沙箱时
   supervisor 报 `failed to spawn sandbox entrypoint process 'python3'`。要跑 Python agent 就显式 `--from`。
5. 内存给小了(256–512Mi)会被 OOM 干掉，表现为 `exec` 返回 137 且 supervisor 重启。
   一个装好 anthropic+OTel SDK 的 Python agent 用 `--cpu 300m --memory 512Mi` 起步比较稳。
6. kind 里加 `observability` ns 后，需要 `kind load docker-image` 把 Jaeger 镜像塞进节点；
   Docker Hub 有时不可达，但 `cr.jaegertracing.io` 可达(127MB)。Jaeger 2.19 同时收 OTLP/HTTP(4318)与 gRPC(4317)。
7. `set -u` + 中文文案：`note "...tenant=$TENANT，"` 里 bash 会把全角逗号的首字节吃进变量名，报
   `TENAN: unbound variable`。**变量后面紧跟非 ASCII 字符时要写 `${TENANT}`。**
8. Tetragon 的 `--policy-names` 过滤在 `tetra getevents` 上不可靠(会返回空)，别用它判断"策略有没有命中"；
   用 `-o json` + 按 pod/uid 过滤，或直接看节点上的 `tetragon.log`。
9. 数策略"命中几次"时小心自匹配：`grep "某 message"` 的那条 shell 命令本身会被内核记录，
   于是出现假阳性(本轮就把它当成"策略生效"过)。

## R2.6 现在能演示什么(录视频脚本)

`bash poc/usage/03-agent-otel-demo.sh`(`TUTOR_MODE=1` 每拍停顿)。四拍，全部实测：

1. **快速失败**：agent 试 `8.8.8.8:53` / `169.254.169.254:80` → 内核 0.01s/0.07s 拒，
   对照组(已放行端点)通过；同时说明 NetworkPolicy 要 6s。
2. **热更新**：加/删一条出网例外，policy v2→v4，`Status: Effective`，沙箱不重启；版本与 hash 可审计。
3. **两侧对照**：trace(`agent.run` / `anthropic.messages.create` / `tool.run_shell`)
   ⇄ 内核(`🚀 process acme/otel-agent /bin/cat /etc/hostname`)，`join` 视图自动标注对上项。
4. **分层互补**：按名字访问才经过策略 DNS(被拒带 reason)；按 IP 直连不经过它 —— 由内核层补上。
   反过来，"这个域名解析到哪"只有边界层看得到。两层都要。

一个额外素材(不是脚本内置)：给 agent 的任务是"装 requests 包"时，
`pip install requests` 被基线策略拒(exit 126)，agent 自己换路 `python3 -m pip install requests` 成功。
这正好把 R2.2 最后一条("按可执行文件建白名单"的固有边界)演给观众看，比任何解释都直观。

## R2.7 这套 demo 的本地前提(便于别人复现)

* 模型端点: 本机 `ANTHROPIC_BASE_URL` 指向一个本地网关(`http://127.0.0.1:15721`)，
  它 **不接受 `api.anthropic.com` 直连**(401)，且**实际服务的模型与请求的模型不同**
  (请求 `claude-haiku-5-5` → 服务 `qwen3.8-flash-next`)。
  所以 trace 里同时记 `gen_ai.request.model` 与 `gen_ai.response.model`，不要只看一个。
  换成真 Anthropic key 时这段自然变干净，代码不用改。
* 沙箱访问模型走 `observability/model-egress`(一个 30 行的 TCP 转发)，
  它代表"租户的模型网关"这一角色 —— 生产上就是公司的 LLM 网关 / 代理。
  上游用 `MODEL_UPSTREAM_HOST/PORT` 两个环境变量改。
* 观测后端: Jaeger 2.19(收 OTLP/HTTP 4318 + gRPC 4317，UI 16686)，
  跑在 plane-a 的 `observability` ns，NodePort 31681/31682；
  看 trace 时 `kubectl -n observability port-forward svc/jaeger 16686:16686`(demo 脚本会自动做)。
  选它是因为 Docker Hub 当时不可达，`cr.jaegertracing.io` 可达且镜像已在本地。
* OpenShell CLI: 0.1.4，与 gateway 同版本；本机在 `/private/tmp/inske-probe/cli/openshell`
  (不在仓库里)。gateway 通过 `kubectl -n openshell port-forward svc/openshell 8443:8080` 连，
  mTLS 凭据在 `~/.config/openshell/gateways/plane-a/`，`openshell status` 可自检。
* 配额提醒: 演示前先看 used/hard(demo 脚本会打印)。一个沙箱 = agent + supervisor 两个 pod，
  acme 的 `limits.memory` 是 2Gi，连开三个 768Mi 的沙箱就会被拒。
