#!/usr/bin/env bash
# 让 apiserver 证书对**宿主 IP** 有效 —— 外部可访问的必要条件之二。
#
# 实测(kind v0.33 / K8s v1.37)，两个坑:
#  (1) 只配 apiServerAddress 时证书 SAN 是 [10.96.0.1, <节点IP>, 0.0.0.0]。端口发布到了
#      宿主，但用宿主 IP 连得到
#        x509: certificate is valid for ..., not 192.168.5.190
#      —— 网络通了、TLS 没过。
#  (2) 想通过 kind 的 kubeadmConfigPatches 加 SAN 时，字段名是 **certSANs**，不是
#      extraSANs。写错名字 kind **不报错也不生效**(集群照常创建，SAN 不变) ——
#      这类"静默无效"必须靠看证书本身来发现，不能靠创建是否成功。
#
# 本脚本做的是生产上会给 apiserver 加 SAN 的同一件事: 改 kubeadm 的 ClusterConfiguration
# (certSANs) → 重新生成 apiserver 证书 → 重启静态 Pod。幂等，可重复跑。
# 注: 节点镜像里没有 python3，所以 YAML 编辑在**宿主**上做，再送进节点。
set -euo pipefail
NODE=${NODE:-agent-runtime-poc-control-plane}
SAN=${SAN:-192.168.5.190}
CTX=${CTX:-kind-agent-runtime-poc}

kubectl --context $CTX -n kube-system get cm kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' > /tmp/cc-in.yaml
python3 - "$SAN" <<'PY'
import sys, yaml
san = sys.argv[1]
cc = yaml.safe_load(open("/tmp/cc-in.yaml"))
api = cc.setdefault("apiServer", {})
sans = set(api.get("certSANs") or [])
sans.update([san, "127.0.0.1", "localhost"])
api["certSANs"] = sorted(sans)
yaml.safe_dump(cc, open("/tmp/cc-out.yaml", "w"))
print("   目标 certSANs:", api["certSANs"])
PY
# 不用 docker cp: 往节点的 /tmp 里 docker cp 会"成功"但 exec 看不到(kind 节点里
# /tmp 是 tmpfs，cp 写到了挂载点之下)。用 stdin 写最稳。
docker exec -i "$NODE" bash -c 'cat > /run/cc.yaml' < /tmp/cc-out.yaml
docker exec "$NODE" bash -ec '
  [ -f /etc/kubernetes/pki/apiserver.crt ] && cp /etc/kubernetes/pki/apiserver.crt /tmp/apiserver.crt.bak || true
  # 关键: kubeadm 的 certs 阶段对 apiserver 证书有"已存在且 CA 未变就 skip"的判断 ——
  # 光改 certSANs 不会重写证书，日志里是
  #   [certs] Skipping "apiserver" ...
  # 所以必须显式删掉 crt/key 再跑这个 phase。(生产上用 kubeadm init phase certs 同样如此;
  #  kops/RKE 之类的实现会自己检测 SAN 变化,这里是手工流程要自己处理。)
  rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
  kubeadm init phase certs apiserver --config /run/cc.yaml 2>&1 | grep -E "Generating|signed for" | sed "s/^/     /"
  mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml
  sleep 8
  mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
'
echo "   等新 apiserver Ready…"
for i in $(seq 1 60); do kubectl --context $CTX get --raw=/readyz >/dev/null 2>&1 && break; sleep 2; done
kubectl --context $CTX get --raw=/readyz >/dev/null && echo "   readyz: ok" || { echo "   ✗ apiserver 没回来"; exit 1; }
echo "   节点内新证书 SAN:"
docker exec "$NODE" bash -ec 'openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName' | tail -1 | sed 's/^/     /'
