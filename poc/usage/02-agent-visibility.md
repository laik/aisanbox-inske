# 在 Tetragon 里看"agent 访问了谁 / 做了哪些危险操作"

下面每条命令与查询都在本 POC 实测跑通过。

## 1. 三条可见性通道，各看什么

| 通道 | 看到什么 | 用途 |
|---|---|---|
| `tetra getevents` | 实时内核事件(带 K8s 身份) | 排障、临时取证 |
| `/var/log/tetragon/tetragon.log`（节点上的 JSONL） | 全量事件流 | 进 Loki/ES/SIEM，长期审计 |
| `:2112/metrics` | 按租户/命名空间/二进制的**计数** | 告警、趋势、容量 |

事件里的 K8s 身份是这套设计能落到租户维度的原因：
```
process.pod.namespace = acme
process.pod.labels    = {"projectcapsule.dev/tenant":"acme", ...}   # Capsule 注入
process.pod.workload  = poc-acme-1
process.uid           = 10001                                        # OpenShell 以非 root 运行
process.binary / arguments / parent                                  # 调用链
```

## 2. 访问了谁（网络）

```bash
# 实时: 该租户所有 sandbox 的出站连接（含被拦掉的尝试）
kubectl -n kube-system exec ds/tetragon -c tetragon -- \
  tetra getevents -o compact --namespace acme -e ProcessKProbe | grep agent:
```
实测输出（`type: sock` 给出完整五元组）：
```
agent:in-cluster      saddr=10.244.0.19 daddr=10.96.0.10  sport=48100 dport=53
agent:egress-external daddr=1.1.1.1  dport=53     <- 被 NetworkPolicy 拦了，仍然被记录
agent:egress-external daddr=142.1.1.1 dport=80
agent:listen          saddr=0.0.0.0 sport=31339    <- agent 自己起了服务 = 暴露面变化
```

**关键性质**：被拦掉的连接一样会被记录。Tetragon 记的是**尝试**，NetworkPolicy/OpenShell 只决定它成不成功。所以"agent 试过连哪儿"这件事，只有这一层能看到。

趋势与告警（PromQL，已跑通）：
```promql
# 各租户 agent 的出站尝试次数（按被观测到的二进制归因）
sum by (namespace, binary) (rate(tetragon_events_total{namespace=~"acme|globex", event_type="PROCESS_KPROBE"}[5m]))

# 某租户 sandbox 起了多少个监听端口（暴露面）
sum by (namespace) (increase(tetragon_events_total{namespace="acme"}[10m]))
```

## 3. 做了哪些危险操作

实测命中样本（就是 POC 里真实发生的）：

| 行为 | 策略 message | 实测到的 args |
|---|---|---|
| 读配置/凭据目录 | `agent:open-sensitive` | `/etc/hosts`, `/etc/resolv.conf`, `/etc/ld.so.cache` |
| 删除文件 | `agent:file-delete` | `/tmp/x1` |
| 移动/覆盖 | `agent:rename` | `/tmp/a` -> `/tmp/b` |
| 起 shell | `agent:risky-exec` | caller=`/usr/local/bin/python3` -> exec target=`/bin/sh` |
| 装包 | `agent:package-manager` | pip（LSM bprm 命中） |
| 出网尝试 | `agent:egress-external` | daddr=1.1.1.1:53 |
| 起服务 | `agent:listen` | 0.0.0.0:31339 |

取证用 JSON 直接查（节点上的导出文件）：
```bash
# 该租户 agent 删过哪些文件
kubectl -n kube-system exec ds/tetragon -c tetragon -- sh -c \
  'grep -h "agent:file-delete" /var/log/tetragon/tetragon.log' \
  | python3 -c 'import sys,json;[print(json.loads(l)["process_kprobe"]["arguments"]) for l in sys.stdin]'
```

## 4. 另一条必须同时看的信息：OpenShell 的判定

Tetragon 说"发生了什么"，OpenShell 说"平台允许什么"。两者要放一起才有结论：

```bash
openshell --workspace acme policy get poc-acme-1     # 当前生效策略 + hash + version
openshell --workspace acme policy list poc-acme-1    # 变更历史
openshell --workspace acme logs poc-acme-1 --since 30m   # 含 OCSF 判定: NET:OPEN ALLOWED/DENIED
```
网关自身指标（已在 POC 里跨集群抓取成功）：
```promql
rate(openshell_server_grpc_requests_total[5m])            # 按 method 看控制面负载
sum(increase(openshell_server_ocsf_otlp_dropped_total[10m]))  # 审计是否丢事件
```
Supervisor 日志本身就是 OCSF 结构化事件：
```
OCSF CONFIG:LOADED  Policy revision loaded [version:2] [hash:21baa807...]
OCSF NET:OPEN [MED] DENIED /usr/bin/curl(64) -> api.github.com:443 [policy:- engine:opa]
```
（`NET:OPEN ... DENIED` 这行是官方文档格式；本 POC 里 sandbox 的 DNS 先失败，所以没有产生该行 —— 见 §6。）

## 5. 把事件接到日志管线

Tetragon chart 默认写 `/var/log/tetragon/tetragon.log`（节点 hostPath，10MB×5 轮转）。生产上：
- 用 DaemonSet 采集器读该路径（本 POC 里 `export-stdout` 容器已在做同一件事）；
- 或打开 `tetragon.otlp`，把事件走 OTLP 出到 collector（与 OpenShell 的 OCSF 导出可共用 collector）；
- 按租户隔离在标签上已经具备（`namespace` + `projectcapsule.dev/tenant`），无需自建映射。

建议同时在 chart 上收紧默认导出，否则全集群事件量很大：
```yaml
tetragon:
  exportAllowList: '{"event_set":["PROCESS_EXEC","PROCESS_KPROBE"]}'
  exportDenyList: '{"namespace":["kube-system",""]}{"health_check":true}'
  exportRateLimit: 2000        # 每租户可接受的速率上限
```

## 6. 本 POC 里没得到预期结果的一处（值得你注意）

我给 sandbox 加了 L7 出网策略并成功热更新（`policy version 1 -> 2, loaded`），但沙箱内的 DNS 解析仍失败：
```
resolv.conf -> nameserver 127.0.0.53      # 指向本地解析器
到 supervisor podIP:53 / :8080 超时；到 cluster DNS 10.96.0.10:53 反而通
```
也就是说 agent 的 DNS 走的是集群 CoreDNS，而不是 supervisor 的边界。要得到官方教程里那种
`curl: (56) Received HTTP code 403 from proxy after CONNECT` 的行为，还需要让沙箱 DNS 落到 supervisor
（本 POC 未定位到具体开关）。这不影响上面所有观测与强制结论，但影响"用 L7 策略放行出网"这条路径，
建议你在自己的环境里先验这一段。
