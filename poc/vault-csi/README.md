# Vault → CSI → OpenShell sandbox（0.1.7 实测）

> 环境：`k8s-221`（192.168.5.221/222，K8s v1.37.2，Antrea，2 节点）。OpenShell helm-chart **0.1.7**
> （image `0.1.7-api-prefix`，单 gateway `openshell`，`workspace_mode=operator`），本地 CLI **0.1.9**，
> 源码 `~/workspace/go/src/github.com/laik/OpenShell`（tag `v0.1.10-pre.3`）。
> 新装：secrets-store-csi-driver **1.6.2**、vault-csi-provider **1.7.4**、Gatekeeper **3.23.1**；
> Vault 1.20.1（dev，ns `vault-demo`）。全部结论来自 **2026-11-23** 实跑，原始输出见
> `evidence-20261123T140115Z.md`。

## 0. 一句话结论

**支持，但不是"把 csi 卷写进 OpenShell"。** OpenShell 的 kubernetes driver 卷闭集只有
`persistent_volume_claim`（`csi` 是未知字段，CR 里出现 csi 卷会被 resource admission 直接拒绝）。
所以 Vault 走 CSI 有两条可行路，两条都不需要在沙箱里放任何 Vault 凭据：

- **路 A（纯 OpenShell 原生）**：secrets-store + vault-csi-provider 包在「静态 CSI PV + 静态绑定的 PVC」里，
  PVC 打批准标签，用 `--driver-config-json` 挂进沙箱。要两个前置：管理员开 `allow_driver_config`，
  以及 CSIDriver 声明 `Persistent` 生命周期模式（chart 默认只声明 `Ephemeral`，kubelet 会拒）。
- **路 B（集群侧注入）**：mutating webhook（本次 Gatekeeper Assign）在 **Pod 准入**时补 inline `csi` 卷。
  gateway 只清点自己生成的 Sandbox CR，不清点 live Pod 的 control-plane 变更，所以不会被拒。

两条都能**不重启沙箱**看到轮转后的新值（实测两条都是 ~25 s 传播，见 C4/C8）。
挂载内容仍然受 sandbox policy 的路径闸门管：挂到 `/etc/...`（在基线里）直接可读；
挂到基线外的路径必须在 **create 时** `--policy` 放行，或对 live 沙箱 `policy set` 之后再
`sandbox stop` + `start` —— 文件策略不会对运行中的沙箱热生效（普通目录也一样，见 C9/C10）。

## 1. 判定矩阵

| # | 命题 | 结果 | 证据 |
| --- | --- | --- | --- |
| C0 | 普通 Pod + inline `csi` 卷 + vault provider 取 Vault KV | ✅ 文件渲染正确 | `20-positive-control.yaml` |
| C0b | 普通 Pod + PVC（静态 CSI PV） | ✅ 前提是 CSIDriver 含 `Persistent` | `30-vault-pvc.yaml` |
| C1 | 沙箱经 `--driver-config-json` 挂该 PVC，进程读到 Vault 密钥 | ✅ `vcsi-a` Ready，`cat /etc/vault-secrets/database-url` 出值 | evidence |
| C2 | driver-config 里写 `csi` 卷 | ❌ `unknown field csi, expected name or persistent_volume_claim` | evidence |
| C3 | webhook 在 live Pod 补 inline `csi` 卷，gateway 不拦、沙箱读到 | ✅ `vcsi-b`，`cat /etc/vault-inline/database-url` 出值 | `40-gk-inline-csi.yaml` |
| C4 | 轮转传播（改 Vault KV，不重启沙箱） | ✅ ~25 s 后读到新值（`--enable-secret-rotation=true --rotation-poll-interval=30s`） | evidence |
| C5 | CSI 挂载是否绕过 sandbox policy 路径闸门 | ❌ 不绕过：`/vault/secrets` 无放行 → `Permission denied` | `vcsi-d` |
| C8 | 路 B（inline csi）也能不重启轮转 | ✅ 改 KV 后 ~25 s，`vcsi-b` 读到新值 | evidence 续测 |
| C9 | 放行路径要在 create 时给 | ✅ `--policy 60-policy-vault-path.yaml` → `vcsi-e` 读到 `/vault/secrets`；同一 policy 热更新到 live 沙箱则无效 | `60-policy-vault-path.yaml` |
| C10 | `policy set` + `sandbox stop/start` | ✅ 重启后策略生效，CSI PVC 自动重新挂上 | evidence 续测 |
| C6 | csi 卷出现在 **Sandbox CR**（CR 级 Assign） | ❌ `workload contains an unsupported external resource attachment`，沙箱没建出来 | `50-gk-cr-csi.yaml` |
| C7 | 沙箱内有没有 Vault token / SA token | ✅ `env | grep -ic vault` = 0；workload Pod 无投影 SA token（同 poc/vault E14） | evidence |

