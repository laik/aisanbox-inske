# 多租户 AI Sandbox · POC 简版结论

> **一句话：** 四个开源组件已经串成一条链 —— **开通租户 → agent 跑起来 → 越界被拦 → 事后能查**。
> 中间只接了一根线，不用改你现有的租户流程。
>
> 结论全部来自 2026-11-03 在 kind × 2（K8s v1.37 · Docker Desktop 29.2.1 / 内核 6.12.72）上的实测。
> 看图版：[`index.html`](index.html) ｜ 逐项证据与踩坑：[`FINDINGS.md`](FINDINGS.md)

---

## 1. 三个结论

| 结论 | 说明 |
|---|---|
| **能跑通** | `openshell sandbox create` → agent 以非 root 执行命令；配额、网络边界、策略、审计全部生效 |
| **够快** | 预热池认领到就绪 **0.25 s**；冷启动 0.92 s（镜像已在节点）/ 15.98 s（要拉 20 MB 镜像） |
| **看得见** | agent 每次出网、起 shell、装包都带租户 / 命名空间 / 二进制名，能按"哪个程序连哪个地址"当场拦 |

两条反常识、但很好用的实测结果：

- **被拦掉的连接照样会被记录。** NetworkPolicy / OpenShell 只决定"成不成功"，"agent 试过连哪儿"只有 Tetragon 这层看得到。
- **同样是拒绝，快慢差 50 倍。** Tetragon 让 agent 0.11 s 收到报错，NetworkPolicy 要 6 s 超时才失败。对 agent 来说，快速失败远比挂起好处理。

---

## 2. 四层，各管一段

| 层 | 负责什么（人话） | 实测证据 |
|---|---|---|
| **Capsule** 0.15.2 | 租户合同：命名空间归谁、CPU/内存上限、能建几个 ns。像物业——分房、抄表、定水电上限 | 超配额直接被拒：`exceeded quota: capsule-globex-0` |
| **agent-sandbox** v1.0.9 | 沙箱本体：稳定身份、持久工作盘、休眠、预热池。像房间——有门牌、有储物柜，可提前备房 | 认领预热池 → **0.25 s** 就绪 |
| **OpenShell** 0.1.4 | 行为边界：agent 能碰哪些文件 / 出网地址 / 凭据，以及**为什么**放行。像门禁——谁批的条子 | 策略热更新 v1→v2，**无需重启**沙箱 |
| **Tetragon** 1.8.0 | 真相与拦截：内核里真实发生了什么都记下来，并能当场拒绝。像摄像头 + 紧急制动 | 越界后 agent **0.11 s** 收到 `PermissionError` |

**四层用同一个租户标签对齐：`projectcapsule.dev/tenant=acme`。** 配额、网络策略、审计都能按这一个键聚合——身份贯穿始终，不需要另建映射表。这是这套组合最值钱的性质。

> 补充：`root` / `mount()` 这类"能力型越权"不靠策略。非 root + seccomp + drop ALL caps 在系统调用进内核**之前**就挡住了，所以 Tetragon 看不到——这是分层正确，不是漏采。

---

## 3. 唯一需要接的线：`workspace_mode = operator`

OpenShell 默认自己建命名空间。你已经有 Capsule 租户体系，所以换成 operator 模式：**平台建 ns 并打一个标签，OpenShell 按标签认领。**

```yaml
# 1) 租户侧 capsule/tenants.yaml：给该租户的所有 ns 打标签
spec:
  namespaceOptions:
    additionalMetadata:
      labels: {openshell.ai/workspace: "true"}
```

```yaml
# 2) 控制面 openshell/values-plane-a.yaml：按标签发现 ns
server:
  drivers:
    kubernetes:
      workspaceMode: operator
      operatorNamespaceLabel: "openshell.ai/workspace=true"
```

网关日志确认接管：`operator namespace allowlist replaced from full relist total=2`。

三种模式里只有 `operator` 适合已有租户体系的平台：

| 模式 | namespace 归谁 | 适用 |
|---|---|---|
| `shared` | 全部落一个 ns | 单团队，隔离最弱 |
| `managed` | OpenShell 自建 ns | 没有既有租户体系时 |
| **`operator`** | **平台预建，按标签发现** | **✅ 与 Capsule 对齐** |

---

## 4. 一个沙箱实际长什么样

```
namespace acme   labels: capsule.clastix.io/tenant=acme · openshell.ai/workspace=true
├─ Sandbox CR        agents.x-k8s.io/v1beta1   ← OpenShell 创建，agent-sandbox 落地
├─ pod poc-acme-1     agent 容器（uid 10001，非 root，drop ALL caps，无 SA token）
├─ pod os-supervisor-… 边界端口 5500
└─ 三层 NetworkPolicy 叠加（Capsule + OpenShell）
```

