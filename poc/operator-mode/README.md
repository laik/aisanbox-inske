# POC-OP：多租户 `operator` 模式（一个 Gateway + 平台预置 Namespace）

判定来自 `k8s-221`（192.168.5.221/222，K8s v1.37.2，Antrea 唯一 CNI）上的实跑，
OpenShell **helm-chart 0.1.7**（image `0.1.7-api-prefix`），本地 CLI 0.1.9。
原始输出见 `evidence-20261123T034137Z.md`（`bash demo.sh` 可重跑，`bash demo.sh down` 清理负载）；
OIDC 一层的判定见 `evidence-20261123T080350Z.md`（`bash 90-oidc-ns-workspace.sh`，见第 7 节）。

> 目标形态复核：一个 Gateway 由平台统一部署，多个租户共享；每个 Workspace 落在独立的 Runtime Namespace；
> Namespace 由平台创建/删除，OpenShell 只发现和使用；Namespace 之间保持 K8s 网络与资源隔离。
> **结论：这套形态在 v0.1.7 上成立，但有 4 个必须先知道的硬约束（第 3 节）。**

---

## 1. 结论表

| 编号 | 判定 | 内容 |
|---|---|---|
| OP-01 | ✅ | 标签发现：`operator_namespace_label = openshell.ai/workspace=true` 生效。日志 `operator namespace label watcher spawned` → `operator namespace allowlist replaced from full relist total=N`，N = 当时带该标签的 ns 数 |
| OP-02 | ✅ | **恒等映射**：Workspace 名 = Namespace 名。`workspace create --name tenant-a-runtime` → 该 workspace 的沙箱进 `tenant-a-runtime` |
| OP-03 | ✅ | 负例：ns 装了 workspace chart 但**没打标签** → 建沙箱被拒 `workspace 'tenant-d-runtime' is not in the operator namespace allowlist`（Precondition）。发现机制只看标签，不看别的 |
| OP-04 | ✅ | 负例：ns 打了标签但**没装 workspace chart** → Pod 创建失败 `error looking up service account tenant-c-runtime/openshell-sandbox: serviceaccount not found (403)`。先撞的是缺 sandbox SA，不是 Secret 权限 |
| OP-05 | ✅ | RBAC 分工实测（见第 2 节）：ClusterRole 有 `namespaces get/list/watch` 但**没有** `create/delete`；per-ns 的 `secrets/services/networkpolicies/sandboxes` 权限只来自各 ns 里的 `openshell-workspace` Role |
| OP-06 | ✅ | 一个 Gateway 同时给两个租户建出完整运行时：两个 ns 内各自的 Sandbox CR、workload Pod、supervisor Pod、`os-boundary-*`/`os-supervisor-*` Service、4 条 NetworkPolicy、2 个 Secret、sandbox SA —— 全部落在租户 ns 内，Gateway ns 里没有残留 |
| OP-07 | ✅ | 控制面隔离：`sandbox list --workspace tenant-a-runtime` 只列出 `op-a`，`--workspace tenant-b-runtime` 只列出 `op-b` |
| OP-08 | ✅ | 数据面跨 ns 正常：`sandbox exec --name op-a --workspace tenant-a-runtime -- hostname` → `op-a`（mTLS 隧道不受 namespace 边界影响） |
| OP-09 | ✅ | 网络隔离是真的被执行（Antrea），不是只有 API 对象：同 ns 探 `os-boundary:5500` = **Connection refused**（包到了，端口拒），跨租户探同名服务 = **timeout/包被丢弃** |
| OP-10 | ✅ | Namespace 生命周期不在 OpenShell 手里：`auth can-i create/delete namespaces` = **no**；`workspace delete` 之后 ns 仍是 `Active`，日志里没有删 ns 的动作 |
| OP-11 | ✅ | 另一种发现机制 JSON allowlist 可用且**热加载**：patch ConfigMap 后 `operator namespace allowlist reloaded from file total=4`（实测 4s 内），**Pod UID 不变、restarts=0**；随后新准入的 ns 里建沙箱成功。标签在 file 模式下不起作用（带标签但不在清单里的 ns 被拒） |
| OP-12 | ✅ | 负例：**两种发现机制同时配置，0.1.7 的 Gateway 起不来** —— `configuration error: operator workspace mode requires exactly one of operator_namespace_label or operator_namespace_file, not both`（CrashLoopBackOff）。上游 main 分支文档写的是"Both can be combined"，v0.1.7 不是 |
| OP-13 | ✅ | Workspace 名上限 **19 字符**（`workspace name exceeds maximum length (22 > 19)`），且只接受 DNS-1123 label（小写字母数字 + 连字符）。operator 模式下这就是 **Runtime Namespace 名的硬上限** |
| OP-14 | ✅ | 切换模式不迁移旧沙箱：shared 期建的 3 个沙箱 CR 仍在 `openshell` ns，`sandbox list --workspace default` 仍列出它们（Completed/Stopped），但新模式下不会再被复用 |
| OP-15 | ⚠️ | `openshell-sandbox-supervisors` / `openshell-sandbox-workloads` 这两条 ns 级 NetworkPolicy 无 ownerRef，**沙箱删掉后仍在**（建沙箱失败时也一样），要计入平台 GC |
| OP-16 | ⚠️ | 环境级坑（与 workspace_mode 无关，但会伪装成它）：Vault 用 `-dev` 内存存储，Pod 重启后 auth/method 全丢 → **所有** `sandbox create` 都失败并报 `Vault Kubernetes auth denied the configured role`。复现与修法见第 4 节 |
| OP-17 | ❌ 未验证 | 把 Gateway 自己的 ns 也当 runtime ns 用（operator 模式下 chart 会**去掉** Gateway ns 里的 namespace-scoped Role，需要在该 ns 也装 workspace chart）。没做这个用例 |
| OP-18 | ✅ | 删 Workspace **不会**回收租户 ns 里的 K8s 资源：有沙箱时 `workspace delete` 要么直接以 `workspace '…' still contains resources: sandbox, sandbox policy` 拒绝，要么进入 `Terminating` 而 Sandbox CR/Pod 仍在跑。必须先 `sandbox delete`，再删 workspace；ns 全程不受影响（见 evidence §82） |

