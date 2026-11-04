# 手工 Demo：从零搭一套多租户 AI Sandbox

> 这份文档是**手把手版**：一条命令一步，按顺序敲，随时可以停下来看结果、讲一遍。
> 它和一键脚本 `poc/scripts/bootstrap.sh` 等价，只是拆成了 17 步——版本号、命名空间、组件顺序完全一致。
>
> 适合：给同事演示、排查某一层、或者想看清每个组件到底装了什么。
> 不适合：CI 里重建环境（用 `bootstrap.sh`）。

实测环境：macOS · Docker Desktop 29.2.1 / 内核 6.12.72 · 8C / 8G · kind v0.33.0 · K8s v1.37.0
全程约 **45–70 分钟**，大头是拉镜像（OpenShell / Tetragon / Prometheus）。

---

## 0. 先对一下条件

| 需要 | 版本 / 要求 | 自查命令 |
|---|---|---|
| Docker | 至少 **8 GiB** 内存（两个 kind 集群常驻约 2.5–3 GiB） | `docker info -f '{{.MemTotal}}'` |
| kind | v0.33 左右 | `kind version` |
| kubectl | ≥ 1.30 | `kubectl version --client` |
| helm | ≥ 3.14 | `helm version --short` |
| 内核 BTF | Tetragon 依赖 `/sys/kernel/btf/vmlinux` | 进入 Docker VM 或直接看第 6 步是否起得来 |
| `openshell` CLI | 0.1.4，与 gateway 同版本 | `openshell version` |

> `openshell` CLI 不在本仓库内（POC 用的是与 gateway 同版本的 0.1.4）。没有它，**第 1–10 步照做**（集群、租户、策略、观测都能验证），第 11 步起无法执行。
> CLI 需要指向刚部署的 gateway；连接方式以 `openshell --help` 为准，常见做法是 `kubectl port-forward`。

本文所有命令都在 **`poc/` 目录**下执行：

```bash
cd poc
export A=kind-inske-plane-a   # 租户数据面
export B=kind-inske-plane-b   # 平台观测面
```

> 每开一个新终端，都要重新 `export A=... B=...`（或者把 `--context $A` 换成完整名字）。
> 组件安装都用 `helm upgrade --install`（cert-manager 用官方 YAML），中途失败可以直接重跑同一条命令。

### 总览

| 步骤 | 做什么 | 大约耗时 | 需要 CLI |
|---|---|---|---|
| 1 | 起两个 kind 集群 | 2 min | |
| 2 | 装 agent-sandbox | 2 min | |
| 3 | 装 cert-manager + Capsule | 3 min | |
| 4 | 声明租户 acme / globex | 1 min | |
| 5 | 租户自己建命名空间，验证注入 | 1 min | |
| 6 | 装 Tetragon | 3 min | |
| 7 | 装 OpenShell gateway（operator 模式） | 3 min | |
| 8 | 每个租户 ns 装 workspace 前置 | 2 min | |
| 9 | 下发策略 + 预热池 | 2 min | |
| 10 | plane-b 装 Prometheus，跨集群抓取 | 5 min | |
| 11 | 创建第一个沙箱 | 1 min | ✅ |
| 12 | 看 agent 到底做了什么 | 5 min | ✅ |
| 13 | 演示拦截：网络 / 执行 | 5 min | ✅ |
| 14 | 演示热更新：改策略不重启 | 3 min | ✅ |
| 15 | 演示预热池：0.25s vs 16s | 5 min | |
| 16 | 演示配额：噪声邻居被挡住 | 3 min | |
| 17 | 收尾清理 | 1 min | |

---

## 1. 起两个集群

**为什么两个**：plane-a 放租户数据面（Capsule + agent-sandbox + OpenShell + Tetragon），plane-b 放观测栈。这样能顺带验证"平台集群观测租户集群"的拓扑。

```bash
kind create cluster --config kind/cluster-a.yaml --wait 120s
kind create cluster --config kind/cluster-b.yaml --wait 120s
```

**应该看到**（第二个集群类似）：

```
Creating cluster "inske-plane-a" ...
 ✓ Ensuring node image (kindest/node:v1.37.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
Set kubectl context to "kind-inske-plane-a"
```

检查：

```bash
kind get clusters
kubectl --context $A get nodes -o wide
```

