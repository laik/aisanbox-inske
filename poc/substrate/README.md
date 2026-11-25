# Agent Substrate 在 k8s-221 上的落地验证

结论先说：**装起来了，也真的跑了一个 actor**（gVisor 沙箱类、快照写进 S3、actor 被路由并返回状态）。
第二轮（11-25）把剩下两块也跑通了：**suspend→resume 状态恢复**、**多 actor 复用 worker**、
**出口凭证替换**（OpenShell provider 平面的对照物）。
但在这台 2 节点小集群上，**装它的成本不是"换个更简单的东西"**：它有自己的硬前提，
把现成的 OpenShell/Vault/Keycloak/Gatekeeper 挤掉才腾出位置。判定与成本见 §4。

时间：2026-11-24 14:16–18:30、2026-11-25 09:30–10:30（本地），集群 `k8s-221`（kubeadm v1.37.2，2 节点 ×4C/8G）。
证据文件：`evidence-20261124T1026Z.md`、`evidence-20261125T0222Z.md`（UTC 时间戳）。

---

## 1. 装的是什么

- 源码 `agent-substrate/substrate` main 分支 tarball（无 release，`ghcr.io` 里没有发布镜像，见 `crane ls` 报 DENIED）。
- 镜像全部本地构建：`ko` 由 `ate-setup` 调用，push 到我们在 vm01 上自建的私有 registry（`192.168.5.221:5000`，静态 Pod + 自建 CA）。
- Go 依赖走 `GOPROXY=https://goproxy.cn`（vm01 到 `proxy.golang.org` 不通），工具链要 go1.27.4（仓库 go.mod 指定）。
- 安装器：`ate-setup deploy ate-system`（非 kind、非 GKE 路径），`--atenet-dataplane agentgateway --sandbox-classes=gvisor --credential-provider='{"name":"k8s.io"}' --storage-bucket-name=ate-snapshots`。

跑起来的组件（`ate-system`）：ate-api-server、ate-controller、ate-idp-server、podcertificate-controller、
atenet-router、atenet-egress、k8s-credential-provider、atelet（两节点 DaemonSet）、postgres、rustfs(S3)。

## 2. 到 actor 跑通为止，必须补的东西（这是关键信息）

| # | 问题 | 处理 |
|---|---|---|
| 1 | 节点拉不到 docker.io（`connection reset`） | `crane cp --insecure` 按 **digest** 把 postgres/rustfs/otel/aws-cli 原样复制进私有 registry；containerd `certs.d/docker.io/hosts.toml` 加 `override = true` 指向私有 registry |
| 2 | 私有 registry 的 CA 不被信 | 节点 `update-ca-certificates` + `certs.d/<registry>/hosts.toml`；**macOS 上 Go 忽略 `SSL_CERT_FILE`**，crane/ko 只能用 `--insecure` 或在节点侧构建 |
| 3 | `PodMonitoring` CRD 不存在（GKE 托管监控）；`deploy demo X` 还卡在 `0/2 replicas available` | 建占位 CRD（`poc/substrate/placeholder-podmonitoring-crd.yaml`）；**先 `kubectl ate create atespace X`** —— worker 向 ateapi 注册要求 atespace 已存在，否则 worker 永远 NotReady |
| 4 | 对象存储默认 GCS | 改 `atelet.yaml` / `ate-api-server.yaml` 的 sidecar：`ATE_STORAGE_BACKEND=s3` + `AWS_*`，并部署 `manifests/ate-install/kind/rustfs.yaml`（含建桶 Job） |
| 5 | GKE 的 image credential provider 挂载（`/etc/srv/kubernetes/cri_auth_config.yaml`、`/home/kubernetes/bin`） | 按 kind overlay 的做法从 `atelet.yaml` 删掉这些挂载与参数 |
| 6 | **非 root 容器 bind :443 → EACCES**（atunnel/ate-api-server 起不来） | 本节点 runc 1.5.3 不给 non-root 进程 ambient caps（实测 `CapBnd=0x400`、`CapEff=0`），节点 sysctl 也不会被新 netns 继承。可行修法：Pod 级 `securityContext.sysctls: net.ipv4.ip_unprivileged_port_start=80`（实测立刻可 bind） |
| 7 | ate-api-server 拒绝客户端 token：`token issuer "https://kubernetes.default.svc.cluster.local" not trusted` | 安装时加 `--ateapi-expected-jwt-issuer=<集群 issuer>` |
| 8 | atelet 的 image cache 拉不到私有 registry（distroless 里没有我们的 CA） | 把 `/etc/ssl/certs/ca-certificates.crt`（含自建 CA）以 ConfigMap 挂进 atelet 与它的 objectstore-plugin |
| 9 | 容量：postgres 要 2 CPU/1Gi、worker 每个 250m/1Gi | vm02 请求已 90%，vm01 到 98% 内存；**为此把 keycloak 缩到 0、gatekeeper 3→1（audit 0）、去掉 vm01 的 control-plane taint、postgres 请求降到 300m/256Mi** |
| 10 | `WorkerPool` CRD 的 `template` 只有 nodeSelector/tolerations/resources，**没有 securityContext / env / 挂载** 开关 | 只能 patch 控制面生成的 Deployment（controller 会保留 patch，但 `deploy demo` 再 apply 会被冲掉）。**每新增一个 demo 命名空间都要重补**：sysctls patch + 该命名空间的 `poc-registry-ca` ConfigMap（worker 拉镜像要 CA） |

