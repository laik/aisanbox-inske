# OpenShell 单租户安装手册（只装 OpenShell）

> 范围：**一个租户**、**只装 OpenShell 网关与沙箱运行时**。
> 身份提供方（OIDC IdP）、PostgreSQL、Agent Sandbox 控制器、入口/证书、监控由平台提供，
> 本文只做前置检查与引用，**不安装**这些组件（清单见 §9）。
>
> 结构与命令来自 POC4 实跑（PASS=33 / FAIL=0，chart 0.1.7），按单租户裁剪：
> 一个 Helm release、两个 namespace、Deployment + 外置 PostgreSQL + OIDC。
> 与 POC4 的唯一取值差异：`allowDriverConfig: false`（POC 为便于测试设为 true）。

---

## 0. 拓扑与命名

```
OIDC IdP ──(JWT)──┐
                  │
用户 ── openshell CLI ── HTTPS/gRPC ──▶ openshell Service (NodePort / 平台入口)
                                              │
                                    Deployment: openshell (N 副本)
                                              │
                        ┌─────────────────────┼──────────────────────┐
                        ▼                     ▼                      ▼
              PostgreSQL (平台提供)     ns: openshell-<tenant>   ns: openshell-<tenant>-runtime
              库 openshell / 用户        gateway / KEK / TLS      沙箱 Pod（Agent Sandbox 控制器）
```

| 对象 | 本手册取值 | 说明 |
|---|---|---|
| 租户标识 `TENANT` | 例如 `acme` | 只用于命名 |
| Gateway namespace `NS` | `openshell-<TENANT>` | 网关 Pod、两个 Secret、可选 CA ConfigMap |
| Runtime namespace `RT` | `openshell-<TENANT>-runtime` | 沙箱 Pod 与 workspace RBAC |
| Helm release | `openshell`（固定） | 每租户独立 ns，release 名可固定 |
| 镜像版本 `OS_VERSION` | `0.1.7` | chart 与 CLI 版本保持一致 |
| OIDC issuer | 平台提供 | 例：`https://id.example.com/realms/openshell` |
| OIDC audience | `openshell-cli` | CLI 的 client id |
| 管理员角色 | `os-admin` | 对应 IdP 的 claim 值 |
| 普通用户角色 | `os-user` | 同上 |
| 副本数 | `2` | 多副本**必须**外置 PG（chart 硬约束） |
| 对外入口 | NodePort（本手册） | 平台已有入口时见 §7.2 |

> **硬约束**：`workload.kind: deployment` 必须配 `server.externalDbSecret`；
> `replicaCount > 1` 也必须配外置 PG。否则 Helm 直接失败：
> `workload.kind=deployment requires server.externalDbSecret` /
> `multiple gateway replicas cannot share the default per-pod SQLite database`。

---

## 1. 平台需先提供（本文不安装）

安装前逐项确认，缺任何一项都会在 §5 失败：

1. **Kubernetes 集群**，kubectl 有目标 namespace 的读写权限，能读取集群级 CRD。
2. **Agent Sandbox CRD + 控制器**：
   ```bash
   kubectl get crd sandboxes.agents.x-k8s.io
   # 期望输出 sandboxes.agents.x-k8s.io 一行；不存在则找平台补齐，OpenShell 不负责装控制器
   ```
3. **PostgreSQL**（14+，建议 16），已建库和账号，**网络可达**，连接串形如：
   ```
   postgresql://openshell:<password>@<host>:5432/openshell?sslmode=require
   ```
   平台侧负责备份与高可用；库的容量/连接数见 §6。
4. **OIDC IdP**：可访问的 issuer URL（`/.well-known/openid-configuration` 正常）、
   一个 public client `openshell-cli`（启用 device code / 授权码）、
   以及 claim→角色映射（见 §3.3）。私有 CA 需能拿到 CA 证书文件。
5. **镜像仓库访问**：节点能拉取 `ghcr.io/nvidia/openshell/*`（gateway、workspace chart、
   沙箱基础镜像）。离线环境需平台先同步。