---

## 2. operator 模式下 RBAC 到底怎么分层

`helm upgrade` 到 operator 模式后，Gateway release 的 RBAC 变化（`helm template` 前后 diff 实测）：

- ClusterRole（`openshell-node-reader-<ns>`）**增加**：`namespaces get/list/watch`、
  `sandboxes/sandboxes/status`、`pods`、`events`、`services create/get`、`networkpolicies create/get`（集群范围）。
  **没有** `namespaces create/delete`（那是 managed 模式才有的），**没有** `secrets`。
- Gateway ns 里的 namespace-scoped Role（shared 模式的 `openshell-sandbox`）**被去掉**，
  换成 `openshell-workspace-secret-source`（只读 Gateway 自己 ns 里要下发到租户 ns 的 Secret）。
- 每个租户 ns 的权限**只能**来自那里装的 `openshell-workspace` release：
  `Role/RoleBinding openshell-workspace-sandbox`（沙箱 CR、pods、services、networkpolicies、`secrets create/delete`、events）
  + sandbox ServiceAccount `openshell-sandbox` + 一条只放行 Gateway Pod 访问 2222 的 SSH ingress NetworkPolicy。

复验：

```bash
SA=system:serviceaccount:openshell:openshell
kubectl auth can-i create namespaces --as=$SA                                   # no
kubectl auth can-i list namespaces   --as=$SA                                   # yes
for ns in tenant-a-runtime tenant-c-runtime; do
  kubectl auth can-i create secrets -n $ns --as=$SA; done                      # yes / no
```

