# OpenShell 生产部署方案（Gateway：Deployment + 外置 PostgreSQL）

> 目标：把 POC4 验证过的「Deployment + 外部 PostgreSQL」形态，扩成一套可交付生产的部署方式。
> 脚本/清单都在本目录；POC4 的实测证据见仓库根目录 `README.md` §13。
>
> **POC4 实测过的**：Deployment、外置 PG、schema 自动创建、控制面对象共库、2 副本 HA、KEK 配置一致。
> **本目录新增、但未在 POC 集群实跑的**：托管 PG/CNPG、Gateway API 边缘 TLS、cert-manager、
> External Secrets、NetworkPolicy、PDB、监控告警、备份恢复。逐条列在 §12，别把「设计」当「已验证」。

---

## 0. 一句话结论

生产用 **一个 Helm release + 3 副本 Deployment + 一台高可用 PostgreSQL**，
不要让多个独立 release 共库（那是 POC 的验证形态，不是 chart 契约）。
边缘由 Gateway API（Envoy Gateway）终止 TLS，gateway 在集群内明文 + OIDC；
凭据 KEK 由一个独立 Secret 注入所有副本，且**终身不换**；
schema 由 gateway 启动时自动迁移，升级时先缩到 1 副本再升。

```
                    ┌───────────────┐
  CLI / SDK ──https──▶ Envoy Gateway │  ← cert-manager 签发 openshell.example.com
                    └───────┬───────┘
                            │ HTTP/2 (集群内明文, 8080)
                 ┌──────────▼──────────┐
                 │ openshell (Deploy)  │ ×3   ← 同一镜像、同一 KEK、同一 OIDC
                 │  peer relay :8080   │
                 └──────┬──────────────┘
                        │ TLS 5432 (pooler / 直连)
              ┌─────────▼─────────┐        ┌─────────────────┐
              │ PostgreSQL HA     │        │ openshell-runtime│
              │ 托管 或 CNPG ×3   │        │ Sandbox Pods     │
              └───────────────────┘        └─────────────────┘
                 ▲ 控制面对象                ▲ Sandbox 是 K8s 对象，不在 PG 里
```

---

## 1. 关键决策（以及为什么）

| 决策 | 选择 | 理由 |
|---|---|---|
| 部署单元 | **1 个 release**，`replicaCount: 3` | chart 的多副本检查只针对单 release；POC4 证明 2 副本杀 1 个仍 10/10 成功 |
| 共享数据库 | **禁止**多个 release 共用 | POC4 证明「技术上能」，但 chart 不承诺；KEK/OIDC/版本必须手工对齐，运维成本远大于收益 |
| 边缘 TLS | Gateway API 终止 TLS + `disableTls=true` + OIDC | chart 明确支持；避免把 mTLS 客户端证书分发给每个 CLI/用户 |
| 身份 | OIDC（Keycloak/Entra/Okta） | `allowUnauthenticatedUsers=false`；角色来自 `realm_access.roles`（或 `roles`/`groups`） |
| 凭据 | 默认 credential storage + **外部托管 KEK** | 不要用 chart 自动生成的 KEK（GitOps 下不可复现）；不要轮换 KEK（无重加密工具） |
| Sandbox 位置 | 独立 runtime namespace | 与 POC4 一致；Sandbox 是 `sandboxes.agents.x-k8s.io` 对象，PG 备份不覆盖它 |
| 数据库 | 托管 PG（首选）或 CloudNativePG 3 实例（备选） | 都要求 TLS、PITR、多 AZ；单机 PG 只配 POC |

---

## 2. 先决条件

| 组件 | 版本/要求 | 检查 |
|---|---|---|
| Kubernetes | ≥ 1.29，3+ 可调度节点（3 副本反亲和） | `kubectl version` |
| Agent Sandbox | `sandboxes.agents.x-k8s.io` CRD + controller | `kubectl get crd sandboxes.agents.x-k8s.io` |
| Gateway API | CRD `gateways` / `grpcroutes` | `kubectl get crd grpcroutes.gateway.networking.k8s.io` |
| Envoy Gateway | 与 chart 0.1.7 配套（chart 注释以 v1.4.1 为例） | `kubectl get gatewayclass eg` |
| cert-manager | ≥ 1.14，有可用 ClusterIssuer | `kubectl get clusterissuer` |
| PostgreSQL | 16.x，TLS，`max_connections` 按 §6 计算 | `psql '...?sslmode=verify-full' -c 'select version()'` |
| 存储 | 块存储 StorageClass（Sandbox / PG PVC） | `kubectl get sc` |
| 可观测 | Prometheus Operator（可选）+ OTLP collector（可选） | — |