6. **工作站工具**：`helm` 3.12+、`kubectl`、`openssl`、`psql`（验证用）、
   `openshell` CLI（版本与 chart 一致）。

---

## 2. 参数一次填好

```bash
export TENANT=acme
export NS="openshell-$TENANT"                 # 网关
export RT="openshell-$TENANT-runtime"         # 沙箱
export OS_VERSION=0.1.7
export RELEASE=openshell                      # 固定；见 §5.2 的 Deployment 命名规则
export ISSUER='https://id.example.com/realms/openshell'   # 按实际改
export NODE_IP='10.0.0.10'                    # 节点地址或平台 LB 地址
export NODE_PORT=31450                        # 本租户独占的 NodePort
export DB_URI='postgresql://openshell:CHANGE_ME@pg.example.com:5432/openshell?sslmode=require'
export OIDC_CA_FILE=''                        # IdP 用公共 CA 时留空；私有 CA 填 ca.crt 路径
export KUBECTL_CTX=''                         # 留空用当前 context；多集群时填名称
KC() { if [ -n "$KUBECTL_CTX" ]; then kubectl --context "$KUBECTL_CTX" "$@"; else kubectl "$@"; fi; }
```

> 下文命令都使用这些变量。请先 `echo` 确认，再执行。

---

## 3. 创建 namespace 与 Secret

### 3.1 namespace

```bash
KC create namespace "$NS" --dry-run=client -o yaml | KC apply -f -
KC create namespace "$RT" --dry-run=client -o yaml | KC apply -f -
KC label namespace "$RT" openshell.ai/sandbox-runtime=true --overwrite
```

### 3.2 数据库 URI Secret（key 必须是 `uri`）

```bash
KC -n "$NS" create secret generic openshell-db \
  --from-literal=uri="$DB_URI" \
  --dry-run=client -o yaml | KC apply -f -
```

chart 会把它渲染成环境变量 `OPENSHELL_DB_URL`，不会出现 `--db-url sqlite:...` 参数。
Secret 名在 values 里由 `server.externalDbSecret` 指定，key 固定为 `uri`。

### 3.3 KEK（凭据加密密钥）

OpenShell 用 AES-256-GCM 加密库里的 Provider 凭据，密钥来自 Secret
`openshell-kek` 的 `key-encryption-key`。**这个值既不能丢，也不能换**：
丢了所有已存凭据解不开；换了同理。

```bash
# 只在第一次安装时生成；已有集群必须取回原值，不要重新生成
KEK=$(openssl rand -base64 32)

KC -n "$NS" create secret generic openshell-kek \
  --from-literal=key-encryption-key="$KEK" \
  --dry-run=client -o yaml | KC apply -f -
```

要点：

- `openssl rand -base64 32` 输出的**字符串本身**就是 Secret 的字面值，
  **不要再手工 base64 一次**（会变成双层编码，网关解不开）。
- 多副本共用一个 Secret，天然一致；不要每个副本一个 KEK。
- 备份数据库时**必须单独托管 KEK**（Vault/KMS/纸质封存均可）——
  PG 备份里没有它，恢复时缺 KEK 等于凭据全丢。
- 首次安装后把 KEK 存进平台的密钥托管，不要再执行上面的 `apply`。

### 3.4 OIDC 私有 CA（仅当 issuer 用私有 CA）

```bash
if [ -n "$OIDC_CA_FILE" ]; then
  KC -n "$NS" create configmap oidc-ca --from-file=ca.crt="$OIDC_CA_FILE" \
    --dry-run=client -o yaml | KC apply -f -
fi
```

ConfigMap 名必须等于 values 里的 `server.oidc.caConfigMapName`（本手册为 `oidc-ca`）。
IdP 用公共 CA 时，把 values 里该行删掉。

---

## 4. 安装沙箱侧 RBAC（workspace chart）

沙箱跑在 `RT`，需要 ServiceAccount、Role、NetworkPolicy。先装它，再装网关
（POC2/3/4 同一条顺序，反过来 supervisor 会起不来）。