**推论（对应安全边界）**：allowlist 只是“准入”，不是隔离边界。发现集合 = 带该标签的 ns 集合，没有额外校验：
evidence §10 的 `kubectl get ns -L openshell.ai/workspace` 与 §20 的 allowlist 日志一一对得上，
其中 `tenant-c-runtime` 没有 workspace chart 也照样进清单；早期一次跑里多打了 4 个标签的无关 ns 就直接进了清单（`total=8`）。
所以 `openshell.ai/workspace` 这个标签必须由 Gatekeeper/平台 Controller 独占写权限，
且租户不能改自己 ns 里 OpenShell 生成的 Sandbox CR / Pod / SA。

---

## 3. 四个必须先知道的硬约束（那份外部方案里没写对的）

1. **两种发现机制在 v0.1.7 是"互斥"，不是"建议只选一个"。**
   同时配 → Gateway 直接启动失败（OP-12）。更常见的踩法是间接的：先 upgrade 成 file 模式，
   再 upgrade 成 label 模式 —— helm 的 `-f` 是深合并，`operator_namespace_file` 会留在 release values 里，
   Gateway 就起不来。修法：在 values 里把另一条显式置 `null`（见 `values-operator.yaml` / `values-operator-file.yaml`）。
2. **Runtime Namespace 的名字最长 19 字符**，且必须 DNS-1123 label（小写字母数字 + 连字符，**下划线不行**）。
   因为 Workspace 名恒等于 ns 名。`tenant-a-runtime`(16) 可以，`tenant_a_runtime` / `tenant-a-agent-runtime`(22) 不行。
   平台命名规范要在设计阶段就按这个来（这也让 Capsule 的租户 ns 命名要提前对齐）。
3. **每个租户 ns 必须装 `openshell-workspace`，不是"可选的 RBAC 加固"。**
   缺它时最先失败的是 sandbox ServiceAccount 找不到（OP-04），不是文档里说的 Secret 权限。
   另外那份方案里 `--set gateway.serviceAccount.name=openshell --set gateway.serviceAccount.namespace=openshell`
   是 chart 的默认值，写不写都一样。
4. **隔离边界只管 OpenShell 的沙箱 Pod。** 生成的策略用 ns 内 `podSelector`，所以跨 ns 天然不通（OP-09 实测），
   但租户 ns 里的普通 Pod（渲染器、sidecar、你自己的服务）彼此之间没有任何限制 —— 实测跨 ns 普通 Pod 直接可达。
   租户级的网络隔离仍然要 Capsule/Antrea 来补，这一点那份方案是对的。

顺带更正两处小事：JSON allowlist 的挂载在这个环境里应走 chart 的 `server.extraVolumes`/`extraVolumeMounts`
（不是手改 Deployment spec）；热加载确实成立（OP-11），改 ConfigMap 不用重启 Gateway。

---

## 4. 踩到的环境级坑：Vault `-dev` 重启

现象：切到 operator 模式后，**所有** `sandbox create` 都返回
`code: 'The caller does not have permission to execute the specified operation', message: "Vault Kubernetes auth denied the configured role"`，
包括 workspace `default` 这种根本没进 allowlist 的调用 —— 说明错误发生在 namespace 路由之前，与 workspace_mode 无关。
根因：`vault-demo` 里的 Vault 是 `server -dev -dev-root-token-id=root`，**存储是内存**，
Pod 重启后 `auth/kubernetes` 与所有 KV 都没了；且 `auth/kubernetes/config` 必须带 `token_reviewer_jwt`（该集群用 `vault-reviewer` SA 做 TokenReview）。

修法（实测可用）：