```
inske-plane-a
inske-plane-b

NAME                         STATUS   ROLES           AGE   VERSION
inske-plane-a-control-plane  Ready    control-plane   1m    v1.37.0
```

> 讲这里：两个集群共享 kind 的 Docker 网络，所以后面 plane-b 能直接抓 plane-a 的 `节点IP:NodePort`，不用做任何隧道。

---

## 2. 装 agent-sandbox（plane-a）

**为什么先装它**：OpenShell 的 Kubernetes driver 是**构建在 agent-sandbox 之上**的（官方要求先有 `Sandbox` CRD），所以这是官方路径，不是拼装。

```bash
kubectl --context $A apply -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.9/sandbox-with-extensions.yaml"

kubectl --context $A -n agent-sandbox-system wait \
  --for=condition=available deploy/agent-sandbox-controller --timeout=180s
```

检查：

```bash
kubectl --context $A get crd | grep -E "agents.x-k8s.io|extensions.agents"
kubectl --context $A -n agent-sandbox-system get pods
```

**应该看到**：`sandboxes.agents.x-k8s.io`、`sandboxclaims.extensions.agents.x-k8s.io`、`sandboxwarmpools.extensions.agents.x-k8s.io` 等 CRD，以及 1 个 `agent-sandbox-controller` Pod 为 `Running`。

---

## 3. 装 cert-manager 与 Capsule（plane-a）

**为什么**：Capsule 的 webhook 证书由 cert-manager 签发；Capsule 提供"租户合同"——命名空间归属、配额、标签注入、策略下发。

```bash
kubectl --context $A apply -f \
  https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml

kubectl --context $A -n cert-manager wait \
  --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager --all --timeout=180s
```

```bash
helm repo add projectcapsule https://projectcapsule.github.io/charts --force-update
helm repo update

helm --context $A upgrade --install capsule projectcapsule/capsule \
  --version 0.15.2 -n capsule-system --create-namespace --wait --timeout 5m
```

检查：

```bash
kubectl --context $A -n capsule-system get pods
kubectl --context $A get crd | grep capsule.clastix.io
```

**应该看到**：`capsule-controller-manager` 为 `Running`；`tenants.capsule.clastix.io`、`tenantowners.capsule.clastix.io`、`globaltenantresources.capsule.clastix.io` 三个 CRD。

> 注意：Capsule v0.15 的 `resourceQuotas` / `limitRanges` / `networkPolicies` 字段已标 deprecated，POC 仍用它们（当前可用），迁移方向见 [SUMMARY.md](SUMMARY.md) §6 与 [FINDINGS.md](FINDINGS.md) §3。

---

## 4. 声明两个租户

租户定义在 `capsule/tenants.yaml`。**最关键的一行**是 `namespaceOptions.additionalMetadata.labels` 里的 `openshell.ai/workspace: "true"`——这是把 Capsule 租户接到 OpenShell 的那根线。

```bash
kubectl --context $A apply -f capsule/tenants.yaml
kubectl --context $A apply -f capsule/tenant-owners.yaml
```

检查：

```bash
kubectl --context $A get tenant
kubectl --context $A get tenantowner
```

```
NAME     STATE    AGE
acme     Active   5s
globex   Active   5s

NAME           AGE
acme-owner     5s
globex-owner   5s
```

> 讲这里：两个租户的配额是**故意不对称**的（acme 2C/2Gi/pods 20，globex 0.5C/512Mi/pods 5），第 16 步用 globex 演示"噪声邻居被配额挡住"。

### 可选：验证"没注册 owner 会怎样"

用一个不属于任何租户的身份建命名空间：

```bash
kubectl --context $A create ns test-nope --as=nobody --as-group=tenant-nobody
```

**应该看到** `Error from server (Forbidden)`——没有 `TenantOwner` 绑定时，用户连 `create ns` 的权限都没有（默认 owner 只有 `admin`，不含 `capsule-namespace-provisioner`）。

---

## 5. 让租户自己建命名空间（验证 Capsule 注入）

```bash
kubectl --context $A create ns acme   --as=alice --as-group=tenant-acme
kubectl --context $A create ns globex --as=bob   --as-group=tenant-globex
```

> 已存在会报 `AlreadyExists`，忽略即可。

检查注入结果：