```bash
helm upgrade --install "os-ws-$TENANT" \
  oci://ghcr.io/nvidia/openshell/openshell-workspace --version "$OS_VERSION" \
  --namespace "$RT" \
  --set gateway.serviceAccount.name=openshell \
  --set gateway.serviceAccount.namespace="$NS" \
  --set gateway.allowDriverConfig=false \
  --set sandboxServiceAccount.name=openshell-sandbox \
  --set networkPolicy.podSelector."app\.kubernetes\.io/instance"="$RELEASE" \
  --timeout 5m --wait
```

说明：

- `gateway.serviceAccount.namespace` 是网关 ns；沙箱 Pod 内的调用凭据靠这个 SA。
- `networkPolicy.podSelector` 必须匹配网关 Pod 上的 `app.kubernetes.io/instance`，
  本手册固定 release 为 `openshell`；若改名，这里同步改。
- 若平台已提供等价的 RBAC/NetworkPolicy，可跳过本步，但要保证
  `RT` 里的沙箱 SA 名与网关 values 的 `sandboxServiceAccount.name` 一致。

---

## 5. 安装网关

### 5.1 values 文件（保存为 `openshell-tenant-values.yaml`）

```yaml
# 单租户：Deployment + 外置 PostgreSQL + OIDC + 自签服务端 TLS
workload:
  kind: deployment

replicaCount: 2

workspaceResources:
  enabled: false            # 沙箱侧 RBAC 由 §4 的 workspace chart 提供

server:
  logLevel: info

  oidc:
    issuer: "__ISSUER__"              # 安装时用 --set 覆盖
    audience: "openshell-cli"
    rolesClaim: "groups"              # Keycloak 用 group 映射；也可 realm_access.roles
    adminRole: "os-admin"
    userRole: "os-user"
    caConfigMapName: "oidc-ca"        # 公共 CA 时删除本行
    jwksTtl: 600

  auth:
    allowUnauthenticatedUsers: false

  tls:
    enableMtls: false

  externalDbSecret: "openshell-db"    # key: uri
  credentialStorage:
    existingSecret: "openshell-kek"   # key: key-encryption-key

  drivers:
    kubernetes:
      workspaceMode: shared
      allowDriverConfig: false
      resourceAdmission:
        enabled: true
        requiredLabels:
          openshell.ai/sandbox-attachable: "true"
          example.com/workspace: "${workspace}"

resources:
  requests: {cpu: 250m, memory: 256Mi}
  limits:   {cpu: 1,    memory: 1Gi}

gatewayConfig:
  openshell:
    version: 2
  openshell.gateway:
    # 每个副本 10 条业务连接 + 4 条锁连接，见 §8
    database_max_connections: 10
    database_lock_max_connections: 4
```

### 5.2 安装

```bash
helm upgrade --install "$RELEASE" \
  oci://ghcr.io/nvidia/openshell/helm-chart --version "$OS_VERSION" \
  --namespace "$NS" \
  -f openshell-tenant-values.yaml \
  --set server.oidc.issuer="$ISSUER" \
  --set server.name="$NS" \
  --set server.sandboxNamespace="$RT" \
  --timeout 10m --wait
```

如果 §3.4 没用私有 CA，先从 values 里删掉 `caConfigMapName` 再执行，否则 Pod 会因
找不到 ConfigMap 卡住。

chart 首次启动自动执行数据库迁移（`_sqlx_migrations`），无需手工建表。

> **命名规则**：Helm 的 fullname 在 release 名已包含 chart 名时直接取 release 名。
> 因此 `RELEASE=openshell` 时 Deployment/Service 都叫 `openshell`；
> 若把 release 改名为 `os-acme`，名字就会变成 `os-acme-openshell`。
> 改名后请用 label 查实际名字：
> `KC -n "$NS" get deploy -l app.kubernetes.io/instance="$RELEASE" -o name`。
> 下文命令按 `RELEASE=openshell` 书写。