```bash
V="kubectl -n vault-demo exec deploy/vault -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault"
$V auth enable kubernetes
TRJ=$(kubectl -n vault-demo create token vault-reviewer --duration=8760h)
$V write auth/kubernetes/config kubernetes_host="https://192.168.5.221:6443" \
   kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt token_reviewer_jwt="$TRJ"
$V policy write openshell - <<< 'path "secret/*" { capabilities = ["create","read","update","delete","list"] }'
$V write auth/kubernetes/role/openshell bound_service_account_names=openshell \
   bound_service_account_namespaces=openshell policies=openshell ttl=1h
```

对平台的含义：credential driver 是沙箱创建的**前置条件**，报错信息不会告诉你这一点。
生产上 Vault 必须是持久化实例（这条对多租户更关键：一个 Gateway 服务多个租户，credential 挂了就是全租户建不出沙箱）。

---

## 5. 这套形态的当前状态与回退

当前 `k8s-221` 上的 Gateway：**operator + label 发现 + OIDC**（issuer `https://192.168.5.221:31443/realms/aisanbox`，
`roles_claim=groups`/`admin_role=os-admin`/`user_role=os-user`/`audience=openshell-cli`）。
5 个 runtime ns：`tenant-a/b-runtime`（正例，已装 chart，workspace 已建好）、`tenant-c-runtime`（标签但无 chart，负例）、
`tenant-d-runtime`（chart 但无标签，负例）、`tenant-e-runtime`（用于 file 模式热加载）。
矩阵沙箱（`oa-*`/`ob-*`/`ta-1`）可能还在，`bash 90-oidc-ns-workspace.sh clean` 清掉。

现成的活体 demo：

```bash
# 开 OIDC 之后要用带 OIDC 身份的 profile（见第 7 节）
OPENSHELL_GATEWAY_INSECURE=true openshell -g os-tadmin sandbox create --workspace tenant-a-runtime --name t1 --from nvcr.io/nvidia/base/ubuntu:24.04 -- sleep 600
kubectl -n tenant-a-runtime get pod,svc,netpol     # 运行时全部在租户 ns 里
```

- 回退到 shared：`helm rollback openshell -n openshell`（回到 rev 5），或去掉 `values-operator.yaml` 重新 upgrade。
  注意切模式不会迁移已有沙箱（OP-14），要先规划旧沙箱的删除。
- `operator_namespace_label` vs `operator_namespace_file`：两条都跑通了。数量多/由 Controller 自动打标 → label；
  要平台审批后才准入 → file（热加载实测有效）。**只能配一条**（OP-12）。
- 想加的安全约束：① 标签写权限归平台（Gatekeeper）；② 每个 runtime ns 自动装 workspace chart（平台 Controller）；
  ③ 租户 ns 里其它 Pod 的网络策略由 Capsule/Antrea 补；④ ns 级 NetworkPolicy 的 GC（OP-15）。

## 6. 复现

```bash
cd poc/operator-mode
bash demo.sh 2>&1 | tee evidence-$(date -u +%Y%m%dT%H%M%SZ).md   # 完整验证，约 6 分钟，含 4 次 Gateway 重启
bash demo.sh down                                                # 只删沙箱/探测 Pod
bash 90-oidc-ns-workspace.sh 2>&1 | tee evidence-$(date -u +%Y%m%dT%H%M%SZ).md   # OIDC 权限矩阵（约 1 分钟）
bash 90-oidc-ns-workspace.sh clean                               # 只删矩阵产物，identity 栈与 OIDC 配置保留
bash 92-roles-where.sh 2>&1 | tee evidence-$(date -u +%Y%m%dT%H%M%SZ).md   # 角色名在哪定义（会重启 Gateway 3 次）
```

前置：agent-sandbox CRD/controller 已装、Gateway release 已存在、credential driver 可用（见第 4 节）。
脚本默认 `CTX=k8s-221 GNS=openshell VER=0.1.7`，可用环境变量覆盖。

---

## 7. Namespace ↔ Workspace ↔ 用户身份（OIDC）

### 7.1 对应关系：一个 namespace 就是一个 workspace，恒等且不可配置