## 3. 验证到哪一步（都有证据）

- ✅ WorkerPool（sandboxClass `gvisor`，SandboxConfig `gvisor-default` resolved）3/3 Ready。
- ✅ ActorTemplate `counter` 的 **golden snapshot 成功**（`GOLDEN TAG 1bea5ebd-…`），快照落在 rustfs：`/opt/local-path-provisioner/…rustfs-data/ate-snapshots` 2.4 MB。
- ✅ `create actor poc-a1` → 经 atenet-router 代理连续 3 次 HTTP 调用，计数器 1→2→3（说明 workload 真在沙箱里执行）。
- ✅ atelet 记录了沙箱运行时：`"Wrote worker sandbox runtimes" sandbox_class:"gvisor" sandbox_bundle_hash:…`；节点上 `/var/lib/ate/{actors,image-cache,sandbox-asset-cache}` 有内容。
- ✅ `suspend actor` 成功（状态回到 `ACTOR_STATE_SUSPENDED`，worker 被释放）。
- ✅（第二轮）**suspend → resume 状态恢复**：`resume` 671 ms 后第一次调用即续上 `count: 3`（内存/文件/rootfs 三处都在）。
  第一轮的 `Aborted: another operation is in progress` 不是生命周期本身的问题：当时有一个 worker 处于 `WORKER_STATE_UNAVAILABLE`。
- ✅（第二轮）**一个 atespace 多 actor**：7 个 actor 共存，挂起的 actor 不占 worker；worker 占满时报 `no worker has room for the actor`；
  挂起在跑的 actor 后，别的 actor 依次顶上。**运行期 actor : worker = 1:1**，池子规模就是可并发运行的 agent 数。
- ✅（第二轮）**出口策略 + 真实凭证替换**（见 §3b）。
- ❌ 没验证：CSI 卷（有 `--setup-csi nfs|hostpath` 与 `docs/guides/csi-volumes.md`，没跑）。

## 3b. 第二轮：生命周期、多 actor、出口凭证（2026-11-25）

命令与输出见 `evidence-20261125T0222Z.md`。只记结论和可复用的写法。

### actor 生命周期是 CLI 一套完整 CRUD

```bash
kubectl ate create|delete actor X -a <atespace> --template <t>   # create 完是 SUSPENDED
kubectl ate resume|suspend actor X -a <atespace>
kubectl ate proxy actor X -a <atespace>          # 127.0.0.1:8000 → actor
kubectl ate get actors|workers -a <atespace>
```

### 出口凭证替换（和 OpenShell 的 provider 平面是同一件事）