```bash
kubectl --context $A get ns acme --show-labels
kubectl --context $A -n acme get resourcequota,limitrange,networkpolicy
```

**应该看到**：

- 标签里有 `capsule.clastix.io/tenant=acme`、`openshell.ai/workspace=true`（Pod 上则是 `projectcapsule.dev/tenant=acme`）
- `resourcequota/capsule-acme-0`、`limitrange/capsule-acme-0`、默认 egress `networkpolicy`

> 讲这里：租户只做"建 ns"这一个动作，配额/标签/默认网络策略都是 webhook 注入的——这就是"租户契约即代码"。第 7 步 OpenShell 就是靠 `openshell.ai/workspace=true` 发现这个 ns 的。

---

## 6. 装 Tetragon（plane-a）

```bash
helm repo add cilium https://helm.cilium.io --force-update
helm repo update

helm --context $A upgrade --install tetragon cilium/tetragon \
  --version 1.8.0 -n kube-system --wait --timeout 6m
```

检查：

```bash
kubectl --context $A -n kube-system get ds tetragon
kubectl --context $A -n kube-system exec ds/tetragon -c tetragon -- tetra version
```

**应该看到**：DaemonSet `1/1`；`tetra version` 输出 `1.8.0`。

> 如果 Pod 报 BTF 相关错误：宿主机内核没有 `/sys/kernel/btf/vmlinux`。Docker Desktop 6.12 自带，其它环境要先确认。

---

## 7. 装 OpenShell gateway（operator 模式）

### 7.1 拉 gateway chart

```bash
mkdir -p vendor
helm pull oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.4 --untar --untardir vendor
ls vendor/helm-chart
```

> GHCR 的 tag 列表分页会骗人（首页最高只显示 `0.0.42`），真实最新稳定是 `0.1.4`。**取 tag 必须分页拉全再排序。**

### 7.2 安装

`openshell/values-plane-a.yaml` 里已经写好关键接线：`workspaceMode: operator` + `operatorNamespaceLabel: openshell.ai/workspace=true`。

```bash
helm --context $A upgrade --install openshell ./vendor/helm-chart \
  -n openshell --create-namespace \
  -f openshell/values-plane-a.yaml --timeout 6m
```

检查：

```bash
kubectl --context $A -n openshell get pods,svc
kubectl --context $A -n openshell logs deploy/openshell --tail=100 | grep -i "operator namespace"
```

**应该看到**这一行（`total=2` 就是 acme + globex 两个命名空间被接管）：

```
operator namespace allowlist replaced from full relist total=2
```

> 如果 `deploy/openshell` 不存在，先 `kubectl -n openshell get deploy` 看实际名字。
> 讲这里：OpenShell 没有自己建 ns，而是"发现"了 Capsule 已经建好并打好标签的 ns——这就是唯一需要接线的地方。

---

## 8. 给每个租户命名空间装 workspace 前置

operator 模式下，gateway 在租户 ns 内的 Secret 权限来自这个 chart（SA / Role / RoleBinding / NetworkPolicy），每个租户 ns 各装一份。POC 里直接从仓库源码拉一份：

```bash
mkdir -p vendor/openshell-workspace/templates
BASE=https://raw.githubusercontent.com/NVIDIA/OpenShell/main/deploy/helm/openshell-workspace

for f in Chart.yaml values.yaml; do
  curl -fsSL -o "vendor/openshell-workspace/$f" "$BASE/$f"
done
for f in _helpers.tpl networkpolicy.yaml role.yaml rolebinding.yaml serviceaccount.yaml; do
  curl -fsSL -o "vendor/openshell-workspace/templates/$f" "$BASE/templates/$f"
done
```

安装到两个租户 ns：

```bash
for t in acme globex; do
  helm --context $A upgrade --install "os-workspace-$t" ./vendor/openshell-workspace -n "$t" \
    --set gateway.serviceAccount.name=openshell \
    --set gateway.serviceAccount.namespace=openshell
done
```

检查：

```bash
kubectl --context $A -n acme get sa,role,rolebinding,networkpolicy
```

**应该看到**：一份 `os-workspace-acme` 的 release 资源（SA / Role / RoleBinding / NetworkPolicy），名字带 release 前缀。