| 谁负责 | 做什么 |
|---|---|
| 平台 | 创建/删除 runtime ns，并决定是否让它进入 allowlist（打标签或写进 JSON 清单） |
| OpenShell | 只发现 allowlist 里的 ns；`workspace create --name X` 要求 X **等于** ns 名（OP-02/OP-13），没有别名/映射表可配 |
| 平台 Controller | 把目录里的租户成员关系写成该 workspace 的 `member add --subject <稳定的 sub> --role user` |

所以「不同 namespace 对应不同 workspace」在 operator 模式下成立且是唯一形态：ns 名 = workspace 名 = 沙箱落点，
三者恒等（本轮实测：`oa-1` 经 `--workspace tenant-a-runtime` 建出 → 落在 ns `tenant-a-runtime`；其余同理）。
用户能碰哪个 ns，完全由**成员关系**决定，与 ns 标签、IdP 组名都无关。

### 7.2 权限模型（实测分层，O-01…O-10）

判定发生在三层，互相独立：

1. **OIDC 层**（Gateway 配置）：`roles_claim = "groups"`、`admin_role = "os-admin"`、`user_role = "os-user"`、`audience = "openshell-cli"`。
   token 里没有 `os-user` 就没有普通操作权限；带 `os-admin` 就是 **Platform Admin**，可以列/管所有 workspace，并绕过成员检查往任意 workspace 建沙箱（O-05）。
2. **Workspace 成员层**：每个 workspace 独立存 `user` / `admin` 成员，subject = token 的 `sub`。
   不是成员 → 建/列都被拒（错误里直接给出该跑的 `workspace member add` 命令）；
   `user` 不能加成员（`workspace role 'admin' required`），`admin`（Workspace Admin）只能管自己那一个（O-09/O-10）。
   加/删成员会即时生效（O-06）。CLI 没有 `member update`，改角色只能 `remove` + `add`。
3. **K8s 层**：没有任何用户身份。租户 ns 里只有 gateway 的 SA 和 `openshell-sandbox` SA；
   `kubectl auth can-i --as=alice --as-group=tenant-a-users` = no（O-08）。K8s RBAC 不参与“谁能用哪个租户”。

**平台上建议这么落**（本轮配置即这套）：

- IdP 组只承担 OpenShell 的角色：`os-user`（所有可能用沙箱的人）、`os-admin`（平台运维，少数）。
- 租户成员用**另一套组**（如 `tenant-a-users`），它们对 OpenShell 完全无效（O-06 证明组不参与判定），
  必须由平台 Controller 按 `tenant-X-users → workspace tenant-X-runtime` 同步成 workspace 成员；
  组员离开时同样要 `member remove`，否则权限滞留（这是平台侧 GC 责任，OpenShell 不管）。
- `sub` 必须是稳定 ID（不要用可复用的用户名/邮箱），它是成员关系唯一绑定的键。
- `aud` 要与 Gateway `audience` 一致，否则 token 直接被拒。
- 权限模型不管网络：网络隔离由 Antrea/ns 边界保证（OP-09），workspace 成员只决定控制面能与不能。

### 7.3 OIDC 一层新踩的坑（细节与原始输出见 `evidence-20261123T080350Z.md` §2）

1. 开 OIDC 后原来的 mTLS 客户端证书 CLI 通道不再作为用户认证生效（`missing authorization header`）；管理动作也要用一个带 `os-admin` 的 OIDC 身份。
2. CLI 连自签证书 Gateway 必须 `OPENSHELL_GATEWAY_INSECURE=true`，否则每次调用都是 `connect error: transport error`（伪装成网络故障）。
3. access token 默认 300s，矩阵跑到一半就过期；realm 里设 `accessTokenLifespan: 1800`。
4. 每轮重签 issuer CA/证书会让运行中的 nginx 继续用旧证书 → Gateway 侧只报 `OIDC discovery request failed`。脚本已改为只在 SAN 不匹配时重签，并在证书/realm 变化时重启 Keycloak。