### 5.3 把 client TLS bundle 复制到 runtime ns

chart **不会跨 namespace** 复制这份 Secret；缺了它 supervisor 的 Pod 会卡在
`ContainerCreating`。

```bash
KC -n "$RT" get secret openshell-client-tls >/dev/null 2>&1 || \
  KC -n "$NS" get secret openshell-client-tls -o yaml | python3 -c "
import sys, yaml, json
o = yaml.safe_load(sys.stdin)
print(json.dumps({'apiVersion': 'v1', 'kind': 'Secret',
  'metadata': {'name': 'openshell-client-tls', 'namespace': '$RT'},
  'type': o['type'], 'data': o['data']}))" | KC apply -f -
```

---

## 6. 验证安装

### 6.1 Kubernetes 层

```bash
KC -n "$NS" get deploy,pod -l app.kubernetes.io/instance="$RELEASE"

# 必须是 Deployment，不能是 StatefulSet
KC -n "$NS" get deploy,sts

# 数据库来自 Secret，而不是 sqlite 参数
KC -n "$NS" get deploy openshell \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}{"\n"}'
# 期望：openshell-db

KC -n "$NS" get deploy openshell \
  -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
# 期望：不含 --db-url / sqlite:
```

### 6.2 数据库层（psql 在能连库的机器上执行）

```bash
psql "$DB_URI" -c "select version, description from _sqlx_migrations order by version;"
# 0.1.7 首次启动后应有 7 行：1,4,5,6,7,8,9
psql "$DB_URI" -c "select count(*) from objects;"
```

### 6.3 CLI 登录（产品自带 device flow）

在工作站执行（`--name` 是本地 profile 名，可自取）：

```bash
export OPENSHELL_NO_BROWSER=1          # 让 CLI 打印 URL，不尝试拉起浏览器
openshell gateway add "https://$NODE_IP:$NODE_PORT" \
  --name "$TENANT-admin" \
  --oidc-issuer "$ISSUER" \
  --oidc-client-id openshell-cli
```

按提示在浏览器打开它打印的 `https://<idp>/device?user_code=XXXX-XXXX`，
用**属于 `os-admin` 角色**的账号批准。成功后 token 在：

```
~/.config/openshell/gateways/<profile>/oidc_token.json
```

后续命令都带 profile：

```bash
openshell -g "$TENANT-admin" whoami
```

> 自签服务端 TLS 的测试环境需要 `OPENSHELL_GATEWAY_INSECURE=true`（CLI 会打印
> TLS 校验关闭的警告）；正式租户应由平台入口提供可信证书，不要长期用它。

### 6.4 冒烟用例（全部为 POC 实测命令形状）

```bash
P="$TENANT-admin"
WS=demo

openshell -g "$P" workspace create --name "$WS"
openshell -g "$P" workspace list

# 成员用 OIDC 的 sub 标识；从 whoami / IdP 里取普通用户的 subject
openshell -g "$P" workspace member add --workspace "$WS" --subject '<user-sub>' --role user

# 普通用户登录（另一个 profile）
openshell gateway add "https://$NODE_IP:$NODE_PORT" --name "$TENANT-user" \
  --oidc-issuer "$ISSUER" --oidc-client-id openshell-cli   # 用普通账号批准
openshell -g "$TENANT-user" --workspace "$WS" sandbox create \
  --name sb1 --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never
openshell -g "$TENANT-user" --workspace "$WS" sandbox list
```

`workspace list` / `sandbox list` 能看到对象即通过；非成员访问该 workspace 应被拒绝。

### 6.5 对外暴露（本手册的 NodePort）

```bash
KC -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: openshell-nodeport
  namespace: $NS
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/instance: $RELEASE
  ports:
    - name: grpc
      port: 8080
      targetPort: 8080
      nodePort: $NODE_PORT
YAML
```

POC 环境用 NodePort 是因为 kind 不做 `kubectl port-forward`；生产请走 §7.2。

---

## 7. 租户日常操作

### 7.1 成员与角色