---

## 3. 数据库

### 3.1 方案 A（推荐）：托管 PostgreSQL

RDS / Aurora / Cloud SQL / AlloyDB / Azure Flexible Server 均可，要求：

- **多 AZ / 自动故障转移**，开启自动备份 + PITR（≥7 天，金融类 ≥30 天）；
- 只允许集群出网段访问（PrivateLink / VPC peering / 防火墙），不开放公网；
- 强制 TLS；应用账号最小权限（只拥有 `openshell` 库）；
- `max_connections` 按 §6 调整（托管默认常是 100，不够 3 副本 + 滚动）；
- 连接串形如：

```
postgresql://openshell:<password>@<host>:5432/openshell?sslmode=verify-full&sslrootcert=/etc/openshell-db-ca/ca.crt
```

CA 通过 chart 的 `server.extraVolumes/extraVolumeMounts` 挂进 Pod（`values-gateway-prod.yaml` 有注释示例）。
> ⚠ `sslrootcert` 是否被当前镜像的 sqlx/rustls 组合采纳，**上生产前必须在预发验证**：
> `provider create` + 重启后 `provider get` 能走通，并且抓包确认是 TLS。
> 若 CA 校验路径不可用，最低退回 `sslmode=require`（加密但不验证身份）+ 网络层隔离。

### 3.2 方案 B：CloudNativePG（自建）

`postgres-cnpg.yaml` 提供：3 实例、反亲和、`max_connections=300`、强制 hostssl、
PgBouncer **session** 池、每日 S3 备份、30 天保留。

```bash
# 1) 先建 namespace 和备份凭据（Cluster 的 barmanObjectStore 会引用这个 Secret）
kubectl create ns openshell-db
kubectl -n openshell-db create secret generic openshell-pg-backup \
  --from-literal=ACCESS_KEY_ID=... --from-literal=SECRET_ACCESS_KEY=...

# 2) 安装 operator（版本按你的支持矩阵固定）
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml

# 3) 建集群 + pooler + 备份计划
kubectl apply -f postgres-cnpg.yaml

# 4) 等 3 实例就绪
kubectl -n openshell-db wait --for=condition=Ready cluster/openshell-pg --timeout=15m
```

生成 gateway 用的 Secret（先拿到 CNPG 的 app 凭据，再换成 pooler URI）：

```bash
# app secret 名: <cluster>-app
URI=$(kubectl -n openshell-db get secret openshell-pg-app -o jsonpath='{.data.uri}' | base64 -d)
echo "$URI"     # 先看清 host / 是否已有 query
# 把主库 host 换成 pooler（生产统一走 pooler），再按需加 sslmode：
URI=${URI/openshell-pg-rw.openshell-db.svc/openshell-pg-pooler-rw.openshell-db.svc}
case "$URI" in
  *\?*) URI="$URI&sslmode=require" ;;
  *)    URI="$URI?sslmode=require" ;;
esac
kubectl -n openshell create secret generic openshell-db --from-literal=uri="$URI"
```

> **池模式必须是 session**：gateway（sqlx）使用服务端 prepared statements，
> transaction 模式会随机报 `prepared statement ... does not exist`。`postgres-cnpg.yaml` 已固定。
> 这里用 `sslmode=require`（加密不验证身份）；要 verify-full 需把 CNPG 的 CA Secret
> 挂进 gateway Pod（`server.extraVolumes/extraVolumeMounts`），并在 URI 里加 `sslrootcert`。

---

## 4. Secret 与 KEK

### 4.1 KEK（最关键）

```bash
# 一次性生成：base64(32 random bytes)，存进 Vault/KMS + 离线托管
openssl rand -base64 32
kubectl -n openshell create secret generic openshell-kek \
  --from-literal=key-encryption-key='<上面的值>'
```