> 坑：gateway 的 `sandboxNamespace` 必须留空（= release 所在的 `openshell` ns）。它同时是 `openshell-client-tls` 这类 Secret 的复制源；指到租户 ns 会报 `Secret ... does not exist in source namespace`。

---

## 9. 下发策略与预热池

三件事：让 Capsule 自动下发租户策略（GTR）、装集群级策略基线、建 acme 的预热池。

```bash
kubectl --context $A apply -f capsule/global-tenant-resource.yaml
kubectl --context $A apply -f tetragon/policies/
kubectl --context $A apply -f agent-sandbox/warmpool-acme.yaml
```

检查：

```bash
kubectl --context $A get globaltenantresource
kubectl --context $A get tracingpolicy
kubectl --context $A -n acme get sandboxwarmpool
kubectl --context $A -n acme get pods
```

**应该看到**：

- `aisanbox-agent-audit` 的 `READY` 为 `True`
- 8 个 `TracingPolicy`（来自 6 个文件）
- `agent-pool` 预热池，acme 里多出 2 个 `agent-pool-*` Pod（`Running`）
- acme 的 `capsule-acme-0` 配额被这 2 个 Pod 占用一部分（池吃租户配额，属正常）

> 讲这里：预热池是"租户的"，不是"集群的"——池子大就要在租户容量规划里算进去。模板里必须显式写 `resources`，否则 Capsule 的 LimitRange 默认值会补上，实际占用变成 `replicas × default`。

---

## 10. plane-b：装 Prometheus，跨集群抓平面 a 的指标

### 10.1 把 plane-a 的三个指标端点暴露成 NodePort

```bash
# Capsule 指标
kubectl --context $A -n capsule-system patch svc capsule-controller-manager-metrics-service \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"metrics","port":8080,"protocol":"TCP","targetPort":8080,"nodePort":30901},{"name":"health-api","port":10080,"protocol":"TCP","targetPort":10080}]}}'
```

```bash
# Tetragon 指标（chart 没给 metrics Service，自己建一个）
kubectl --context $A apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata: {name: tetragon-metrics-nodeport, namespace: kube-system}
spec:
  type: NodePort
  selector: {app.kubernetes.io/name: tetragon}
  ports: [{name: metrics, port: 2112, targetPort: 2112, nodePort: 30902}]
YAML
```

```bash
# OpenShell 指标（自动分配 NodePort；服务名以 kubectl -n openshell get svc 为准）
kubectl --context $A -n openshell patch svc openshell -p '{"spec":{"type":"NodePort"}}'
```

### 10.2 生成 scrape 配置并安装 Prometheus（plane-b）

```bash
NODE_IP=$(kubectl --context $A get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
OS_PORT=$(kubectl --context $A -n openshell get svc openshell -o jsonpath='{.spec.ports[?(@.name=="metrics")].nodePort}')
echo "plane-a node: $NODE_IP, openshell metrics port: $OS_PORT"

sed -e "s/172\.18\.0\.2/${NODE_IP}/g" -e "s/32133/${OS_PORT}/g" \
  observability/scrape-tenants.yaml > /tmp/scrape.yaml
```

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update

helm --context $B upgrade --install prometheus prometheus-community/prometheus \
  --version 27.38.0 -n monitoring --create-namespace \
  --set alertmanager.enabled=false --set pushgateway.enabled=false \
  --set kube-state-metrics.enabled=false --set nodeExporter.enabled=false \
  --set-file extraScrapeConfigs=/tmp/scrape.yaml --timeout 6m
```

验证：

```bash
kubectl --context $B -n monitoring port-forward deploy/prometheus-server 9090:9090
```

打开 `http://localhost:9090/targets`，三个 job（capsule / tetragon / openshell）都应为 **UP**。再试一条容量查询：

```promql
max by (tenant, resource) (
  capsule_tenant_resource_usage / clamp_min(capsule_tenant_resource_limit, 1)
)
```

> 讲这里：`--set-file` 是必须的——`extraScrapeConfigs` 传字符串，传布尔会类型错误。改完 ConfigMap 老 Pod 不会自动 reload，需要 `kubectl -n monitoring rollout restart deploy/prometheus-server`。

---

## 11. 创建第一个沙箱（需要 `openshell` CLI）

先确认 CLI 能连上刚部署的 gateway。CLI 的连接参数以 `openshell --help` 为准；如果默认连不上，常见做法是本地端口转发后在 CLI 里指定 endpoint：

