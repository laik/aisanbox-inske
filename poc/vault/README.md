# Vault + ConfigMap → OpenShell Sandbox 文件注入（0.1.7 实测）

> 环境：`root@192.168.5.190`，kind `kind-agent-runtime-poc`，OpenShell chart/CLI **0.1.7**，
> gateway `os-a`（tenant-a-gateway，mTLS，workspace `poc-shared`，runtime ns `tenant-a-runtime`）。
> 本文所有结论均为 **2026-11-18** 实跑所得。 Vault **2.0.4** / vault-k8s **2.x**（dev 模式），
> Gatekeeper 3.23（mutation 已启用），Kyverno 1.20（装而未用，见 §4）。

## 0. 一句话结论

**Vault Agent Injector 进不了 OpenShell 0.1.7 的 workload Pod** —— 不是配置问题，是产品不变量：
gateway 显式拒绝 workload 持有任何投影 SA token（*capability-free isolation*），而 injector 的
kubernetes auth 必须用 Pod SA token。可行路径是**边界外渲染 + 带准入标签的 PVC 挂载**；
**ConfigMap 和 K8s Secret 都可以直接挂**（打准入标签 + Gatekeeper Assign 补卷，E10/E15）。
Vault 密钥走边界外渲染 + PVC。三条路都不需要在 sandbox 里放任何凭据。

## 1. 最终架构

```text
Vault KV (secret/data/tenant-a/*)
   │  ① 渲染器 Job（沙箱边界外，SA vault-renderer，kubernetes auth）
   ▼
PVC agent-secrets-pvc  ← 标签 openshell.ai/sandbox-attachable=true
   │                      example.com/workspace=poc-shared
   │  ② Gatekeeper Assign 给 workload Pod 补 PVC 卷 + /vault/secrets 挂载
   ▼
sandbox agent 容器  ← ③ sandbox policy 显式放行 /vault/secrets (RO)
                      （无 SA token、无 Vault token，只有文件）

ConfigMap agent-config（同款准入标签）
   │  Gatekeeper Assign 补 configMap 卷 + /etc/agent-config 挂载
   ▼
sandbox agent 容器（/etc 在策略基线里，无需改 policy）
```

对照：普通 Pod（非 OpenShell）上 Vault Agent Injector **完全可用**
（`20-positive-control-pod.yaml`，init-only 渲染、无 sidecar、app 容器无 Vault token）——
证明 Vault 侧健康，sandbox 侧的失败都归因于 OpenShell 边界。

## 2. 实测结论矩阵

| # | 命题 | 结果 | 证据 |
| --- | --- | --- | --- |
| E1 | driver-config 挂 configMap 卷 | ❌ `unknown field config_map, expected name or persistent_volume_claim` | `40-...sh` |
| E2 | driver-config 挂 secret 卷 | ❌ 同上（`secret` 也被拒） | 同上 |
| E3 | driver-config 写 pod annotations | ❌ pod 段只接受 `node_selector/runtime_class_name/tolerations/priority_class_name` | 同上 |
| E4 | injector 注入普通 Pod | ✅ 文件渲染正确，init-only，无 token 泄漏 | `20-...yaml` |
| E5 | injector 注入 workload Pod | ❌ `failed to find service account volume mount`（automount=false）；webhook `failurePolicy=Ignore` **不救显式 denied** | controller 日志 |
| E6 | automount 翻 true（Pod 级 webhook） | ❌ SA 插件跑在 webhook 之前，卷不会补 | 实测 |
| E7 | automount 翻 true（Sandbox CR 级） | ❌ 卷有了，gateway 拒：`unsupported external resource attachment` | `80-...yaml` |
| E8 | 纯 SA token 投影卷（无 configMap 引用） | ❌ gateway 拒：`workload Pod must not receive a projected ServiceAccount token` | `90-...yaml` |
| E9 | 额外 emptyDir 卷 | ✅ 放行（admission 管的是外部资源引用，不是卷数量） | v-ed |
| E10 | 带准入标签的 ConfigMap 卷（Assign 补） | ✅ v-cm Ready，`openshell exec` 读到内容 | `110` 同款 Assign |
| E11 | 带准入标签的 PVC 卷（Assign 补） | ✅ v-sec Ready，读到 Vault 渲染的密钥 | `100/110` |
| E12 | 策略基线不含 /vault/secrets | ✅ 负对照 v-nopol：`Permission denied`（与 Unix 权限无关） | policy get --base |
| E13 | 轮转传播（重跑 Job，不重启 sandbox） | ✅ 目录挂载（非 subPath）即时可见 | §5 |
| E14 | workload 内无 SA token | ✅ `ls .../serviceaccount/token` → No such file | v-sec |
| E15 | 带准入标签的 K8s Secret 卷（Assign 补） | ✅ v-ksec Ready，`openshell exec` 读到内容 | `130-gk-ksec-mount.yaml` |