源码依据（本地 `v0.1.10-pre.3`，与 0.1.7 行为一致）：
`crates/openshell-driver-kubernetes/src/driver.rs` 的 `KubernetesDriverVolumeConfig` 只有
`name` + `persistent_volume_claim`（`deny_unknown_fields`）；
`crates/openshell-driver-kubernetes/src/resource_admission.rs` 的 `inventory()` 只放行
`emptyDir` / `downwardAPI` / `persistentVolumeClaim` / gateway 私有 Secret，其它 `deny()`，
并且注释明确 "Kubernetes control-plane mutations of the eventual live Pod are … not inventoried here"。

## 2. 结构

```text
Vault KV (vault-demo, dev)                ← provider 在节点上（hostNetwork），沙箱 NetPol 不参与取密钥
   ▲  vault-csi-provider DS（socket 必须是 <provider>.sock；身份用 provider 自己的，不用 Pod SA）
   │
secrets-store.csi.k8s.io（DS，每节点）
   ├── 路 B：inline csi 卷 ← Gatekeeper Assign 打在 live Pod（Ephemeral 模式即可）
   └── 路 A：静态 PV(csi) ←→ 静态绑定 PVC（带 openshell.ai/sandbox-attachable* 标签）
                 │  OpenShell driver-config（allow_driver_config=true）
                 ▼
            sandbox agent 容器  /etc/vault-secrets（路径要在 policy 基线内）
```

## 3. 文件地图

| 文件 | 用途 |
| --- | --- |
| `00-login.sh` | 非交互刷新 gateway OIDC token（realm TTL 30 min，跑一半会过期） |
| `10-provider.yaml` | vault-csi-provider DaemonSet + HMAC RBAC（不是 sidecar，靠共享 socket 目录） |
| `20-positive-control.yaml` | C0 正向对照（普通 Pod + inline csi 卷） |
| `30-vault-pvc.yaml` | C0b 对照 + 路 A 的 SPC / 静态 CSI PV / 带标签 PVC |
| `40-gk-inline-csi.yaml` | 路 B：给 workload Pod 补 inline csi 卷 + 挂载 |
| `50-gk-cr-csi.yaml` | C6 反向对照：CR 级注入（跑完就删，留着会挡住所有建沙箱） |
| `60-policy-vault-path.yaml` | 基线 + `/vault/secrets` 只读（C9/C10 用） |
| `evidence-20261123T140115Z.md` | 实跑原始输出 |

## 4. 复现

