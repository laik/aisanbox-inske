# 集群侧私有 registry 与镜像信任（vm01:5000，自建 CA）

- 静态 Pod：`/etc/kubernetes/manifests/sub-registry.yaml`（hostNetwork :5000，`registry:3` 镜像用 `ctr -n k8s.io images import` 预导入，数据在 `/var/lib/substrate-registry`）。
  注意：`subPath` 不能用在 `type: File` 的 hostPath 上（CreateContainerConfigError），挂目录。
- containerd 必须开 hosts-dir：config.toml 里 legacy 键 `[plugins."io.containerd.grpc.v1.cri".registry] config_path = "/etc/containerd/certs.d"`
  （追加 new-style `[plugins."io.containerd.cri.v1.images".registry]` 会被迁移覆盖，不生效）。
- `/etc/containerd/certs.d/192.168.5.221:5000/hosts.toml`：`server = "https://192.168.5.221:5000"` + `ca = "/root/ca.crt"`。
- `/etc/containerd/certs.d/docker.io/hosts.toml`：把 docker.io 镜像走私有 registry（`override = true`），
  前提是用 `crane cp --insecure docker.io/<img>@sha256:<digest> 192.168.5.221:5000/<repo>` 按 **digest** 原样复制，
  否则它们的清单里 pin 的 digest 找不到（`crane cp --platform` 会改 digest）。
- macOS 上的坑：Go 在 darwin 忽略 `SSL_CERT_FILE`（`security add-trusted-cert` 需要交互授权），
  所以从 mac 推镜像只能用 `crane --insecure`，或者把构建放到节点上做（Linux 认 `/etc/ssl/certs`）。
