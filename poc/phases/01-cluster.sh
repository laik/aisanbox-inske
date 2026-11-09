#!/usr/bin/env bash
# Phase 1a —— 创建 kind 集群 (POC2 §3.2)
# 手工重现: bash poc/phases/01-cluster.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
# 本轮宿主: 192.168.5.190。kind 把 apiserver 发布在宿主 0.0.0.0:6443，
# 所以**集群外**也能用 kubectl —— 前提是用一份 server=宿主IP 的 kubeconfig。
HOST_IP=${HOST_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')}

kind create cluster --config kind/poc2-cluster.yaml --wait 180s || true
# 注意: 没有 CNI 时节点会一直 NotReady —— 这是预期结果，不是失败。
echo "### 此刻节点应当 NotReady（disableDefaultCNI: true）"
kubectl --context $CTX get nodes
echo "### Service CIDR / Pod CIDR（后面 Tetragon 网络策略要用）"
kubectl --context $CTX -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep -E 'podSubnet|serviceSubnet' || true

# ---------------------------------------------------------------------------
# 外部可访问(用户要求): kind 自己写的 kubeconfig 里 server 是 127.0.0.1。
# 在宿主上用没问题；要让别的机器连进来必须换 server。
# 实测要点: kind 0.33 + apiServerAddress: 0.0.0.0 会把 6443 作为 docker 端口发布到
# 宿主所有网卡，所以只需要**改 kubeconfig 里的地址**，不需要额外的 LB。
# ---------------------------------------------------------------------------
# apiserver 证书要先包含宿主 IP，否则外部连是 TLS 失败(见 kind/fix-apiserver-sans.sh)
echo
echo "### 给 apiserver 证书加宿主 IP 的 SAN"
SAN="$HOST_IP" bash kind/fix-apiserver-sans.sh

echo
echo "### 生成外部 kubeconfig(server=$HOST_IP:6443)"
KUBECFG="$PWD/kubeconfig-external.yaml"
kind export kubeconfig --name agent-runtime-poc --kubeconfig "$KUBECFG"
# kind 0.33 在 apiServerAddress: 0.0.0.0 时把 server 写成 https://0.0.0.0:6443 ——
# 0.0.0.0 是**监听**地址，不是可连接的地址；kubectl 连它会失败(或连到本机)。
# 所以这里要替换的是"任意 host:6443"，不只是 127.0.0.1。
sed -i -E "s#https://([0-9.]+|127\.0\.0\.1|0\.0\.0\.0):6443#https://${HOST_IP}:6443#g" "$KUBECFG"
echo "   写出: $KUBECFG"
grep -n "server:" "$KUBECFG" | sed 's/^/     /'
echo "   从集群外验证(用宿主 IP，不走 kind 内部地址):"
KUBECONFIG="$KUBECFG" kubectl get --raw=/readyz | sed 's/^/     readyz: /'
KUBECONFIG="$KUBECFG" kubectl get ns --no-headers | wc -l | awk '{print "     从外部读到 namespace 数="$1}'
echo "   另一台机器上:"
echo "     export KUBECONFIG=<这份文件>"
echo "     kubectl --context kind-agent-runtime-poc get nodes"
