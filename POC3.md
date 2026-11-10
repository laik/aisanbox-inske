# 角色
你是一名熟悉 Kubernetes RBAC、OIDC 身份联邦和 NVIDIA OpenShell 权限模型的安全架构验证工程师。

# 任务背景
沿着碑的设计，模拟capsule定义tenant-a|b 两个tenant, 并且在tenant配置里定义networkpolices策略为租户隔离；

我正在做一个 POC，验证一套统一的权限体系能否同时覆盖 Kubernetes 和 NVIDIA OpenShell Gateway。链路如下：

自研 LDAP Server（模拟返回 tenant-a / tenant-b 两个租户身份）
        ↓
Keycloak（通过 User Federation 或自定义 User Storage SPI 代理到该 LDAP Server）
        ↓
签发 OIDC JWT（JWT 中必须携带租户标识与角色）
        ↓
┌─────────────────────────────┬─────────────────────────────┐
│ Kubernetes kube-apiserver    │ NVIDIA OpenShell Gateway     │
│ 通过 OIDC 认证 + RBAC 授权   │ 通过 OIDC 认证 + Workspace   │
│ 控制 namespace 级权限        │ 角色/Scope 控制资源权限      │
└─────────────────────────────┴─────────────────────────────┘

# 架构约束
1. 自研 LDAP Server 是我方开发，只需模拟返回两类用户：
   - tenant-a 用户：应只能操作 namespace `tenant-a` 及 OpenShell 中属于 tenant-a 的资源
   - tenant-b 用户：应只能操作 namespace `tenant-b` 及 OpenShell 中属于 tenant-b 的资源
2. Keycloak 是唯一 OIDC 提供商，K8s 与 OpenShell Gateway 都信任它。
3. OpenShell 的权限模型是：OIDC 角色（adminRole/userRole）+ Workspace 成员资格（admin/user）+ 可选 Scope。Workspace 是资源隔离边界。
4. 不要求改造 OpenShell 源码；通过其标准 OIDC 配置与 Workspace 成员管理实现隔离。

# 需要你产出的内容

## 一、身份与声明设计
1. 设计 Keycloak 中应配置的 Realm Role、Client Scope、以及 JWT 中应携带的 claim 结构（至少包含：租户标识、OpenShell 角色、K8s 组/用户标识）。
2. 说明 K8s kube-apiserver 需要配置的 OIDC 参数（issuer、client-id、username-claim、groups-claim），以及 OpenShell Gateway 需要配置的 OIDC 参数（issuer、audience、roles-claim、adminRole、userRole）。
3. 指出 tenant-a 与 tenant-b 在 JWT 中必须体现的差异点，确保下游两侧都能据此做隔离。

## 二、Kubernetes 侧验证方案
1. 给出 RBAC 设计：RoleBinding/ClusterRoleBinding 如何把 tenant-a 组绑定到 `tenant-a` namespace，tenant-b 同理。
2. 给出正反用例矩阵，至少覆盖：
   - tenant-a 用户在 `tenant-a` namespace 内创建/读取 Pod（应成功）
   - tenant-a 用户在 `tenant-b` namespace 内做同样操作（应被拒绝）
   - tenant-a 用户读取集群级资源如 Node（应被拒绝，除非显式授权）
3. 给出每个用例的具体 kubectl 命令与预期返回（成功 / Forbidden 的具体错误形态）。

## 三、OpenShell Gateway 侧验证方案
1. 给出 Workspace 规划：是否为 tenant-a / tenant-b 各建一个 Workspace，以及成员如何分配。
2. 给出正反用例矩阵，至少覆盖：
   - tenant-a 用户在 tenant-a Workspace 内创建/列出 Sandbox（应成功）
   - tenant-a 用户尝试访问 tenant-b Workspace（应不可见或被拒绝）
   - tenant-a 用户尝试创建 Provider 或修改策略（根据其角色应被拒绝或允许）
   - tenant-b 用户做对称验证
3. 给出每个用例的具体 openshell CLI 命令与预期输出形态。

## 四、跨系统一致性验证
1. 设计一个“同一用户、两侧行为对照”的检查表：同一 tenant-a 用户在 K8s 与 OpenShell 中的可见资源范围必须一致，不能出现一侧隔离生效、另一侧越权的情况。
2. 指出最容易出现“隔离假象”的三个风险点（例如：JWT claim 缺失导致两侧都退化为全权限、Workspace 成员误配、Keycloak 角色映射未生效），并给出检测方法。

## 五、POC 验收标准
用一张表给出“通过 / 不通过”的判定条件，必须包含：
- 身份链路：LDAP 用户能经 Keycloak 登录并拿到包含正确租户 claim 的 JWT
- K8s 隔离：tenant-a 无法触碰 tenant-b namespace，反之亦然
- OpenShell 隔离：tenant-a 无法看到或操作 tenant-b Workspace 资源，反之亦然
- 一致性：两侧对同一用户的授权范围不矛盾
- 失败可观测：越权请求在 K8s 返回 Forbidden、在 OpenShell 返回明确拒绝，且审计日志可追溯

# 输出要求
- 用中文输出，结构按上面五部分组织。
- 每个用例用表格呈现：用例编号、操作者、目标系统、命令、预期结果、失败判定。
- 对关键配置项给出示例值（如 claim 名称、Role 名称、Workspace 名称），不要只给抽象描述。
- 如果发现我给出的架构约束中存在会导致 POC 无法验证隔离的漏洞，请单独列出并给出修正建议。