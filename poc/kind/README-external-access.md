# 从集群外访问这个 kind 集群

kind 配置里已经开了:

```yaml
networking:
  apiServerAddress: "0.0.0.0"
  apiServerPort: 6443
```

实测(kind v0.33.0 @ Ubuntu 24.04 / 内核 6.8):

- 宿主上 `docker-proxy` 把 `0.0.0.0:6443` 发布出去，`ss -ltnp` 可见；
- `curl -k https://<宿主IP>:6443/version` 从另一台机器返回 v1.37.0 —— **外部可访问是真的通了**。

## 两个坑

1. `kind export kubeconfig` 在 `apiServerAddress: 0.0.0.0` 时写出的 server 是
   `https://0.0.0.0:6443`。0.0.0.0 是**监听**地址不是**可连接**地址，kubectl 会连不上。
   必须换成宿主 IP(见 `phases/01-cluster.sh` 末尾的 sed)。
2. 本机(macOS + Clash TUN, `utun4 198.18.0.1/15`)上 **Go 编译的程序(kubectl / helm)连不上**
   这个 IP，所有端口都是 `connect: no route to host`；同一个端口 `curl` / `nc` 正常。
   这不是集群的问题，是本机代理对 Go socket 的拦截。两条解决办法:
   - 用 SSH 隧道(推荐,见下),或
   - 在本机关掉 TUN 模式 / 把该 IP 加入其 bypass 列表。

## 用法

```bash
# A) 直连(在别的 Linux 机器上，或本机代理不拦 Go 时)
export KUBECONFIG=poc/kubeconfig-external.yaml
kubectl --context kind-agent-runtime-poc get nodes

# B) 本机走 SSH 隧道(16443 -> 远端 6443)
bash poc/kind/ssh-tunnel.sh &        # 前台保持
export KUBECONFIG=poc/kubeconfig-tunnel.yaml
kubectl --context kind-agent-runtime-poc get nodes
```

## 顺带说明: 集群内的服务想被外面看

kind 只发布 apiserver。演示时要看 Jaeger UI 用 NodePort(见 `observability2/collector.yaml`
里 `nodePort: 31686`)，浏览器直接开 `http://<宿主IP>:31686` —— 这条路不受上面 Go 的问题影响。