## 3. 文件地图

| 文件 | 用途 | 状态 |
| --- | --- | --- |
| `demo.sh` | 七拍手工 demo / 无人值守回归（FAST=1），含 --cleanup | ✅ 7/7 |
| `values-vault-poc.yaml` | helm values（dev 模式 + injector） | ✅ 在用 |
| `10-vault-config.sh` | k8s auth / policy / role / 种子 KV（幂等） | ✅ 在用 |
| `15-vault-renderer-role.sh` | 渲染器专用 role（SA vault-renderer） | ✅ 在用 |
| `20-positive-control-pod.yaml` | 普通 Pod injector 正向对照 | ✅ 在用 |
| `30-configmap-secret.yaml` | ConfigMap + 静态 Secret（带准入标签） | ✅ CM 在用 |
| `policy-vault-secrets.yaml` | 基线 + /vault/secrets RO | ✅ 在用 |
| `100-renderer.yaml` | SA + PVC + 渲染 Job（边界外） | ✅ 在用 |
| `110-gk-pvc-mount.yaml` | Assign：PVC 卷 + /vault/secrets 挂载 | ✅ 在用 |
| `120-gk-cm-mount.yaml` | Assign：ConfigMap 卷 + /etc/agent-config 挂载 | ✅ 在用 |
| `130-gk-ksec-mount.yaml` | Assign：K8s Secret 卷 + /etc/agent-secrets 挂载 | ✅ 在用 |
| `40-driver-config-experiments.sh` + `dc-*.json` | E1–E3 能力边界探针 | 📁 存档 |
| `50-gatekeeper-mutation.yaml` | GK 注解 location 被拒记录 | 📁 负面存档 |
| `60-kyverno-policy.yaml` | Kyverno CEL API 两条死路记录 | 📁 负面存档 |
| `80-kyverno-sandbox-automount.yaml` / `90-gatekeeper-sa-token.yaml` | E7/E8 被拒记录 | 📁 负面存档 |

## 4. 工具链实测坑（装之前必读）

1. **vault chart 的 RBAC 缺口**：`vault-agent-injector` SA 只绑了 webhook 权限，
   `system:auth-delegator` 绑的是 server SA。用 injector SA token 做
   `token_reviewer_jwt` 会 403，审计日志只显示 `permission denied`，真正原因
   （`cannot create tokenreviews`）藏在 **debug 日志**里。`10-vault-config.sh`
   第 0 步补绑定。另：chart 的 StatefulSet 是 OnDelete 策略，`set env` 不会重启 Pod。
2. **vault-k8s 2.x 不自建投影 token**：直接用 Pod 标准路径 SA token，aud 是 API
   server 默认值 `https://kubernetes.default.svc.cluster.local`。role 的 audience
   必须钉这个值（写 `vault` 会 403 `invalid audience`）。
3. **Gatekeeper Assign**：location 解析器拒绝带点/斜杠的注解键
   （`metadata.annotations["vault.hashicorp.com/..."]` 全部校验失败）；
   数组 upsert（`spec.volumes[name:...]`）可用，value 任意 JSON。
4. **Kyverno 1.20**：legacy `kyverno.io/v1 ClusterPolicy` 禁止创建；新
   `policies.kyverno.io/v1 MutatingPolicy` 的 ApplyConfiguration 写不了 atomic list
   （`projected.sources`），JSONPatch 的 CEL value 类型钉死 string。注解注入可行，
   卷注入两条路都断。最终未采用（集群里留着无策略）。
5. **webhook 顺序**：mutating 按配置名字典序调用（gatekeeper < kyverno <
   vault-agent-injector-cfg）；`failurePolicy=Ignore` 只忽略调用失败，**不忽略显式
   denied**。
6. **workload NetPol 全拒 egress**（含 DNS）：`openshell-sandbox-workloads` 声明
   Egress 无规则。边界外渲染方案里渲染器是普通 Pod 不受影响；若将来要在 workload
   里跑任何需要网络的 init，先补 `70-netpol-vault.yaml` 式受控出口。
7. **渲染器重跑**：上一轮 `chmod 0444` 的文件不可覆盖，先 `rm -f` 再写（已修）。

## 5. 复现

**一键逐拍 demo（推荐）**：`bash /root/poc2/vault/demo.sh`（交互，每拍回车继续，适合录屏）
或 `FAST=1 bash /root/poc2/vault/demo.sh`（连跑回归）。七拍：injector 正向对照 →
Vault 密钥进 sandbox → 策略负对照 → ConfigMap → K8s Secret → 无 SA token → 不重启轮转。
2026-11-18 实跑 **7/7 通过**。清场：`demo.sh --cleanup`。前置只需下面步骤 0 装好一次。