- chart 的要求是 Secret key 为 `key-encryption-key`，值是 **base64 编码的 32 字节**；
  不要对这个值再 base64 一次（POC4 踩过：`must decode to exactly 32 bytes`）。
- **KEK 不可轮换**：PG 里存的是 AES-256-GCM 密文，换 KEK 后旧凭据全部解不开，也没有重加密工具。
  泄露处置 = 换 KEK + 重建所有 provider（重新录入凭据）。
- **PG 备份不包含 KEK**：恢复演练必须同时恢复 Secret，否则备份里的凭据是废密文。

### 4.2 DB URI

`openshell-db`，key `uri`。由 External Secrets Operator 从 Vault/Secrets Manager 同步
（`secrets-external-secrets.yaml`），不要让 Helm 或 Git 持有连接串。

### 4.3 边缘证书

`certificate-edge-tls.yaml`：cert-manager 签发 `openshell-edge-tls`，
被 `grpcRoute.gateway.listener.tls.certificateRefs` 引用。`dnsNames` 必须和
`grpcRoute.hostnames`、DNS 解析一致。

---

## 5. 部署步骤

```bash
# 0) 先把占位全部替换掉（下面这条会把它们列出来）
grep -rnE 'example\.com|REPLACE-|203\.0\.113\.|10\.96\.0\.1' .
#    另外确认：镜像 digest、OIDC issuer、hostnames、资源量都已按环境改过
# 1) 数据库（§3）与两个 Secret（§4）
# 2) 一键部署（幂等）
DOMAIN=openshell.example.com \
ISSUER=https://id.example.com/realms/openshell \
APPLY_MONITORING=1 \
bash deploy-prod.sh
```

脚本做：前置检查 → runtime ns 的 workspace 资源 → `helm upgrade --install` gateway →
跨 ns 复制 `openshell-client-tls` → PDB/监控 → 部署后断言。

> release 名固定为 `openshell`：`values-gateway-prod.yaml` 的反亲和、`pdb-gateway.yaml` 的
> selector、脚本里的断言都按 `app.kubernetes.io/instance=openshell` 写的。改名要同步改这三处。

**手工等价步骤**（不信任脚本时）：

```bash
# 0. namespace
kubectl create ns openshell 2>/dev/null || true
kubectl create ns openshell-runtime 2>/dev/null || true

# 1. sandbox 资源（装到 runtime ns，SA 指向 gateway ns）
helm upgrade --install os-ws-openshell oci://ghcr.io/nvidia/openshell/openshell-workspace \
  --version 0.1.7 -n openshell-runtime \
  --set gateway.serviceAccount.name=openshell \
  --set gateway.serviceAccount.namespace=openshell \
  --set gateway.allowDriverConfig=false \
  --set sandboxServiceAccount.name=openshell-sandbox \
  --set networkPolicy.podSelector."app\.kubernetes\.io/instance"=openshell

# 2. gateway
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.1.7 -n openshell -f values-gateway-prod.yaml \
  --set server.oidc.issuer=https://id.example.com/realms/openshell \
  --set 'grpcRoute.hostnames[0]=openshell.example.com' --wait

# 3. 断言
kubectl -n openshell get deploy,pods
kubectl -n openshell get deploy openshell \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}'
```

---

## 6. 容量与扩缩容

### 6.1 连接数（最容易踩的坑）

每个 gateway 副本会打开 **`database_max_connections + database_lock_max_connections`
= 10 + 4 = 14** 条 PG 连接（启动日志
`sizing Postgres connection pools max_connections=10 lock_max_connections=4`）。

```
PG max_connections ≥ (副本数 + 滚动升级 surge) × 14 + pooler/运维余量
3 副本 + surge 1 = 4 × 14 = 56；再留 30% → ≥ 80
若加 PgBouncer：后端连接另算（session 模式 default_pool_size × 实例数）
本方案 CNPG 取 300
```

> 托管 PG 默认 `max_connections=100`，开 3 副本 + 滚动就只有 ~40 条余量，必须调大。

### 6.2 副本与 HPA

- 基线：固定 3 副本 + `podAntiAffinity`（3 节点）。节点少时改 `preferred`。
- 要开 HPA：`autoscaling.enabled=true`，`minReplicas≥3`，并按
  `maxReplicas × 14` 重算 PG 连接数。chart 文档明确：在**已有** release 上开启 HPA
  会短暂把副本数重置为 1，请在安装时开启或维护窗口内操作。