## 8. 接一个新租户要改什么（T-50933 实测，O-11…O-13）

判定与原始输出见 `evidence-20261123T102308Z.md`（`90-oidc-ns-workspace.sh` 第 60 步）。

**OpenShell 侧：什么都不加。** Gateway 的 OIDC 配置永远只有两个角色值，与租户数量无关：

```toml
[openshell.gateway.oidc]
issuer      = "https://<idp>/realms/<r>"
audience    = "openshell-cli"
roles_claim = "groups"        # 只读这一个 claim
admin_role  = "os-admin"      # Platform Admin，全平台，只给平台运维
user_role   = "os-user"       # 普通操作，所有可能用沙箱的人
```

IdP 侧给这个租户加两个组/角色（`T-50933-USER`、`T-50933-ADMIN`），把成员放进去 ——
用户 token 里的角色值就是 `["os-user","T-50933-USER"]`，OpenShell 只认其中的 `os-admin`/`os-user`，
剩下的组名对它毫无意义（实测：带 `T-50933-USER` 但不是成员 → `not a member of workspace 't-50933'`）。

K8s / 平台侧四步（顺序不能换）：

```bash
T=t-50933                     # ns 名 = workspace 名：DNS-1123、≤19 字符（大写、点、下划线都不行）
kubectl create ns "$T" && kubectl label ns "$T" openshell.ai/workspace=true platform.io/tenant=T-50933
helm upgrade --install openshell-workspace oci://ghcr.io/nvidia/openshell/openshell-workspace --version 0.1.7 -n "$T"
openshell -g <platform-admin> workspace create --name "$T"     # Gateway 不用重启，标签 watcher 自动发现
```

平台 Controller 里那条同步规则（每个租户一条，别的一律不动）：

```
组 T-<id>-USER  → workspace member add --workspace t-<id> --subject <稳定的 sub> --role user
组 T-<id>-ADMIN → workspace member add --workspace t-<id> --subject <稳定的 sub> --role admin   # 租户管理员
组员离开        → workspace member remove --workspace t-<id> --subject <sub>      # 不做就会权限滞留
```

**不要把 `T-50933-ADMIN` 配成 `admin_role`**：`admin_role` 是全局的，配上就是 Platform Admin
（能列所有 workspace、能往任意租户 ns 建沙箱）。租户内的管理员用 workspace 成员角色 `admin`（实测只能管自己那一个）。

## 9. 图、数据结构、以及平台上具体怎么做

### 9.1 一条链上的四份状态

```
                       ┌──────────────── ① IdP（OIDC）─────────────────┐
                       │ user: sub=<稳定 ID>, username, email          │
                       │ groups/roles: os-user, os-admin,              │
                       │             T-<id>-USER, T-<id>-ADMIN         │
                       └───────┬───────────────────────▲───────────────┘
              token claims      │ iss/aud/sub/groups/exp │ 登录（device flow / 浏览器）
        ┌───────────────────────▼──────────┐            │
        │ ② Gateway 控制面 (PVC 里的 SQLite │            │  openshell gateway login
        │    /var/openshell/openshell.db)  │◄───────────┘
        │  objects 表: workspace(name,status)│─── 授权判定 ───► ① 里的 role 值 + ②里的成员关系
        │          sandbox(workspace,name)  │
        │          sandbox_policy / ...     │
        │  配置 gateway.toml: roles_claim / │
        │  admin_role / user_role / audience│
        └───────┬───────────────────────────┘
                │ workspace 名 == namespace 名（恒等，没有映射表）
        ┌───────▼───────────────────────────────────────────┐   ③ K8s（平台拥有）
        │ Namespace t-<id>  labels: openshell.ai/workspace=true│
        │ openshell-workspace chart → openshell-sandbox SA +   │
        │   Role/RoleBinding + SSH ingress NetworkPolicy       │
        │ Sandbox CR + workload Pod + supervisor Pod +         │
        │ os-boundary-*/os-supervisor-* Service + Secret +     │
        │ 4 条 NetworkPolicy（全部只在这个 ns 内）             │
        └───────────────────────────────────────────────────┘
        ④ 平台自己要存的：租户注册表 + 成员同步状态（见 9.3）
```