```bash
kubectl --context $A -n openshell get svc        # 找到 gateway 的 Service 与端口
# 形如（名称/端口以实际输出为准）：
kubectl --context $A -n openshell port-forward svc/<Service 名> <本地端口>:<服务端口>
```

然后把 CLI 的 endpoint 指向 `127.0.0.1:<本地端口>`。

```bash
openshell version
openshell workspace create --name acme
```

创建沙箱，让它跑一段会一直活着的 Python：

```bash
openshell --workspace acme sandbox create --name try1 \
  --cpu 200m --memory 256Mi -- \
  python3 -u -c 'import time; print("agent up from sandbox", flush=True); time.sleep(900)'
```

检查：

```bash
kubectl --context $A -n acme get sandbox,pods
openshell --workspace acme logs try1 --since 5m
```

**应该看到**：

- 一个 `Sandbox` CR（`agents.x-k8s.io/v1beta1`）
- 一个带 agent 容器的 Pod + 一个 `os-supervisor` Pod
- 日志里出现 `agent up from sandbox`

> 讲这里：Sandbox CR 是 OpenShell 创建的，Pod 由 agent-sandbox 控制器落地——这条链就是"官方路径"的证据。

---

## 12. 看 agent 到底做了什么

需要两个终端。**终端 A** 持续看事件：

```bash
export A=kind-inske-plane-a
kubectl --context $A -n kube-system exec ds/tetragon -c tetragon -- \
  tetra getevents -o compact --namespace acme -e ProcessKProbe \
  | awk '/agent:/ {print; fflush()}'   # macOS 的 grep 没有 --line-buffered，用 awk 逐行刷出
```

**终端 B** 进入沙箱，手动制造几件"可疑但真实"的事：

```bash
export A=kind-inske-plane-a
kubectl --context $A -n acme get pods          # 找名字里带 try1 的 Pod

kubectl --context $A -n acme exec -it <Pod 名> -c agent -- sh
```

> `-c agent` 是容器名；不确定就先 `kubectl -n acme describe pod <Pod 名>` 看 Containers。

在容器里依次执行：

```bash
cat /etc/hosts                                          # 读敏感路径 -> open-sensitive
echo hi > /tmp/a && mv /tmp/a /tmp/b                    # 移动/覆盖 -> rename
touch /tmp/x1 && rm -f /tmp/x1                          # 删除 -> file-delete
python3 -c 'import os; os.system("/bin/sh -c true")'    # 起 shell -> risky-exec
```

**终端 A 应该看到**（消息名与 args 来自策略定义）：

```
agent:open-sensitive   /etc/hosts
agent:rename           /tmp/a -> /tmp/b
agent:file-delete      /tmp/x1
agent:risky-exec       caller=python3 -> /bin/sh
```

> 讲这里：事件自带租户、命名空间、Pod、二进制名，不需要任何映射表——因为 Capsule 和 OpenShell 把租户标签打在了同一个 Pod 上。
> 注意：`/bin/sh` 在 Alpine 里是 `/bin/busybox` 的软链，所以"起 shell"能被看见，但按 `/bin/sh` 写**执行强制**永远不会命中（13.2 会看到：拦得住 pip，拦不住 busybox）。

---

## 13. 演示拦截：网络与执行

仍在终端 B 的沙箱容器里。**终端 A 继续看事件。**

### 13.1 网络：两种拦法，快慢差 50 倍

```bash
# 1.1.1.1 在 Tetragon 的拒绝名单里 -> 应该 0.1 秒左右返回 PermissionError
python3 -c 'import urllib.request; urllib.request.urlopen("http://1.1.1.1", timeout=10)'
```

```bash
# 142.1.1.1 不在 Tetragon 名单里 -> 落回 NetworkPolicy，应该是 ~6 秒超时
python3 -c 'import socket; socket.create_connection(("142.1.1.1", 80), 8)'
```

**应该看到**：

```
PermissionError: [Errno 1] Operation not permitted     # 马上
TimeoutError: timed out（约 6–8 秒）                   # 挂住
```

> 讲这里：同样是"拒绝"，agent 侧的体验完全不同。快速失败能被 agent 处理（改道/报错），超时会撑爆它的重试逻辑。而且 Tetragon 更细：可以按"哪个二进制连哪个地址"决定。

