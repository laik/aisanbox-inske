前提：cert-manager 本体要先装

chart 只创建 Issuer/Certificate 资源，不装 cert-manager 本身（values 注释原话）。先装：

helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true
kubectl -n cert-manager rollout status deploy/cert-manager-webhook

OpenShell 的 values（内网域名场景，就是你现在这套）

certManager:
  enabled: true                      # 总开关：chart 生成整条私有 CA 链
  # serverIssuerRef 留空 → 全部用 chart 自己的 CA。
  # .home.rapa 是内网域名，Let's Encrypt 签不了，私有 CA 是唯一正解。
  serverDnsNames:                    # 服务端证书 DNS SAN（内部名建议保留）
    - openshell-vm.home.rapa
    - openshell
    - openshell.openshell.svc
    - openshell.openshell.svc.cluster.local
  serverIpAddresses:                 # IP SAN
    - 192.168.5.221
  certificateDuration: 8760h         # 证书有效期（默认 1 年）
  certificateRenewBefore: 720h       # 提前 30 天自动续期
  clientCaFromServerTlsSecret: true  # 默认 true，别动：mTLS 客户端 CA 挂内部
                                     # server secret 的 ca.crt，与 client 证书同 CA

service:
  type: NodePort                     # 外部入口 31761 这类；要 443 另加 ingress

# pkiInitJob.enabled 保持默认 true！
# certManager.enabled=true 时这个 hook 自动变 JWT-only 模式，
# 负责生成 cert-manager 不管的 sandbox JWT 签名 Secret。
# （你现有 release 设了 false，是因为 JWT secret 早已存在；全新安装别关。）

helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.1.7 -n openshell --create-namespace -f values.yaml

装完 chart 会自动建好这条链（就是你集群里现在看到的）：

Issuer openshell-selfsigned
  └─ Certificate openshell-ca (isCA) → Secret openshell-ca-tls
       └─ Issuer openshell-ca-issuer
            ├─ Certificate openshell-server → openshell-server-tls（gateway 服务端 + client CA）
            └─ Certificate openshell-client → openshell-client-tls（supervisor/CLI 客户端）

两个关键注意

1. serverIssuerRef 是给公网域名用的：填一个真实 ACME ClusterIssuer 时，chart 会另签第二张只含 serverDnsNames 的外部证书；内部证书永远由 chart CA 签（mTLS 客户端信任锚不变）。内网场景留空。
2. 别混用两套 PKI——昨天 unknown ca 的根因就在这：先有 chart pkiInitJob 生成的旧 CA secret，再让 cert-manager 接管，ca.crt 键残留旧 CA 造成裂脑。全新安装从一开始就 certManager.enabled: true，secret 全由 cert-manager 创建，天然一致。装完体检一条：

# client 证书的 AKI 必须等于 server secret ca.crt 的 SKI
kubectl -n openshell get secret openshell-client-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -A1 "Authority Key"
kubectl -n openshell get secret openshell-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -text | grep -A1 "Subject Key"

你现有 release 已经是这个形态（rev 5），等价升级命令就是昨天那条 helm upgrade --reuse-values --set 'certManager.serverDnsNames={…}'。