- 管理员：IdP 侧授予 `os-admin`（或 values 里 `adminRole` 的取值），重新登录后生效。
- 普通成员：`workspace member add --workspace <ws> --subject <sub> --role user`。
- 移除成员：用 `openshell -g "$P" workspace member --help` 查看当前版本的子命令与 flag，
  参数与 add 时的 subject 对应。
- 角色 claim 由 `server.oidc.rolesClaim` 决定；IdP 改 claim 名时同步改 values。

### 7.2 平台已有入口 / 边缘 TLS

若平台用 Gateway API 终止 TLS，按 chart 的 `grpcRoute` 配置（`values-gateway-prod.yaml`
里有 HTTPS 443 + `certificateRefs` 的完整样例），并把 `server.disableTls` 设为 `true`、
入口到网关用明文 gRPC。此时不要把 NodePort 再暴露到集群外。
（该形态在 POC 中只做到 `helm template` 验证，未在集群实跑，见 `production/README.md` §12。）

### 7.3 Provider 与凭据

OpenShell 发行包**不自带 provider profile**。直接执行
`provider create --type openai` 会报 `provider profile 'openai' not found`，需要先导入：

```yaml
# my-profile.yaml（最小可用 profile；id 就是后面 --type 的取值）
id: my-provider-type
display_name: My Provider
credentials:
  - name: API_KEY
    required: true
```

```bash
openshell -g "$P" --workspace "$WS" profile import -f my-profile.yaml
# 输出 Expect：Imported 1 provider profile.

API_KEY=sk-xxx openshell -g "$P" --workspace "$WS" provider create \
  --name my-provider --type my-provider-type --credential API_KEY
# 输出 Expect：Created provider my-provider
```

凭据由 KEK 加密后写入 PG；**KEK 不变**才能在重启/升级后继续解密。

### 7.4 升级

1. 备份 PG，确认 KEK 已托管（§3.3）。
2. **升级时显式保持 1 副本**，避免多个新副本同时跑迁移
   （迁移在 Pod 启动时执行；values 里是 2，不覆盖会被 Helm 拉回 2）：
   ```bash
   helm upgrade "$RELEASE" oci://ghcr.io/nvidia/openshell/helm-chart \
     --version <新版本> --namespace "$NS" -f openshell-tenant-values.yaml \
     --set replicaCount=1 \
     --set server.oidc.issuer="$ISSUER" --set server.name="$NS" --set server.sandboxNamespace="$RT"
   KC -n "$NS" rollout status deploy/openshell --timeout=300s
   ```
3. 确认 `_sqlx_migrations` 里有新版本、Pod Ready 且 0 重启后，再升回 2 副本：
   ```bash
   helm upgrade "$RELEASE" oci://ghcr.io/nvidia/openshell/helm-chart \
     --version <新版本> --namespace "$NS" -f openshell-tenant-values.yaml \
     --set replicaCount=2 \
     --set server.oidc.issuer="$ISSUER" --set server.name="$NS" --set server.sandboxNamespace="$RT"
   ```
4. chart **不提供 down migration**：跨大版本升级前必须做库备份，回滚只能回到旧镜像 +
   旧库，不能靠 Helm rollback 撤销已执行的迁移。

### 7.5 卸载与数据保留

```bash
helm uninstall "$RELEASE" -n "$NS"          # 网关
helm uninstall "os-ws-$TENANT" -n "$RT"     # 沙箱侧 RBAC
```

注意：

- **PG 数据、KEK Secret、namespace 不会随 Helm 删除**；需要清理时显式删除，
  并确认已按平台流程归档。
- 删除租户前先清空业务对象，顺序为
  `sandbox delete --all` → `provider delete` → `profile delete` → `workspace delete`。
  workspace 里还有 provider/profile 时删除会被拒绝，原文：
  `workspace '...' still contains resources: provider profile`。
- 删 namespace 会连带删掉未归档的 Secret（含 KEK），务必先导出。

---

## 8. 容量与连接数