### 13.2 执行：拦掉 pip，但放行 busybox

```bash
pip --version
```

**应该看到**：

```
sh: /usr/local/bin/pip: Operation not permitted
```

```bash
sh -c 'echo busybox shell still works'
```

**应该看到**：正常输出。原因：Alpine 里 `/bin/sh` 解析后是 `/bin/busybox`，而策略按真实路径匹配。所以**agent 运行时镜像建议用 Debian/Ubuntu 基座并按 digest 固定**，否则会出现"看得见、拦不住"的错觉。

---

## 14. 演示热更新：改策略不重启沙箱

回到宿主机（任意终端）：

```bash
export A=kind-inske-plane-a

# 当前版本（记下 version 和 hash）
openshell --workspace acme policy get try1
```

```bash
# 加一条"允许 python 只读访问 api.github.com:443"的策略
openshell --workspace acme policy update try1 \
  --add-endpoint "api.github.com:443:read-only:rest:enforce" \
  --binary /usr/local/bin/python3 --wait
```

```bash
# 再看一次：version 变了，hash 变了，沙箱没重启
openshell --workspace acme policy get try1
kubectl --context $A -n acme get pods
```

**应该看到**：`version 1→2`，生效策略里多出那条 endpoint；Pod 的 `AGE` 没归零。

> 讲这里：策略变更走的是"加载新 revision"，不是重建沙箱——这对有状态的 agent 很关键（工作区、内存里的上下文都不丢）。

---

## 15. 演示预热池：0.25s vs 16s

### 15.1 认领预热池

```bash
kubectl --context $A -n acme delete sandboxclaim acme-claim-2 --ignore-not-found

time ( kubectl --context $A -n acme apply -f agent-sandbox/claim-acme-2.yaml && \
       kubectl --context $A -n acme wait --for=condition=Ready \
         sandboxclaim/acme-claim-2 --timeout=60s )
```

**应该看到**：命令整体在 **1 秒内**返回（POC 仪器测得的 Ready 是 **0.25 s**，`kubectl wait` 本身有几百毫秒开销）。

### 15.2 冷启动对比

```bash
cat > /tmp/sandbox-cold.yaml <<'YAML'
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata: {name: bench-cold, namespace: acme}
spec:
  podTemplate:
    spec:
      containers:
        - name: agent
          image: python:3.12-alpine
          command: ["python3", "-u", "-c"]
          args:
            - |
              import time
              time.sleep(900)
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 200m, memory: 256Mi}
YAML

kubectl --context $A -n acme delete sandbox bench-cold --ignore-not-found

time ( kubectl --context $A -n acme apply -f /tmp/sandbox-cold.yaml && \
       kubectl --context $A -n acme wait --for=condition=Ready \
         sandbox/bench-cold --timeout=180s )
```

**应该看到**：镜像已在节点时约 **1 秒**；首次拉 20 MB 镜像时约 **16 秒**。

> 想要精确数字（不受 kubectl 开销影响），跑 `python3 scripts/bench-latency.py`：它会轮询 `status.conditions`，打印 cold / warm / speedup。
> 讲这里：预热池的代价是常驻 Pod 占租户配额，收益是首字节延迟从十几秒降到亚秒级——容量规划里必须显式算这笔账。

---

## 16. 演示配额：噪声邻居被挡住

globex 的配额很小（0.5C / 512Mi / 5 Pods），用它在自己的命名空间里"捣乱"：

```bash
for i in 1 2 3 4 5 6; do
  kubectl --context $A -n globex run n$i \
    --image=python:3.12-alpine --restart=Never \
    --requests=cpu=100m,memory=128Mi --command -- sleep 300
done
```

**应该看到**：前 4 个创建成功（4 × 128Mi = 512Mi 正好用满），第 5 个被拒：

```
Error from server (Forbidden): pods "n5" is forbidden:
exceeded quota: capsule-globex-0, requested: requests.memory=128Mi,
used: requests.memory=512Mi, limited: requests.memory=512Mi
```

检查与清理：

```bash
kubectl --context $A -n globex describe resourcequota capsule-globex-0
kubectl --context $A -n globex delete pod --all
kubectl --context $A -n globex get resourcequota capsule-globex-0 -o jsonpath='{.status.used}'
```