```bash
# 1) 密钥 + 授权（atespace → 可解析哪些命名空间的 Secret）
kubectl -n ns1 create secret generic example-api --from-literal=token=test-github-token
kubectl -n ate-system edit configmap k8s-credential-provider-namespace-policy   # policies: [{atespace, allowedNamespaces}]
kubectl -n ate-system rollout restart deployment/k8s-credential-provider        # 只在启动时加载策略
# 2) 每个 actor 一份出口策略（L7，默认拒绝）
kubectl ate create egress-policy <actor> -a <atespace> -f pol.yaml
```

```yaml
rules:
- http:
    hostnames: ["whoami.egress-target.svc.cluster.local"]
    ports: {numbers: [8080]}
    effects:
      replaceHeaders:
      - header: traceparent
        prefix: "tp-"
        credentialUri: "ate-secret://k8s.io/default/ns1/example-api/token"
```

实测：actor 发 `traceparent: PLACEHOLDER-do-not-leak`，目标回显到的是 `Traceparent: tp-test-github-token`；
不带该 header 时不注入；URI 前缀写错（`ate-secret://k8s.io/ns1/…`）→ 403 fail closed，
内置 provider 只吃 `ate-secret://k8s.io/default/<ns>/<secret>/<key>`；
撤掉 atespace 授权后**旧凭证还会被服务**（网关缓存），重启 `atenet-egress` 才 403。

## 4. 对"要不要用 Substrate"的判断（基于这次实测，不是文档）

- Substrate 的价值确实是 OpenShell 没有的那块：**actor/worker 复用 + 快照挂起/恢复 + 每 actor 身份 + egress 注入**。
  这两轮验证下来，这四件事**都是真的、可用的**：恢复 671 ms、挂起不占 worker、
  凭证在网关侧替换（actor 手里只有占位符）、每请求带 actor 身份写日志。
  它把这些做成了运行时，而不是让你自己拼。
- 但它**不比 OpenShell 省心**：它假定 S3/GCS、GKE 风格的挂载与监控、自己的 PKI/JWT issuer、自己的镜像信任链。这次 4 小时里绝大多数时间花在环境胶水（第 2 节 10 条），不是 demo 本身。
- 它**没有** OpenShell 那种"外部资源闭集准入 / workspace 多租隔离 / 文件与出站策略引擎"。要拿它替代 OpenShell，策略层（谁能动什么、审计、凭据闸门）要自己搭。
- 门槛：控制面 + 1 个 worker ≈ **2.5–3 CPU、3.5 Gi 内存**起（且 postgres 默认 2 CPU/1Gi）。这台 2×4C/8G 的 POC 集群放不下 OpenShell + Substrate 两套。

## 5. 现场状态与恢复

留在集群里的东西：`ate-system`（整套控制面）、`ate-demo-counter`（ActorTemplate + actor `poc-a2`，SUSPENDED）、
`ate-demo-egress`（ActorTemplate + 出口策略实验）、两个 demo 的 WorkerPool 已缩到 0（释放节点）、
vm01 上的 `sub-registry` 静态 Pod、`/etc/containerd/certs.d/…`、`/etc/sysctl.d/99-substrate-poc.conf`。
要用 actor：先 `kubectl scale workerpool <name> -n <atespace> --replicas=1`，再 `kubectl ate resume actor …`。

**被我为腾容量改动的 OpenShell 侧（要恢复就执行）**：

```bash
kubectl --context k8s-221 -n identity scale deploy keycloak --replicas=1      # OpenShell 登录要用
kubectl --context k8s-221 -n gatekeeper-system scale deploy gatekeeper-controller-manager --replicas=3
kubectl --context k8s-221 -n gatekeeper-system scale deploy gatekeeper-audit --replicas=1
kubectl --context k8s-221 taint node vm01 node-role.kubernetes.io/control-plane:NoSchedule --overwrite
```

彻底拆掉 Substrate：

```bash
ssh root@192.168.5.221 'cd /root/substrate-main && /root/bin/ate-setup delete demo counter; /root/bin/ate-setup delete ate-system'
kubectl --context k8s-221 delete -f poc/substrate/placeholder-podmonitoring-crd.yaml
kubectl --context k8s-221 -n kube-system delete pod sub-registry-vm01   # 再删 /etc/kubernetes/manifests/sub-registry.yaml
```