```bash
# 0) 装 driver + provider（镜像从节点拉 docker.io/registry.k8s.io 不稳定，先 crane pull + ctr import，见 §6.5）
helm install secrets-store csi-secrets-store/secrets-store-csi-driver --version 1.6.2 -n secrets-store \
  --create-namespace --set enableSecretRotation=true --set rotationPollInterval=30s
kubectl apply -f 10-provider.yaml
# 关键：CSIDriver 的 volumeLifecycleModes 不可改（immutable），只声明 Ephemeral 时路 A 挂不上
kubectl delete csidriver secrets-store.csi.k8s.io && kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata: {name: secrets-store.csi.k8s.io}
spec:
  attachRequired: false
  podInfoOnMount: true
  requiresRepublish: true
  volumeLifecycleModes: [Ephemeral, Persistent]
EOF

# 1) 对照 + 路 A 的资源（SPC / 静态 PV / 带批准标签的 PVC）
kubectl apply -f 20-positive-control.yaml -f 30-vault-pvc.yaml

# 2) gateway 管理员开关：driver-config 默认关闭
helm get values openshell -n openshell -o yaml > /tmp/cur.yaml
printf 'server:\n  drivers:\n    kubernetes:\n      allowDriverConfig: true\n' > /tmp/dc.yaml
helm upgrade openshell oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.7 -n openshell -f /tmp/cur.yaml -f /tmp/dc.yaml

# 3) 沙箱挂 Vault（路 A）
bash 00-login.sh
WS=tenant-a-runtime
DC='{"kubernetes":{"volumes":[{"name":"vault","persistent_volume_claim":{"claim_name":"vault-csi-pvc","read_only":true}}],"containers":{"agent":{"volume_mounts":[{"name":"vault","mount_path":"/etc/vault-secrets","read_only":true}]}}}}'
openshell -g os-tadmin --workspace $WS sandbox create --name vcsi-a --from nvcr.io/nvidia/base/ubuntu:24.04 \
  --cpu 50m --memory 64Mi --detach --restart-policy never --driver-config-json "$DC"
openshell -g os-tadmin --workspace $WS sandbox exec vcsi-a -- cat /etc/vault-secrets/database-url   # ✅

# 4) 路 B：Pod 级 inline csi 卷
kubectl apply -f 40-gk-inline-csi.yaml
openshell -g os-tadmin --workspace $WS sandbox create --name vcsi-b --from nvcr.io/nvidia/base/ubuntu:24.04 \
  --cpu 50m --memory 64Mi --detach --restart-policy never
openshell -g os-tadmin --workspace $WS sandbox exec vcsi-b -- cat /etc/vault-inline/database-url      # ✅

# 5) 轮转：改值后不重启沙箱，~30s 内读到新值
kubectl -n vault-demo exec deploy/vault -- sh -c 'export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root; \
  vault kv put secret/csi/db url="postgres://demo-app:CSI-v3-DEMO@db.tenant-a.svc:5432/app"'
openshell -g os-tadmin --workspace $WS sandbox exec vcsi-a -- cat /etc/vault-secrets/database-url     # 新值
```

清场：`sandbox delete vcsi-a vcsi-b vcsi-d` → `kubectl delete -f 40-gk-inline-csi.yaml -f 30-vault-pvc.yaml`
（PV 是 Retain，要单独 `kubectl delete pv vault-csi-pv-poc`）→ 需要关回开关就
`helm upgrade` 去掉 `allowDriverConfig`。`vcsi-a`/`vcsi-b` 本次**留着**，可以直接 `sandbox exec` 复看。

## 5. 轮转怎么配（不是 Vault 侧的事，是 driver 的 rotation loop）

```yaml
# helm values（secrets-store-csi-driver 1.6.2）
enableSecretRotation: true        # → --enable-secret-rotation=true（默认 false）
rotationPollInterval: 30s         # 默认 120s；本次 30s，实测改值后 20–25s 沙箱内就是新值
```
```yaml
# CSIDriver 必须同时带（chart 会随 enableSecretRotation 生成；
# 但我们是手工 delete+recreate 的 CSIDriver，这一行必须自己写，否则不会重挂）
spec:
  requiresRepublish: true
  volumeLifecycleModes: [Ephemeral, Persistent]
```
- provider 需要能在**它自己的 ns** get/create/update secret `vault-csi-provider-hmac-key`
  （`10-provider.yaml` 里的 Role 就是干这个）；缺了会 `[WARN] Error generating HMAC key …
  Mounted secrets will not be assigned a version`，版本 hash 就没了（缺 hash 时轮转是否仍生效未测）。
