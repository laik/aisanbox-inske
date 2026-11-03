# 多租户 AI Sandbox POC — 实测结论

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
