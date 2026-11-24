结论:支持。 gateway 通过 Kubernetes 计算驱动的 workspace_mode 支持多 namespace 运行时,v0.1.7(你的线上基线)和最新 main 都有此功能,且有专门的 E2E 测试覆盖。

三种模式(config.rs:304-307)

┌──────────────┬──────────────────────────────────────────────────────────────────────────┬──────────────────┐
│     模式     │                              namespace 映射                              │ 谁管理 namespace │
├──────────────┼──────────────────────────────────────────────────────────────────────────┼──────────────────┤
│ shared(默认) │ 所有 workspace 共用一个 namespace                                        │ 平台运维         │
├──────────────┼──────────────────────────────────────────────────────────────────────────┼──────────────────┤
│ managed      │ 每个 workspace 一个 openshell-{gateway_id}-{workspace},按需自动创建/删除 │ OpenShell 驱动   │
├──────────────┼──────────────────────────────────────────────────────────────────────────┼──────────────────┤
│ operator     │ workspace 名 = 预置 namespace 名,须在允许清单内                          │ 平台运维         │
└──────────────┴──────────────────────────────────────────────────────────────────────────┴──────────────────┘

代码证据(v0.1.7 检出验证)

- 沙箱创建按模式路由 namespace:driver.rs:2400-2416 — managed 调 ensure_namespace(workspace);operator 校验 allowlist,不在清单内的 workspace 直接拒绝(Precondition 错误)。
- 多 namespace watch:driver.rs:5513-5519 — is_multi_namespace() 为真时走 watch_sandboxes_cluster_wide(),跨 namespace 同步沙箱状态。
- managed 模式配套:自动打 openshell.ai/managed-by=openshell 标签、每 namespace 建 ServiceAccount + NetworkPolicy、从 server.sandboxNamespace 复制配置的 Secret;删除 workspace 时由驱动删 namespace。
- operator 模式发现机制:operator_namespace_label(标签选择器动态 watch,driver.rs:8672)或 operator_namespace_file(JSON 允许清单,ConfigMap 挂载、热加载)。

如何启用(Helm)

gatewayConfig:
  openshell.drivers.kubernetes:
    workspace_mode: managed   # 或 operator
    # operator 模式二选一:
    # operator_namespace_label: "openshell.ai/workspace=true"
    # operator_namespace_file: /etc/openshell/workspaces/namespaces.json

- managed 需要保留 chart 的 cluster-scoped RBAC(创建/删除 namespace 权限);gateway ID + workspace 名受 DNS-1123 长度限制。
- operator 需在每个允许清单 namespace 里装 openshell-workspace chart,gateway 不创建/删除这些 namespace。

测试与文档

- E2E:e2e/rust/tests/workspace_namespace_managed.rs(5 个用例,含 managed_isolates_workspaces_into_separate_namespaces、workspace 删除回收 namespace)和 workspace_namespace_operator.rs(标签发现、无 workspace chart 时 gateway 无 Secret 权限的 RBAC 边界);CI overlay values-workspace-managed.yaml / values-workspace-operator.yaml。
- 文档:docs/kubernetes/workspaces.mdx。

⚠️ 注意:切换模式不迁移已有沙箱——新旧模式映射到不同 namespace,存量资源留在原地;workspace 成员/角色与 K8s namespace 访问是两套独立体系。

需要的话我可以在远程 kind 集群(192.168.5.190)上实际部署 managed 模式、建两个 workspace 各跑一个沙箱做活体验证。


可以每个 workspace 落到不同 namespace,但不能任意指定 namespace 名——映射规则是固定的,v0.1.7 和 main 都一样:

映射规则(不可自定义的部分)

┌──────────┬─────────────────────────────────────────────┬──────────────────────────────────────────────────────┐
│   模式   │            workspace → namespace            │                   能否指定任意名字                   │
├──────────┼─────────────────────────────────────────────┼──────────────────────────────────────────────────────┤
│ managed  │ openshell-{gateway_id}-{workspace} 自动生成 │ ❌ 名字由规则推导                                    │
├──────────┼─────────────────────────────────────────────┼──────────────────────────────────────────────────────┤
│ operator │ workspace 名 = namespace 名(恒等映射)       │ ⚠️ 间接可以:把 workspace 命名成目标 namespace 的名字 │
└──────────┴─────────────────────────────────────────────┴──────────────────────────────────────────────────────┘

证据:

- CreateWorkspaceRequest(proto/openshell.proto:3834)只有 name/labels/request_id,没有 namespace 字段;Workspace 数据模型也只有 metadata + status。
- 驱动侧目标 namespace 解析(v0.1.7 driver.rs:2400,main driver.rs:2591):operator 模式直接 workspace.to_string() 当 namespace 用,只校验 allowlist,没有任何映射表或 override 配置。

按用户切分的实际做法

场景 A:每用户一个独立 namespace(推荐 managed)

openshell workspace create alice
openshell workspace create bob
# 沙箱自动落到 openshell-<gateway_id>-alice / openshell-<gateway_id>-bob
# 驱动自动建 namespace、SA、NetworkPolicy,删 workspace 时回收

场景 B:用户要发到已有的、名字不规则的 namespace(用 operator)

比如想让某用户的沙箱进现有的 team-a-runtime:

# workspace 必须与 namespace 同名
openshell workspace create team-a-runtime
# 把该用户加进这个 workspace 的成员/角色里

namespace 预先建好、打上 allowlist 标签(或写进 JSON 清单)、装 openshell-workspace chart。gateway 不碰这些 namespace 的生命周期。

关键点:workspace 是隔离单元,不是"用户名"——用户归属靠 workspace 成员/角色管理,一个 workspace 可以有多个用户,一个用户也可以进多个 workspace。所以"按用户切分"和"按团队 namespace 切分"可以解耦:namespace 按团队预置(operator),workspace 与 namespace 同名,用户通过 membership 授权进对应 workspace。

如果你的需求是 workspace 名与 namespace 名完全解耦的任意映射(如 workspace alice → namespace prod-team-x),当前没有这个能力,需要提 feature request(在 workspace 模型或驱动配置里加显式映射)。需要的话我可以照 #5818 的流程帮你起草 issue。
---

✅ 2026-11-23 已在 k8s-221（OpenShell 0.1.7）实跑验证 operator 模式：判定、RBAC 分层、隔离实测与复现脚本见
[`poc/operator-mode/README.md`](poc/operator-mode/README.md)。上文的"能力边界"结论成立，另有四条硬约束补在那里：
Workspace 名（= 租户 ns 名）上限 19 字符且必须 DNS-1123；`operator_namespace_label` 与 `operator_namespace_file`
在 0.1.7 互斥（同时配 Gateway 起不来，helm 深合并会悄悄留下旧的那条）；每个租户 ns 必须装 `openshell-workspace`
（缺它先撞 sandbox SA 不存在）；OpenShell 的策略只管它自己的沙箱 Pod，租户 ns 里其它 Pod 之间仍需 Capsule/Antrea。