### 9.2 每份数据结构的字段与归属

| # | 存在哪 | 关键字段 | 谁写 | 实测依据 |
|---|---|---|---|---|
| ① IdP 用户/组 | 客户 IdP（Keycloak/ADFS/Dex…） | `sub`（不可复用的稳定 ID）、用户名、组成员 | 身份管理员 | `kc-realm-op.json`；token 解码 `sub=u50933 groups=['T-50933-USER','os-user']` |
| ①′ Token | 短时（本 POC 配 1800s） | `iss` `aud` `sub` `<roles_claim>` `exp` | IdP | 第 7 节矩阵里的 claim 打印 |
| ② Workspace 记录 | Gateway SQLite（PVC），`objects` 表里 `object_type='workspace'` | `name`(=ns 名，≤19 DNS-1123)、`status`、labels | 平台（`workspace create/delete`） | 从 PVC 里 dump 出来的 `objects` 表；`workspace list` |
| ②′ Workspace 成员 | Gateway 控制面（0.1.7 里我没能从 `objects` 表按 object_type 找到独立行，见下面"未查明"） | `(workspace, subject, role∈{user,admin})` | 平台 Controller / Platform Admin | `workspace member list` 输出 `SUBJECT ROLE`；加/删即时生效（O-06、O-13） |
| ②″ Sandbox / Policy | 同上，`object_type='sandbox' / 'sandbox_policy' / 'sandbox_ssh_identity_v1' …` | 带 `workspace` 列做作用域 | Gateway | 从 PVC dump 的 object_type 分布 |
| ②‴ 准入清单（allowlist） | 不存，运行时从 ns 标签或 JSON 文件算出 | `operator_namespace_label` 或 `operator_namespace_file` | 平台（打标）/ 配置文件 | 日志 `operator namespace allowlist replaced from full relist` |
| ③ Namespace + RBAC | K8s | labels `openshell.ai/workspace`、`platform.io/tenant`；SA `openshell-sandbox`；Role/RoleBinding | 平台 | `namespaces.yaml`、第 2 节 |
| ③′ 运行时对象 | K8s（租户 ns 内） | Sandbox CR、2 个 Pod、2 个 Service、2 个 Secret、4 条 NetworkPolicy | Gateway | OP-06、第 8 节落点检查 |
| ④ 租户注册表 + 同步状态 | **平台自己**（这是要你自己写的部分） | 见 9.3 | 平台 | 本 POC 用手工等价 |

未查明（诚实标注）：0.1.7 的 SQLite 是"一张 `objects` 表 + protobuf 二进制 payload"（`id, object_type, name, scope, workspace, labels, version, status, payload, created_at_ms, updated_at_ms`）。我没在这张表里看到独立的 `member` object_type，workspace 行只有 67–77 字节，装不下成员列表；成员关系的物理存法没查实（可能是 WAL 未快照，也可能是内部结构）。要读它的稳定接口只有 `workspace member list`。

### 9.3 平台上要写的那个 Controller（伪代码，就是这一件事）

```yaml
# 租户注册表（平台拥有；这是唯一"新接一个系统"要加的东西，一条）
tenant:
  id: T-50933
  namespace: t-50933              # = workspace 名；DNS-1123、≤19 字符
  idp_groups: {user: T-50933-USER, admin: T-50933-ADMIN}
  network_policy: required        # OpenShell 的策略只管沙箱 Pod，普通 Pod 靠 Capsule/Antrea
```