- 默认是 **per-sandbox supervisor**（每个 sandbox 自带 supervisor），本基线不配置
  `supervisor.replicas`。若改用共享 supervisor 池（`supervisor_topology=gateway`），
  chart 要求 `replicas>=2` 才有故障转移；本 POC 未实测该形态（§12）。

---

## 7. 升级与 schema 迁移

gateway 启动时用 sqlx 自动建表/迁移（POC4 观测：7 条 `_sqlx_migrations`；
第二个副本打印 `relation "_sqlx_migrations" already exists, skipping`）。

**生产升级流程**（避免多副本并发跑 DDL；`$URI` 取自 `openshell-db` Secret 的 `uri`）：

```bash
# 1. 记录当前 schema 版本
psql "$URI" -c 'select max(version) from _sqlx_migrations'

# 2. 缩到 1 副本（滚动期间只有一个进程执行迁移）
DEP=$(kubectl -n openshell get deploy -l app.kubernetes.io/instance=openshell -o jsonpath='{.items[0].metadata.name}')
kubectl -n openshell scale "deploy/$DEP" --replicas=1
kubectl -n openshell rollout status "deploy/$DEP"

# 3. 升级镜像/values
helm upgrade openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version <new> -n openshell -f values-gateway-prod.yaml --wait

# 4. 验证 migration 成功后再扩回（部署名用 label 查，不同 release 名会变）
DEP=$(kubectl -n openshell get deploy -l app.kubernetes.io/instance=openshell -o jsonpath='{.items[0].metadata.name}')
psql "$URI" -c 'select version,description,success from _sqlx_migrations order by version'
kubectl -n openshell scale "deploy/$DEP" --replicas=3
```

注意：

- 缩到 1 副本会让其余副本上的 supervisor 会话迁移/断开，客户端会重连；在维护窗口做。
- sqlx 迁移**只有 up、没有 down**；回滚二进制不保证能配新 schema。回滚前先在预发验证。
- 升级前先备份（§10），并确认备份可恢复。
- 多个独立 release 共库时「先升一台再升另一台」的顺序，在生产架构里不该出现（生产只有一个 release）。

---

## 8. 安全

| 面 | 配置 |
|---|---|
| 客户端身份 | OIDC Bearer token；`allowUnauthenticatedUsers=false`；角色映射 `os-admin` / `os-user` |
| 边缘 TLS | cert-manager；TLS 1.2+；HSTS 可选 |
| 集群内 | gateway 明文只在 NetworkPolicy 隔离的 ns 内；`enableMtls=false` 时禁止把 8080 暴露到集群外 |
| 数据库 | TLS；私有网络；应用账号只拥有 `openshell` 库；定期轮换密码（只换 URI Secret + 滚动重启，不动 KEK） |
| Sandbox | `allowDriverConfig=false`（调用方不能自带 driver JSON）；`resourceAdmission.enabled=true`（外部资源挂载需审批标签） |
| 镜像 | 固定 digest；准入扫描；`runAsNonRoot`、drop ALL（chart 默认） |
| 审计 | OCSF 日志导出到你的 collector；`openshell_ocsf_log_dropped_total` 必须为 0 |
| RBAC | chart 默认创建 ClusterRole（node reader）；namespace-admin 安装时可用 `rbac.clusterScoped.create=false` 由集群管理员预建 |

---

## 9. 可观测性与告警

- 指标：Service `openshell:9090/metrics`（Prometheus Operator 用 `servicemonitor.yaml`）。
- 实抓到的关键指标（POC4，名字可直接用于告警，见 `prometheusrule.yaml`）：
  - `openshell_server_readiness_database_healthy` — PG 健康（0 = 不可用）
  - `openshell_server_mutation_lock_{timeouts_total,errors_total,wait_seconds}`
  - `openshell_server_relay_{pending,pending_capacity,rejected_total,expired_total}`
  - `openshell_server_supervisor_sessions`
  - `openshell_server_grpc_requests_total`
  - `openshell_ocsf_log_{dropped_total,writer_errors_total,queue_records,queue_bytes}`