- 每个副本默认 **10 条业务连接 + 4 条锁连接 = 14**，连接池**惰性打开**，
  实测 3 个 Pod 时总连接数在 11–14 之间，这是观测值，不是上限。
- 2 副本按 `2 × 14 = 28` 给 PG 预留；还要叠加平台其他使用方。
- PG 的 `max_connections` 必须大于所有网关副本的连接预算之和，并留出运维连接。
- 多副本之间通过 PG 里唯一的 `reconciler_lease` 行协调；抢到租约的副本负责调谐，
  谁抢到取决于启动顺序，属正常现象。
- 沙箱数量、每个 workspace 的 supervisor 会话是另一维容量，压测前不要按 Pod 数推算。

---

## 9. 本文明确不包含

| 组件 | 由谁负责 |
|---|---|
| OIDC IdP（Keycloak 等）及其 realm/client/用户 | 平台，本文只消费 issuer 与 client id |
| PostgreSQL 的安装、高可用、备份、监控 | 平台，本文只写连接串与连接数预算 |
| Agent Sandbox CRD 与控制器 | 平台，本文只检查 `sandboxes.agents.x-k8s.io` |
| 入口网关、cert-manager、可信证书 | 平台；OpenShell 侧只提供 `grpcRoute` 配置位 |
| Prometheus / 日志采集 / 告警 | 平台；指标名见 `production/README.md` §9 |
| 多租户共享一个 runtime namespace | 不在本文范围；本手册每租户独立 ns |
| 多 release 共享同一 PG/KEK | 不在本文范围；单租户单 release |

---

## 10. 常见失败与定位

| 现象 | 原因 / 处理 |
|---|---|
| Helm 报 `workload.kind=deployment requires server.externalDbSecret` | values 缺 `server.externalDbSecret`，或 Secret 名拼错 |
| Helm 报 `multiple gateway replicas cannot share the default per-pod SQLite database` | `replicaCount>1` 但没配外置 PG，两者必须成对 |
| Pod 起不来，事件里找不到 `oidc-ca` | 用了私有 CA 却没建 ConfigMap；或公共 CA 却在 values 里留了 `caConfigMapName` |
| supervisor Pod 卡 `ContainerCreating` | runtime ns 缺 `openshell-client-tls`，执行 §5.3 |
| 登录报 issuer/JWKS 错误 | issuer 必须与 token 的 `iss` 完全一致（含结尾斜杠）；私有 CA 未挂载 |
| 登录成功但无权限 | claim 名（`rolesClaim`）或角色值（`os-admin`/`os-user`）与 IdP 不一致 |
| `provider profile 'openai' not found` | 发行包不带 profile，先 `profile import`（§7.3） |
| workspace 删不掉 | 里面还有 provider/profile，按 §7.5 顺序清理 |
| 换过 KEK 后旧凭据不可用 | KEK 必须与写入时一致；从备份/托管中取回原值，不要重新生成 |
| 想 `kubectl exec` 进网关容器排查 | 镜像为 distroless，没有 shell；看日志或用临时 curl Pod 抓指标 |

---

## 11. 验收清单

- [ ] `kubectl get crd sandboxes.agents.x-k8s.io` 存在
- [ ] `NS` / `RT` 已建，`RT` 带 `openshell.ai/sandbox-runtime=true`
- [ ] `openshell-db`（key `uri`）与 `openshell-kek`（key `key-encryption-key`）已建
- [ ] KEK 已存进平台密钥托管（不在 Git、不在聊天记录里）
- [ ] `helm get manifest` 中工作负载类型为 Deployment，副本数符合预期
- [ ] `OPENSHELL_DB_URL` 来自 Secret；args 中无 `sqlite:`
- [ ] `_sqlx_migrations` 有 7 行；Pod 0 重启
- [ ] `openshell gateway add` + device flow 登录成功，`whoami` 正常
- [ ] 管理员建 workspace，普通用户在其中建 sandbox 并能 list
- [ ] 非成员访问被拒绝
- [ ] 入口（NodePort 或平台路由）可从租户侧访问，证书校验符合预期