> 讲这里：配额是**租户边界**，不是集群边界。acme 的预热池再大，也不会挤占 globex 的份额；反过来，一个租户的沙箱失控也只会在自己的配额里打转。

---

## 17. 收尾

```bash
kind delete cluster --name inske-plane-a
kind delete cluster --name inske-plane-b
rm -rf vendor
```

如果只想停掉 Demo 但保留环境，跳过删除；`helm upgrade --install` 和 `kubectl apply` 都可以原样重跑。

---

## 附 A. 10 分钟演示动线（讲给别人听时按这个顺序）

如果时间有限，只讲这 6 段，其余作为"已经验证过"的证据：

1. **展示租户边界**：`kubectl get tenant` + `kubectl -n acme get resourcequota` —— 一句话："配额、命名空间、标签都是声明出来的。"
2. **跑起来**：`openshell sandbox create` + `kubectl -n acme get pods` —— "agent 是非 root，只有边界端口 5500 通往 supervisor。"
3. **看得见**：终端 A 滚 Tetragon 事件，终端 B 在沙箱里 `cat /etc/hosts` —— "每次访问都带租户和二进制，被拦掉的尝试也记。"
4. **拦得住**：`1.1.1.1` 立刻 PermissionError vs `142.1.1.1` 6 秒超时 —— "同样是拒绝，agent 的体验差 50 倍。"
5. **改策略不重启**：`policy update --wait` 后 `policy get` 版本 +1 —— "有状态 agent 不重来。"
6. **快**：认领预热池 < 1 秒 vs 冷启动 16 秒 —— "把首字节延迟压到亚秒。"

## 附 B. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `kind create` 卡住 / OOM | Docker VM 内存不足 | Docker Desktop 调到 ≥ 8 GiB，删掉旧集群重试 |
| Tetragon Pod `CrashLoopBackOff` | 内核没有 BTF | 换内核 ≥ 5.4 且带 BTF 的环境；Docker Desktop 6.12 可用 |
| `operator namespace allowlist` 只有 1 个 ns | 该租户 ns 少了 `openshell.ai/workspace=true` | 检查 Tenant 的 `additionalMetadata.labels`，重建 ns |
| `Secret openshell-client-tls does not exist` | `sandboxNamespace` 指到了租户 ns | 留空（= release ns） |
| 预热池 Pod 一直 `Pending` | 池超过租户配额 | 调小 `replicas` 或提高租户配额；确认 template 写了 `resources` |
| Prometheus target `DOWN` | NodePort / 节点 IP 不对 | 重跑 10.2 的 `NODE_IP` / `OS_PORT` 两行，check `curl 节点IP:30901/metrics` |
| `pip` 拦不住 | 镜像是 Alpine，pip 可能是软链 | 换 Debian/Ubuntu 基座，或按 busybox 形态写策略 |
| 事件里没有 `agent:*` | 策略的 `podSelector` 对不上租户标签 | `kubectl -n acme get pod --show-labels` 看 `projectcapsule.dev/tenant` |
| 有 `open-sensitive` 但没有 `file-delete` | 不同架构上 `rm` 走 `sys_unlink` 还是 `sys_unlinkat` 不同 | 用 `python3 -c 'import os; os.remove("/tmp/x1")'` 复现；策略要按架构对齐（见 FINDINGS §3） |

## 附 C. 和 `bootstrap.sh` 的对应关系

| 本文步骤 | 脚本里的段落 |
|---|---|
| 1 | `### 1/6 创建两个 kind 集群` |
| 2 | `### 2/6 plane-a: agent-sandbox` |
| 3–5 | `### 3/6 cert-manager + Capsule`、`### 4/6 租户` |
| 6 | `### 5/6 Tetragon` |
| 7–8 | `### 6/6 OpenShell gateway + workspace` |
| 9 | `### 租户侧安全策略…` |
| 10 | `### 观测栈放在 plane-b…` |
| 11–16 | 脚本不包含，属于演示动作 |

> 两边版本号是同一组：agent-sandbox v1.0.9 / Capsule 0.15.2 / Tetragon 1.8.0 / OpenShell 0.1.4。改一边记得改另一边。

---

> 想先看结论：[一页看懂](index.html) · [文字简版](SUMMARY.md) · [详细架构](architecture.html) · [逐项证据](FINDINGS.md)
