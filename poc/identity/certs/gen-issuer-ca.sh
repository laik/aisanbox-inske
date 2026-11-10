#!/usr/bin/env bash
# POC3 —— 给 OIDC issuer 签一份证书。
#
# 为什么必须自己签: kube-apiserver 的 --oidc-issuer-url **只接受 HTTPS**(实测 1.37 的 --help:
#   "The URL of the OpenID issuer, only HTTPS scheme will be accepted")。
# 所以"集群内起个 HTTP 的 Keycloak"这条路不存在 —— 必须有 TLS + 一个所有验证方都信任的 CA。
#
# issuer 主机名怎么选(实测):
#  - kind 节点**不解析**集群内 DNS(节点 resolv.conf 只有 docker 网关 172.22.0.1，search .)，
#    所以 issuer 不能用 keycloak.identity.svc.cluster.local;
#  - 宿主 IP(192.168.5.190)能被节点访问，但 NodePort **不会自动发布到宿主** —— 要 extraPortMappings，
#    而那只能在**建集群时**配(POC2 记录过同一条: 31686 就是这么来的)。重建集群 = 重跑 13 个 phase。
#  - ⇒ 用**控制平面节点的 IP** + NodePort: 节点访问自己节点 IP 上的 NodePort 天然可用，
#    宿主机也在 kind 的 docker 网络里(172.22.0.0/16)，能直连节点 IP。
#  ⚠ 代价必须写下来: issuer URL 里含**节点 IP**。集群重建后 IP 变了，所有已签发 JWT 立即失效、
#    RBAC 绑定还在但再也匹配不上 —— 这是**整体鉴权失败**(响)，不是"隔离静默失效"。生产要用稳定域名。
set -euo pipefail
OUT=$(cd "$(dirname "$0")" && pwd)
NODE_IP=${NODE_IP:-172.22.0.3}
HOST_IP=${HOST_IP:-192.168.5.190}

openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
  -keyout "$OUT/issuer-ca.key" -out "$OUT/issuer-ca.crt" \
  -subj "/CN=aisanbox-poc3-issuer-ca" \
  -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

openssl req -newkey rsa:2048 -nodes -keyout "$OUT/issuer.key" -out "$OUT/issuer.csr" \
  -subj "/CN=aisanbox-poc3-keycloak" 2>/dev/null
openssl x509 -req -in "$OUT/issuer.csr" -CA "$OUT/issuer-ca.crt" -CAkey "$OUT/issuer-ca.key" \
  -CAcreateserial -days 825 -sha256 -out "$OUT/issuer.crt" \
  -extfile <(printf "subjectAltName=IP:%s,IP:%s,DNS:keycloak.identity.svc.cluster.local,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" "$NODE_IP" "$HOST_IP") 2>/dev/null

echo "wrote issuer-ca.crt / issuer.crt / issuer.key for SAN IP:$NODE_IP,IP:$HOST_IP"
openssl x509 -in "$OUT/issuer.crt" -noout -ext subjectAltName