- 可观察量：`kubectl get secretproviderclasspodstatus <pod>-<ns>-<spc> -o jsonpath='{.status.objects[0].version}'`
  会跟着变（实测 `m1yBPu…` → `N8Ap9k…`，同时 `sandbox exec cat` 就是新值）。
- **挂载必须是目录，不要 subPath**：轮转是 `..data` 原子换符号链接，subPath 钉的是旧 inode。
  （OpenShell 的 `volume_mounts[].sub_path` 支持但不建议用，没实测。）
- Vault 侧要做的只是改值（`vault kv put`）。若用动态密钥（database engine 等），每轮会重新取一遍；
  lease/TTL 由 Vault 自己管，CSI 不做 lease renew（本 POC 未验证动态密钥场景）。
- 轮转完全发生在节点/kubelet 层：OpenShell 不参与，不需要重启沙箱、不需要改 policy。

## 6. 硬约束与环境坑

1. **`csi` 不是一种 OpenShell 卷类型。** 想在 API 里表达，只能 PVC；CR 里出现 csi 卷 = 建沙箱失败（C6）。
   路 A 因此是"CSI 藏在 PVC 后面"，路 B 是"CSI 绕开 OpenShell 的清点"。
2. **`allow_driver_config` 默认 false**（`openshell-config` 里 `allow_driver_config = false`）。
   路 A 必须有 gateway 管理员开它；开与不开都是平台侧决定，不是租户能改的。
3. **CSIDriver `volumeLifecycleModes` 是 immutable，且 secrets-store chart 只写 `Ephemeral`。**
   不声明 `Persistent` 时 kubelet 报 `volume mode "Persistent" not supported by driver`，路 A 直接不可用。
   修法是 `kubectl delete csidriver … && kubectl apply`（patch 会被拒绝：field is immutable）。
   实测同一 chart 的 `helm upgrade --reuse-values` **不会**把它改回去；要固化还是应该改 chart values，
   或把这条 CSIDriver 从 release 里拆出来由平台自己管。
4. **provider 的身份**：vault-csi-provider 默认用挂载 Pod 的投影 SA 走 Kubernetes auth，而 OpenShell
   workload Pod 恒无 SA token（capability-free isolation）。本次把凭据放在 provider 自己
   （DaemonSet 的 `VAULT_TOKEN`，POC 用 root）。生产换成 provider 侧的 AppRole/K8s auth +
   每租户 Vault role；好处是取密钥完全发生在沙箱边界外，沙箱的 egress 全拒不影响。
5. **镜像拉取**：这两个节点上 docker.io / registry.k8s.io 常被中间设备打断（`x509: certificate is
   valid for *.facebook.com`、`connection reset by peer`）。可用本地 `crane pull` + `scp -O` +
   `ctr -n k8s.io images import`（本次就是这么装的）。
6. **provider 发现**：driver 只认 `<provider>.sock`（`vault.sock`）。`provider-vault.sock` 会报
   `provider not found`（secrets-store v1.6.2 `provider_client.go`）。
7. **Vault 路径**：KV v2 在 provider 里要写 `secretPath: "secret/data/csi/db"`，写 `secret/csi/db` 是 404。
8. **策略热更新不会打开文件路径**：`policy set` 会回 `loaded`，但运行中的沙箱里新起的进程仍按旧策略；
   删除一个 `read_only` 路径会被网关直接拒绝（`read_only path '/var/log' cannot be removed on a live sandbox`）。
   要么建沙箱时给 policy，要么 `policy set` 后 `sandbox stop`/`start`。
9. **和 provider 凭据平面无关**：`openshell provider create` 那套 Gateway Vault Credential Driver
   （出站替换凭据）与这里的文件注入是两条独立平面，见 `../vault/README.md` 与主文档。