**手工逐步**（190 上）：

```bash
ssh root@192.168.5.190
K="kubectl --context kind-agent-runtime-poc"
C=/root/poc2/vendor/openshell-cli-0.1.7/openshell

# 0) Vault（已装则跳过；dev 模式 Pod 重建后数据全丢，需重跑 10/15/100）
helm repo add hashicorp https://helm.releases.hashicorp.com
helm --kube-context kind-agent-runtime-poc install vault hashicorp/vault \
  -n vault --create-namespace -f /root/poc2/vault/values-vault-poc.yaml
$K -n vault wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=240s
bash /root/poc2/vault/10-vault-config.sh
bash /root/poc2/vault/15-vault-renderer-role.sh

# 1) gateway 通道（mTLS profile poc2-a）
ss -ltn | grep -q ":18441 " || setsid nohup $K -n tenant-a-gateway \
  port-forward svc/os-a-openshell 18441:8080 --address 127.0.0.1 >/tmp/pf-os-a.log 2>&1 &
$C -g poc2-a whoami

# 2) 正向对照（Vault+injector 本身）
$K apply -f /root/poc2/vault/20-positive-control-pod.yaml
$K -n tenant-a-runtime wait --for=condition=Ready pod/vault-inject-control --timeout=150s
$K -n tenant-a-runtime exec vault-inject-control -c agent -- cat /vault/secrets/database-url

# 3) 渲染器 + PVC + 挂载
$K apply -f /root/poc2/vault/100-renderer.yaml
$K -n tenant-a-runtime wait --for=condition=complete job/vault-render --timeout=180s
$K apply -f /root/poc2/vault/110-gk-pvc-mount.yaml

# 4) ConfigMap 挂载
$K apply -f /root/poc2/vault/30-configmap-secret.yaml
$K apply -f /root/poc2/vault/120-gk-cm-mount.yaml

# 5) sandbox（正/负对照）
$C -g poc2-a --workspace poc-shared sandbox create --name v-sec \
  --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
  --policy /root/poc2/vault/policy-vault-secrets.yaml
$C -g poc2-a --workspace poc-shared sandbox create --name v-nopol \
  --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never
$C -g poc2-a --workspace poc-shared sandbox exec v-sec   -- cat /vault/secrets/database-url  # ✅
$C -g poc2-a --workspace poc-shared sandbox exec v-nopol -- cat /vault/secrets/database-url  # ❌ Permission denied
$C -g poc2-a --workspace poc-shared sandbox exec v-sec   -- cat /etc/agent-config/app.yaml   # ✅

# 6) 轮转（不重启 sandbox）
$K -n vault exec vault-0 -- env VAULT_TOKEN=poc-root-token \
  vault kv put secret/tenant-a/database url="postgres://demo-app:ROTATED-v2-DEMO@db.tenant-a.svc:5432/app"
$K -n tenant-a-runtime delete job vault-render
$K apply -f /root/poc2/vault/100-renderer.yaml
$K -n tenant-a-runtime wait --for=condition=complete job/vault-render --timeout=120s
$C -g poc2-a --workspace poc-shared sandbox exec v-sec -- cat /vault/secrets/database-url  # 新值
```

清场：`sandbox delete v-sec v-nopol v-cm` → 删 Assign（cm/pvc 四条）→ 按需保留 Vault。

## 6. 生产化备注

- **每租户一套**：Vault role/policy（`secret/data/tenant-x/*`）+ 渲染器 SA + PVC +
  Assign 策略，由平台开通流程生成；namespace/label 选择器按租户替换。
- **渲染器形态**：POC 用 Job 手动重跑；生产换成控制器（定时 / watch Vault 租约），
  或评估 **secrets-store-csi-driver + vault provider**（CSI 节点驱动代取 token，
  Pod 内不落 token —— 但 CSI 卷能否过 0.1.7 admission **未验证**）。
- **隔离粒度**：os-a 的所有 sandbox 共用 SA `os-a-openshell-sandbox`（gateway 级），
  所以 Vault role 的绑定粒度是"每租户 gateway"，不是"每 sandbox"。
- **Vault 形态**：dev 模式仅 POC（内存存储、固定 root token、无 TLS）；生产按
  `openshell4/production/` 约定（TLS + 持久存储 + auto-unseal）。
- **Provider 凭据另一条平面**：Gateway Vault Credential Driver（`provider create`
  的凭据进 Vault）与本文的文件注入互不相干，见 README 主文档与贴文第一~四节。