- 日志：gateway INFO 起步；`reconciler lease` 行用于确认哪副本持有租约（正常应只有一个）。
- 追踪：`server.otlp.endpoint` + `OTEL_EXPORTER_OTLP_ENDPOINT`。

---

## 10. 备份、恢复与灾难演练

| 对象 | 方式 | 频率 |
|---|---|---|
| PostgreSQL | 托管自动备份/PITR 或 CNPG `ScheduledBackup` + WAL | 每日全量 + 持续 WAL |
| KEK Secret | Vault/KMS 托管 + 离线托管（双人） | 变更即备份（基本不变） |
| gateway values/清单 | Git（不含 Secret） | 每次变更 |
| Sandbox 数据 | Sandbox 工作区 PVC 由业务自行备份；PG 备份**不包含** Sandbox | 按业务 |

恢复顺序：**PG 恢复 → 原 KEK Secret 就位 → gateway 启动 → OIDC 验证 → CLI 冒烟**。

> 演练必做：把备份恢复到新 PG，用**原来的 KEK** 起一个临时 gateway，
> `provider list` / `provider get` 能读出凭据元数据；否则你的备份只在纸面上有效。

---

## 11. 日常运维

- **扩容**：改 `replicaCount`（并确认 PG 连接数）→ `helm upgrade --reuse-values`。
  不要用 `kubectl scale` 长期漂移，HPA 之外请让 Helm 管副本数。
- **证书续期**：cert-manager 自动；监控 `certmanager_certificate_expiration_timestamp_seconds`。
- **DB 密码轮换**：更新 Secret → `kubectl rollout restart deploy/openshell`（滚动，不断服务）。
- **KEK**：不轮换；泄露才重建。
- **故障排查入口**：`readiness_database_healthy` → PG/Secret；`mutation_lock_errors` → 连接池；
  `relay_rejected` → TokenReview / NetworkPolicy；Pod 重启 → 看 `--previous` 日志里的启动探测错误。

---

## 12. 本方案中**未在 POC 集群验证**的部分（上线前必须在预发逐项过）

1. 托管 PostgreSQL（RDS/Cloud SQL）与 TLS（含 `sslrootcert` 是否被 sqlx 采纳）。
2. CloudNativePG 3 实例、Pooler session 模式、S3 备份与恢复。
3. cert-manager + Gateway API（Envoy Gateway）边缘 TLS 终止；`disableTls=true` 下
   sandbox supervisor 回连是否与 POC4 的 mTLS 路径一致。
4. External Secrets Operator 同步 DB URI / KEK。
5. NetworkPolicy：POC 集群没有验证 CNI 是否强制执行，也没有验证 kubelet 探针、
   apiserver、peer relay 的实际流量路径；必须在生产 CNI 上按实际流量收敛。
6. 共享 supervisor 池（`supervisor_topology=gateway` + `supervisor.replicas>=2`）的故障转移。
7. HPA 及连接数在压力下的表现。
8. 并发副本启动时的 sqlx 迁移竞争（POC4 只观测到「已存在则跳过」，未压测）。
9. PDB 在真实节点维护/驱逐下的效果。
10. 大规模（>3 副本、>100 workspace）下的租约与写锁行为。

---

## 13. 上线验收清单

- [ ] `helm template` 渲染中 **没有** `--db-url`，`OPENSHELL_DB_URL` 来自 `openshell-db`
- [ ] 3 副本在不同节点 Ready；杀 1 个 Pod 后 CLI 连续调用不失败（POC4 已证 2 副本形态）
- [ ] PG 里 `_sqlx_migrations` 7 条、`success=t`
- [ ] 在副本 A 建 provider，杀掉 A 后从 B 能 `provider get`（证明不是本地状态）
- [ ] KEK Secret 与 PG 备份分开托管，恢复演练通过
- [ ] `allowUnauthenticatedUsers=false`；无 token 调用被拒
- [ ] 边缘证书由 cert-manager 签发且自动续期
- [ ] 告警规则在预发演练中能触发（人为断 PG、造 relay 拒绝）
- [ ] 升级演练：按 §7 缩 1 → 升 → 验 migration → 扩 3
- [ ] 备份恢复演练：新 PG + 原 KEK + 临时 gateway 能读出凭据