```python
# 每次租户 ns 开通 / 每次目录组成员变化时跑（幂等）
def onboard(t):                       # 只在建租户时
    kubectl.apply(ns(t.namespace, labels={"openshell.ai/workspace": "true",
                                          "platform.io/tenant": t.id}))
    helm.upgrade("openshell-workspace", in=t.namespace)     # SA + Role + SSH ingress
    os.workspace_create(name=t.namespace)                   # 名字必须一模一样

def sync_members(t):                  # 周期跑，或订阅 IdP 组变化事件
    want = {(g.subject, "admin") for g in idp.members(t.idp_groups.admin)} | \
           {(g.subject, "user")   for g in idp.members(t.idp_groups.user)}
    have = {(m.subject, m.role) for m in os.member_list(workspace=t.namespace)}   # 以 OpenShell 为准
    for s, r in want - have: os.member_add(workspace=t.namespace, subject=s, role=r)
    for s, r in have - want: os.member_remove(workspace=t.namespace, subject=s)   # 少了这步就权限滞留
```

要点：
- 同步器自己要一个**机器身份**：在 IdP 里建 service account，组里给 `os-admin`，用它的 token 调 OpenShell（否则没人能加成员）。
- 比对**必须以 OpenShell 为准**（`member list`），不要只记自己的账——中间失败过就会漂移。
- 角色变更没有 update：`remove` + `add`。
- 命名：`T-50933` → `t-50933`（大写、点、下划线都不行；总长 ≤19）。这条要在租户注册表里做一次转换并校验，别让运维手写。
- 删租户的顺序：先清沙箱 → 再 `workspace delete` → 最后平台删 ns（OP-18：反了会卡在 Terminating）。

## 10. 角色名到底在哪定义（R-01…R-04，`92-roles-where.sh`）

判定见 `evidence-20261123T121127Z.md`。一句话：**角色名只在 Gateway 配置里定义（可以随便起名）；
但 token 里必须字面出现它，所以 IdP 侧至少要有一个全平台共用的值 —— 且只有一个，不随租户增长。**

```toml
[openshell.gateway.oidc]
roles_claim = "realm_access.roles"    # 支持点分路径（chart values.yaml 里就写了 Keycloak/Entra/Okta 的写法）
user_role   = "openshell-user"       # 普通操作门槛，全平台一个值
admin_role  = "openshell-admin"      # 只给平台运维；不配就是没有 Platform Admin
audience    = "openshell-cli"
```

实测要点：

- R-01 把 `roles_claim` 换成 Keycloak 默认的 `realm_access.roles` 一样能用 → 不需要在 IdP 里造自定义 claim 名。
- R-02 角色数组为空的用户被拒：`role 'os-user' required`。OpenShell 不去 IdP 注册任何东西，也不凭空造角色。
- R-03 ⚠️ **`adminRole`/`userRole` 都留空 ≠ 没有角色门**：0.1.7 会回退到内置默认名，所有调用报 `role 'openshell-user' required`
  （chart 注释里写的 "authentication-only mode" 不是"任何人都放行"）。好处是可以直接沿用这个默认名，少配一个字符串。
- R-04 `user_role`/`admin_role` 各只接受**一个**字符串，没有列表/前缀/通配 → 每租户的 `T-<id>-USER`/`T-<id>-ADMIN`
  不能拿来当它们用；租户内的管理员走 workspace 成员角色 `admin`（§8）。

IdP 侧三选一（都不随系统数量增长）：

1. 目录里加一个组/角色 `openshell-user`（+ 一个 `openshell-admin`），把会用沙箱的人都放进去 —— 最省事，总共两个。
2. 不动目录：只在 client/scope 上注入（Keycloak Hardcoded claim / 组→自定义 claim，ADFS issuance transform rules，Dex static client）。
3. 什么都不加：`adminRole`/`userRole` 留空，沿用内置默认名 `openshell-user`（R-03），token 里仍要出现它。
