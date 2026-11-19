# OpenShell Workspace 手工 demo

> 对齐 NVIDIA 文档：[How it works → Workspaces](https://docs.nvidia.com/openshell/how-it-works/workspaces)
> 实测版本：OpenShell chart / CLI **0.1.7**，kind 集群 `kind-agent-runtime-poc`。
> 本文所有输出均为 **2026-11-15** 在 `root@192.168.5.190` 上实跑所得，不是示意。
>
> 这是一份**手工** demo：每一步都给出可直接粘贴的命令、预期输出，以及"这一拍证明什么"。
> 自动化回归矩阵仍以 [`../phases/14-identity-federation.sh`](../phases/14-identity-federation.sh) 为准
> （G-01…G-13 与本文同源）。

---

## 0. 一句话目标

**一台 Gateway、两个 Workspace、三个 OIDC 身份**，用成员资格证明：

- Workspace 是资源隔离边界，不是命名习惯；
- 身份来自目录（LDAP → Keycloak → JWT），Gateway 按 `subject` 授权；
- 边界随**成员资格**移动，而不是随 Workspace 名字；
- 每一次拒绝都能在 Gateway 的 OCSF 日志里取证。

### 本文证明什么 / 不证明什么

| 证明 | 不证明 |
| --- | --- |
| OpenShell 侧 Workspace 的可见性与操作隔离 | Kubernetes 侧 namespace/RBAC 隔离（见 `phases/14` 的 N-xx 用例） |
| Platform Admin / Workspace Admin / Workspace User 三级权限 | `scopesClaim` 细粒度 scope（本环境显式关闭） |
| 成员资格按 OIDC `subject` 绑定、可增删 | 目录组自动同步为 Workspace 成员（产品当前不做，需自建控制器） |
| 拒绝原因可由调用方和 Gateway 两侧看到 | 审计日志的长期留存/外发（OCSF 只落在节点文件 + OTLP） |

---

## 1. 拓扑与身份

```text
                    ┌──────────────────────────────┐
  LDAP（唯一目录） → │ Keycloak realm: aisanbox      │
  alice/bob/tadmin  │ JWT: sub=entryUUID, groups    │
                    └───────────────┬──────────────┘
                                    │ OIDC（issuer https://172.22.0.3:31443/realms/aisanbox）
                                    ▼
                    ┌──────────────────────────────┐
                    │ Gateway p3-openshell-0        │
                    │ poc3-gateway ns               │
                    │   ws-tenant-a  ← alice        │
                    │   ws-tenant-b  ← bob          │
                    │   default      （平台默认）    │
                    └──────────────────────────────┘
```

| 身份 | 目录组 → JWT `groups` | OpenShell 角色 | 用途 |
| --- | --- | --- | --- |
| `tadmin` | `os-admin`, `os-user`, `tenant-a-users` | Platform Admin | 建/删 Workspace、分配 Workspace Admin |
| `alice` | `os-user`, `tenant-a-users`, `tenant-a-owners` | Workspace User | tenant-a 的普通用户 |
| `bob` | `os-user`, `tenant-b-users`, `tenant-b-owners` | Workspace User | tenant-b 的普通用户 |

> ⚠ **`subject` 不是用户名，也不是固定值。** 它是目录条目的 `entryUUID`（Keycloak 用
> `24-claim-sub-from-ldap` 把 `sub` 映射过去）。目录重新灌入后 `entryUUID` 会变，
> 旧的成员记录会**静默失效**。所以每一轮都要用 `whoami` 现取，不要把 UUID 抄进脚本。

---

## 2. 开演前 60 秒自检

以下命令都在 **192.168.5.190** 上执行：

```bash
ssh root@192.168.5.190
cd /root/poc2
C=./vendor/openshell-cli-0.1.7/openshell
export OPENSHELL_GATEWAY_INSECURE=true     # 自签证书，仅 demo 环境
```

四件事必须同时成立：

```bash
# 1) Gateway 在跑
kubectl --context kind-agent-runtime-poc -n poc3-gateway get pod p3-openshell-0
# 期望: 1/1 Running

# 2) Keycloak realm 的 discovery 可达
curl -sk -o /dev/null -w '%{http_code}\n' \
  https://172.22.0.3:31443/realms/aisanbox/.well-known/openid-configuration
# 期望: 200

# 3) CLI profile 的 token 没过期
$C -g p3-tadmin whoami
# 期望: Current User / Name: tadmin；若报 cached OIDC token has expired → 见 §7.2 重新登录

# 4) 环境是干净的（没有残留 Workspace 抢名字）
$C -g p3-tadmin workspace list
# 期望: NAME=default 一行
```

> 每条 CLI 命令都会先在 **stdout** 打一行
> `WARN openshell_sdk::transport: TLS certificate verification is disabled`。
> 这是预期的；但**解析 JSON 前必须先剥掉它**（从第一个 `{` 开始取），否则会得到
> `JSONDecodeError`，看起来像 Gateway 返回了坏数据。

---

## 3. 逐拍脚本

先取三个人的 subject（后面所有 `member add` 都用它）：

```bash
subj() {
  $C -g "$1" whoami -o json 2>/dev/null \
    | sed -n '/^{/,$p' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["subject"])'
}
SUB_T=$(subj p3-tadmin)
SUB_A=$(subj p3-alice)
SUB_B=$(subj p3-bob)
echo "tadmin=$SUB_T"; echo "alice=$SUB_A"; echo "bob=$SUB_B"
```

---

### 第 1 拍：身份先于权限（`whoami`）

```bash
$C -g p3-tadmin whoami -o json
$C -g p3-alice  whoami -o json
$C -g p3-bob    whoami -o json
```

真实输出（节选）：

```json
{
  "display_name": "tadmin",
  "identity_provider": "oidc",
  "roles": ["os-user", "tenant-a-users", "os-admin"],
  "scopes": [],
  "subject": "f50afdb2-74f3-1041-8560-1329f54d68f0"
}
```

```json
{
  "display_name": "alice",
  "identity_provider": "oidc",
  "roles": ["os-user", "tenant-a-users", "tenant-a-owners"],
  "scopes": [],
  "subject": "f50a8d46-74f3-1041-855f-1329f54d68f0"
}
```

**这一拍证明**：调用者是谁由 OIDC token 决定；`subject` 与目录里的 `entryUUID` 逐字相同。

**讲解词**：*"Gateway 不认用户名，只认 token 里的 subject。后面所有授权都挂在这个值上。"*

---

### 第 2 拍：只有 Platform Admin 能建 Workspace

```bash
$C -g p3-tadmin workspace create --name ws-tenant-a
$C -g p3-tadmin workspace create --name ws-tenant-b
$C -g p3-alice  workspace create --name ws-by-alice
```

真实输出：

```text
✓ Created workspace ws-tenant-a
✓ Created workspace ws-tenant-b

Error:   × code: 'The caller does not have permission to execute the specified
  │ operation', message: "role 'os-admin' required"
```

**这一拍证明**：Workspace 的创建权在 Platform Admin（`os-admin`）手里，普通 `os-user` 连
自己"名下"的 Workspace 都建不出来。

---

### 第 3 拍：成员资格按 subject 绑定

```bash
$C -g p3-tadmin workspace member add --workspace ws-tenant-a --subject "$SUB_A" --role user
$C -g p3-tadmin workspace member add --workspace ws-tenant-b --subject "$SUB_B" --role user
$C -g p3-tadmin workspace member list --workspace ws-tenant-a
$C -g p3-tadmin workspace member list --workspace ws-tenant-b --output json
```

真实输出：

```text
✓ Added f50a8d46-74f3-1041-855f-1329f54d68f0 to workspace ws-tenant-a as user
✓ Added f50b6a54-74f3-1041-8561-1329f54d68f0 to workspace ws-tenant-b as user

SUBJECT                               ROLE
f50a8d46-74f3-1041-855f-1329f54d68f0  user
```

```json
{
  "members": [
    { "role": "user", "subject": "f50b6a54-74f3-1041-8561-1329f54d68f0" }
  ],
  "next_page_token": ""
}
```

**Workspace Admin 委派（可选加演）**：Platform Admin 可以给某个人 `admin` 角色；
Workspace Admin 能加/删 `user`，但**不能**再分配 `admin`。

```bash
$C -g p3-tadmin workspace create --name ws-role-test
$C -g p3-tadmin workspace member add --workspace ws-role-test --subject "$SUB_A" --role admin
$C -g p3-alice  workspace member add --workspace ws-role-test --subject "$SUB_B" --role user
$C -g p3-alice  workspace member add --workspace ws-role-test --subject "$SUB_B" --role admin
```

真实输出：

```text
✓ Added … to workspace ws-role-test as admin
✓ Added … to workspace ws-role-test as user

Error:   × code: 'The caller does not have permission to execute the specified
  │ operation', message: "only platform admins can assign the workspace admin
  │ role"
```

清理：

```bash
$C -g p3-tadmin workspace delete ws-role-test
```

**这一拍证明**：三级权限是真实的（Platform Admin → Workspace Admin → Workspace User），
不是"有 Workspace 就什么都能改"。

---

### 第 4 拍：可见性就是隔离

```bash
$C -g p3-tadmin workspace list
$C -g p3-alice  workspace list
$C -g p3-bob    workspace list
```

真实输出：

```text
NAME         STATUS        CREATED               LABELS
default      Active        2026-11-15 04:06:47
ws-tenant-a  Active        2026-11-15 04:07:02
ws-tenant-b  Active        2026-11-15 04:07:03

# alice
NAME         STATUS        CREATED               LABELS
ws-tenant-a  Active        2026-11-15 04:07:02

# bob
NAME         STATUS        CREATED               LABELS
ws-tenant-b  Active        2026-11-15 04:07:03
```

**这一拍证明**：同一个 Gateway 内，alice 根本看不到 `ws-tenant-b` 存在；`tadmin`
因为是 Platform Admin 才看得到全部（连 `default` 也能看到）。

> 如果一个用户 `workspace list` 是 `No workspaces found.`，不是 Gateway 坏了，
> 而是这个 subject **没有任何成员关系** —— 正好是文档 "Diagnose access denials" 的第一条。

---

### 第 5 拍：目标 Workspace 的两种写法（以及默认值的坑）

```bash
$C -g p3-alice --workspace ws-tenant-a sandbox list
OPENSHELL_WORKSPACE=ws-tenant-a $C -g p3-alice sandbox list
$C -g p3-alice sandbox list            # 不带 --workspace
```

真实输出：

```text
（前两条都返回）
No sandboxes found.

（第三条）
Error:   × code: 'The caller does not have permission to execute the specified
  │ operation', message: "not a member of workspace 'default'; ask a platform
  │ admin to run: openshell workspace member add --workspace 'default'
  │ --subject 'f50a8d46-…' --role user"
```

**这一拍证明**：CLI 省略 `--workspace` 时**故意**落到 `default`，不是"最近用过的
Workspace"。演示时如果突然被拒，先看自己有没有带 `--workspace`。

---

### 第 6 拍：同 Workspace 可用、跨 Workspace 被拒

```bash
# 自己的 Workspace：成功
$C -g p3-alice --workspace ws-tenant-a sandbox create --name p3-a1 \
  --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never

# 对方的 Workspace：被拒
$C -g p3-alice --workspace ws-tenant-b sandbox create --name p3-a2 \
  --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never

$C -g p3-alice --workspace ws-tenant-a sandbox list
$C -g p3-alice --workspace ws-tenant-b sandbox list
```

真实输出：

```text
Created sandbox: p3-a1

  [0.0s] Requesting compute...
[4.0s] Sandbox allocated
[4.6s] Image pulled
[5.1s] Pulling image alpine:latest
[7.0s] Image pulled (3 MB)

Error:   × code: 'The caller does not have permission to execute the specified
  │ operation', message: "not a member of workspace 'ws-tenant-b'; ask a
  │ platform admin to run: openshell workspace member add --workspace 'ws-
  │ tenant-b' --subject 'f50a8d46-…' --role user"

NAME   CREATED              PHASE
p3-a1  2026-11-15 04:07:03  Ready
```

**跨 Workspace 列表也拒**（不是"列出来但操作失败"）：

```text
Error:   × … message: "not a member of workspace 'ws-tenant-b'; …"
```

**只有 Platform Admin 能跨 Workspace 看全量**：

```bash
$C -g p3-tadmin sandbox list --all-workspaces
$C -g p3-alice  sandbox list --all-workspaces
```

```text
WORKSPACE    NAME   CREATED              PHASE
ws-tenant-a  p3-a1  2026-11-15 04:07:03  Ready

Error:   × … message: "platform admin role required for cross-workspace
  │ operations"
```

**这一拍证明**：隔离同时作用在**读**和**写**上；跨租户的"上帝视角"需要
`os-admin`，不是普通用户的隐藏开关。

---

### 第 7 拍：边界随成员资格移动（最关键的一拍）

先让 alice 成为 `ws-tenant-b` 的 user，重复刚才被拒的操作，再把她移出：

```bash
$C -g p3-tadmin workspace member add --workspace ws-tenant-b --subject "$SUB_A" --role user
$C -g p3-alice workspace list
$C -g p3-alice --workspace ws-tenant-b sandbox create --name p3-a3 \
  --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never

$C -g p3-tadmin workspace member remove --workspace ws-tenant-b --subject "$SUB_A"
$C -g p3-alice workspace list
```

真实输出：

```text
✓ Added f50a8d46-… to workspace ws-tenant-b as user

# alice 现在看到两个
NAME         STATUS        CREATED
ws-tenant-a  Active        2026-11-15 04:07:02
ws-tenant-b  Active        2026-11-15 04:07:03

Created sandbox: p3-a3          # 刚才同一个操作，现在成功

✓ Removed f50a8d46-… from workspace ws-tenant-b

# alice 又只剩一个
NAME         STATUS        CREATED
ws-tenant-a  Active        2026-11-15 04:07:02
```

**这一拍证明**：被拒不是因为"名字里带 tenant-a"或"这个用户永远被拒"，而是因为成员表里
没有那一行。把它加上，边界移动；删掉，边界恢复。**正向对照**让"被拒"不再是自证。

**讲解词**：*"隔离不是写死在名字上的。同一秒钟、同一个用户，只改成员表，权限就变了。"*

---

### 第 8 拍：标签是创建时属性

```bash
$C -g p3-tadmin workspace create --name ws-demo-labels --label env=dev --label team=ml
$C -g p3-tadmin workspace list --label-selector env=dev,team=ml
$C -g p3-tadmin workspace get ws-demo-labels
$C -g p3-tadmin workspace delete ws-demo-labels
```

真实输出：

```text
✓ Created workspace ws-demo-labels

NAME            STATUS        CREATED               LABELS
ws-demo-labels  Active        2026-11-15 04:07:40   env=dev, team=ml

Workspace:
  Name: ws-demo-labels
  Id: 0a5e513e-7ac4-458d-910e-26514f0b89f7
  Resource version: 1
  Created: 2026-11-15 04:07:40
  Labels: team=ml, env=dev
```

**这一拍证明**：标签在创建时写入、可按选择器过滤；**没有** workspace update 操作，
创建后不能改标签（要改只能重建）。映射到生产就是"用标签做租户分组/计费"时，
标签必须在开通时一次写对。

---

### 第 9 拍：拒绝可取证（Gateway 侧）

上面每一次拒绝，Gateway 都会打一条 OCSF 记录。演示时另开一个终端：

```bash
kubectl --context kind-agent-runtime-poc -n poc3-gateway \
  logs p3-openshell-0 --tail=400 | grep DENIED | tail -8
```

真实输出（与上面的操作一一对应）：

```text
OCSF API:OTHER [MED] DENIED user:f50a8d46-… from 10.244.0.1:54955 [op:/openshell.v1.OpenShell/CreateWorkspace reason:missing_role]
OCSF API:OTHER [MED] DENIED user:f50a8d46-… [op:/openshell.v1.OpenShell/CreateSandbox workspace:ws-tenant-b reason:not_workspace_member]
OCSF API:OTHER [MED] DENIED user:f50a8d46-… [op:/openshell.v1.OpenShell/ListSandboxes workspace:ws-tenant-b reason:not_workspace_member]
OCSF API:OTHER [MED] DENIED user:f50a8d46-… [op:/openshell.v1.OpenShell/ListSandboxes reason:platform_admin_required]
OCSF API:OTHER [MED] DENIED user:f50a8d46-… [op:/openshell.v1.OpenShell/ListSandboxes workspace:default reason:not_workspace_member]
```

**这一拍证明**：拒绝不是"客户端本地拦了一下"——Gateway 记录了 `subject`、gRPC 方法、
目标 Workspace 和机器可读的 `reason`。这正是后面接 SIEM/审计的入口。

---

### 第 10 拍：删除语义（谨慎演示）

安全的部分：`default` 永远删不掉。

```bash
$C -g p3-tadmin workspace delete default
```

```text
Error:   × code: 'The system is not in a state required for the operation's
  │ execution', message: "the default workspace cannot be deleted"
```

**危险但值得讲的部分**：Workspace 必须**先清空**才能删。对非空 Workspace 直接
`delete`，会返回错误，**但状态已经进入 `Terminating` 并占住名字**：

```text
Error:   × code: 'The system is not in a state required for the operation's
  │ execution', message: "workspace 'ws-tenant-a' still contains resources:
  │ sandbox, sandbox policy"
```

之后 `workspace list` 里它会一直是 `Terminating`，下一轮 `create` 得到
`already exists`、`member add` 得到 `is being deleted`。

> ⚠ **不要在还要用的 Workspace 上演示这一条。** 正确顺序永远是
> **sandbox → workspace**，并且等它从 `list` 里消失（删除是异步的）：
>
> ```bash
> $C -g p3-tadmin --workspace ws-tenant-a sandbox delete --all
> $C -g p3-tadmin --workspace ws-tenant-b sandbox delete --all
> $C -g p3-tadmin workspace delete ws-tenant-a
> $C -g p3-tadmin workspace delete ws-tenant-b
> ```
>
> 实测清空后删除，**一轮 4 秒轮询内**就从 list 消失了。若已经卡死，见 §7.3。

---

## 4. 完整清场（可重复跑）

```bash
$C -g p3-tadmin --workspace ws-tenant-a sandbox delete --all
$C -g p3-tadmin --workspace ws-tenant-b sandbox delete --all
$C -g p3-tadmin workspace delete ws-tenant-a
$C -g p3-tadmin workspace delete ws-tenant-b

# 等名字真的消失，不要 sleep 5 拍脑袋
for i in $(seq 1 30); do
  L=$(OPENSHELL_GATEWAY_INSECURE=true $C -g p3-tadmin workspace list 2>/dev/null \
      | grep -oE 'ws-tenant-[ab]')
  [ -z "$L" ] && { echo "CLEAR after ~$((i*4))s"; break; }
  sleep 4
done

$C -g p3-tadmin workspace list
# 期望: 只剩 default
```

实测清场输出：

```text
✓ Deleted sandbox p3-a1
✓ Deleted sandbox p3-a3
✓ Deleted workspace ws-tenant-a
✓ Deleted workspace ws-tenant-b
CLEAR after ~4s

NAME     STATUS        CREATED
default  Active        2026-11-15 04:06:47
```

---

## 5. 与 NVIDIA 文档的逐节映射

| 文档章节 | 本文对应 | 实测结论 |
| --- | --- | --- |
| Workspace model（隔离边界） | 第 4/6 拍 | ✅ 不可见 + 不可操作 |
| Roles and permissions | 第 2/3 拍 | ✅ Platform Admin / Workspace Admin / User 三级成立 |
| Identity（`whoami`） | 第 1 拍 | ✅ `subject` = 目录 `entryUUID`，两侧一致 |
| Create a workspace and add members | 第 2/3 拍 | ✅ 按 subject 授权 |
| List and remove members | 第 3/7 拍 | ✅ 增删即时生效 |
| Labels | 第 8 拍 | ✅ 创建时可写、可 selector 过滤；无 update |
| Target a workspace | 第 5 拍 | ✅ `--workspace` / `OPENSHELL_WORKSPACE`；默认 `default` |
| Diagnose access denials | 第 4/9 拍 | ✅ 调用方有明确 message，Gateway 有 OCSF |
| Delete a workspace | 第 10 拍 | ⚠️ 必须先清空；非空删除会卡 `Terminating` |
| Demo-able workflow（文档末尾 9 步） | 第 1–10 拍 | ✅ 全部覆盖，且多了"边界随成员移动"的正对照 |

---

## 6. 常见现象 → 处置

| 现象 | 真正原因 | 处置 |
| --- | --- | --- |
| `workspace list` 返回 `No workspaces found.` | 该 subject 没有任何成员关系 | 让 Platform Admin `member add`；先 `whoami` 拿 subject |
| 每条命令都被 `not a member of workspace 'default'` 拒 | 忘了 `--workspace`，CLI 默认落 `default` | 显式加 `--workspace ws-tenant-a` |
| `workspace create` 报 `role 'os-admin' required` | 调用者只有 `os-user` | 换 Platform Admin；或让平台补"目录组 → Workspace 成员"的同步控制器 |
| `member add` 报 `only platform admins can assign the workspace admin role` | Workspace Admin 只能分配 `user` | 提升角色只能由 Platform Admin 做 |
| `workspace create` 报 `already exists`，或 `member add` 报 `is being deleted` | 上一轮残留的 `Terminating` Workspace 占着名字 | 先清 sandbox；仍卡住见 §7.3 |
| `cached OIDC token has expired` | Keycloak 重启 / realm 重建导致 refresh token 失效 | 重新走 CLI device flow，见 §7.2 |
| `whoami` 正常但 `workspace list` 为空，且刚重灌过目录 | 目录 `entryUUID` 变了，旧成员记录全部失效 | 用新的 subject 重新 `member add` |
| `-o json` 解析失败 | WARN 行在 **stdout**，混进了 JSON | 从第一个 `{` 开始截取再解析 |
| Keycloak discovery 返回 404 | Keycloak 的 `dev-file` 数据不持久，realm 不在了 | 重灌 LDAP + 重跑 realm Job，见 §7.1 |

---

## 7. 环境恢复（演示前故障处理）

### 7.1 Keycloak 里 realm/用户没了（discovery 404）

Keycloak 用 `--db=dev-file`，数据在容器可写层（见 `identity/20-keycloak.yaml` 的注释）：
Pod 重建就丢 realm，本次实测连容器重启后也没了。另外 `kc-realm` Job 有 1 小时 TTL。
恢复顺序必须是**先目录、后 realm**，否则联邦用户导不进来：

```bash
cd /root/poc2
kubectl --context kind-agent-runtime-poc apply -f identity/10-seed-job.yaml
kubectl --context kind-agent-runtime-poc -n identity \
  wait --for=condition=complete job/ldap-seed --timeout=90s

kubectl --context kind-agent-runtime-poc -n identity delete job kc-realm --ignore-not-found
kubectl --context kind-agent-runtime-poc apply -f identity/30-keycloak-realm.yaml
# Job 可能显示 Running 但日志已到 "=== 完成 ==="；以日志为准
kubectl --context kind-agent-runtime-poc -n identity logs job/kc-realm --tail=5
```

验证：

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
  https://172.22.0.3:31443/realms/aisanbox/.well-known/openid-configuration
# 200
```

> 重灌目录会生成**新的 entryUUID**，所以所有旧的 `member add` 都失效。
> 这是演示的一部分（见 §6），不是环境坏了。

### 7.2 CLI token 过期 / 重新登录

```bash
cd /root/poc2
cp identity/certs/issuer-ca.crt /tmp/issuer-ca.crt
cp openshell3/device-approve.py .        # 脚本里按相对路径找它（BASH_SOURCE 在 ssh 下为空）
export CLI=/root/poc2/vendor/openshell-cli-0.1.7/openshell
export GW_EP=https://172.22.0.3:31444
export PASS=poc3pass
ISSUER="$(kubectl --context kind-agent-runtime-poc -n identity \
  get cm kc-config -o jsonpath={.data.issuer_url})/realms/aisanbox"
source /root/poc2/openshell3/lib-cli-login.sh

for u in alice bob tadmin; do
  cli_login_as p3-$u $u $PASS "$ISSUER" "$GW_EP" && echo "$u OK" || echo "$u FAIL"
done
```

### 7.3 Workspace 卡在 `Terminating`

先确认 sandbox 已经删干净：

```bash
$C -g p3-tadmin --workspace ws-tenant-a sandbox list
```

仍然卡住时（这是 0.1.7 的已知现象，README §12.7 也记了），只能重建 Gateway 的
SQLite 状态卷。**代价：所有 Workspace/成员关系清空，只剩 `default`。**

```bash
kubectl --context kind-agent-runtime-poc -n poc3-gateway \
  scale statefulset p3-openshell --replicas=0
kubectl --context kind-agent-runtime-poc -n poc3-gateway \
  wait --for=delete pod/p3-openshell-0 --timeout=90s
kubectl --context kind-agent-runtime-poc -n poc3-gateway \
  delete pvc openshell-data-p3-openshell-0
kubectl --context kind-agent-runtime-poc -n poc3-gateway \
  scale statefulset p3-openshell --replicas=1
kubectl --context kind-agent-runtime-poc -n poc3-gateway \
  wait --for=condition=Ready pod/p3-openshell-0 --timeout=150s

$C -g p3-tadmin workspace list
# 期望: 只剩 default
```

> 这是产品边界，不是 demo 技巧：**Workspace 删除没有 force/purge**，失败后名字仍被占用。
> 生产上必须给"目录组 → Workspace 成员"和"清理孤儿 Workspace"补控制器。

---

## 8. 录制建议（可选）

- 建议 2 个终端：左边跑命令，右边常驻
  `kubectl -n poc3-gateway logs -f p3-openshell-0 | grep --line-buffered DENIED`，
  第 9 拍直接指过去。
- 重点录**第 7 拍**（边界随成员移动）：先被拒、加成员后成功、移出后再被拒，三段在同一分钟里。
- 每拍之间停 2–3 秒，等 `sandbox create` 的进度条走完再讲下一句。
- 不要录第 10 拍的"非空删除"实操；用一句"会卡 Terminating"带过即可。