同一个 Pod 上同时带 Capsule 与 OpenShell 的租户标签，配额、策略、审计才能用同一个键聚合。

---

## 5. 已经实测通过

| 验证项 | 结果 |
|---|---|
| 端到端创建 sandbox | ✅ 一条命令建沙箱，agent 以 uid 10001 非 root 运行 |
| Capsule 配额真实拦截 | ✅ 超限被拒，删除沙箱后 `status.used` 回落 |
| 网络边界 | ✅ agent 连 kube-apiserver / gateway 超时，只留 supervisor:5500 |
| 运行时强制（内核） | ✅ 指定解释器被拒（`pip: Operation not permitted`），python 不受影响 |
| 预热池 | ✅ claim → Ready 0.25 s |
| Tetragon 观测 | ✅ 事件自带 namespace / pod / labels / binary |
| 按租户下发策略 | ✅ `projectcapsule.dev/tenant: acme` 选中；Capsule GTR 自动下发（`READY=True`） |
| 跨集群可观测 | ✅ 平台集群抓租户集群三处指标，全部 `up` |
| 租户契约可移植 | ✅ 同一份 `tenants.yaml` 在第二个集群复现 |

---

## 6. 还没搞定（上线前必须处理）

| 项 | 状态 | 影响 & 建议 |
|---|---|---|
| 沙箱 DNS 走 supervisor 边界 | ❌ 未达成 | 沙箱 `resolv.conf` 指向 `127.0.0.53`，解析走集群 CoreDNS；L7 出网策略拿不到官方教程里的"代理 403"。**先在自己环境复验这段** |
| Capsule `runtimeClasses` 白名单 | ❌ 未拦住 | owner 用 `kata-containers` 仍被接受，到 kubelet 才失败。要按租户限制 gVisor/Kata，需自补 CEL ValidatingPolicy / Kyverno |
| 预热池沙箱没有策略边界 | ❌ 缺口 | 池里领出的沙箱不带 OpenShell supervisor 与凭据注入 → "低延迟"与"有策略"目前二选一 |
| hypervisor 级隔离 | ❌ 未做 | kind 无 gVisor 节点镜像；现有强度 = 非 root + seccomp + NP + supervisor。跑不可信 LLM 代码前需上 gVisor / Kata |
| 单副本 + SQLite | ⚠️ 需改 | 网关默认只够 POC；生产要 `deployment` + 外部 PostgreSQL。多集群只能每集群一套 gateway |

另外三条运维注意：

- Capsule 的 `resourceQuotas` / `limitRanges` / `networkPolicies` / `additionalMetadata` 已标 deprecated，新设计优先用 `rules` + `*TenantResource`。
- `GlobalTenantResource` 与 Helm 对同名资源会冲突（如 `openshell-sandbox` SA），二选一。
- Capsule 0.15 声明最低 K8s v1.36，本 POC 用 1.37 可用；生产选版本时把它和 agent-sandbox / OpenShell 的支持矩阵放在一起看。

---

## 7. 上手

```bash
# 1. 重建两个 kind 集群与全部组件（约 10 分钟，Docker 至少 8 GiB）
bash poc/scripts/bootstrap.sh

# 2. 给一个租户开通 sandbox 能力（5 个动作全在脚本里）
bash poc/usage/01-onboard-tenant.sh acme

# 3. 用起来
openshell workspace create --name acme
openshell --workspace acme sandbox create --name try1 \
  --cpu 200m --memory 256Mi -- python3 -u agent.py
openshell --workspace acme policy get try1     # 生效策略 + hash + 版本
```

---

## 8. 文档怎么读

| 文件 | 适合谁 | 内容 |
|---|---|---|
| [`index.html`](index.html) | 第一次了解的人 | 一页看懂：结论、四层、数字、缺口 |
| `SUMMARY.md` | 要文字版的人 | 本页，简版结论 |
| [`architecture.html`](architecture.html) | 要动手接的人 | 详细架构、配置、策略基线、9 条写策略规则 |
| [`FINDINGS.md`](FINDINGS.md) | 要核对证据的人 | 第一轮逐项验证、报错原文、未定论项 |

策略文件在 [`../tetragon/policies/`](../tetragon/policies/)（全部实测加载成功），观测手册在 [`../usage/02-agent-visibility.md`](../usage/02-agent-visibility.md)。
