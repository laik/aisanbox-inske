#!/usr/bin/env python3
"""从**源文件**生成 poc/identity/30-keycloak-realm.yaml。

为什么要有这个脚本(而不是直接编辑那个 YAML): 30 号文件里的 ConfigMap 是把
realm-script.sh 和 keycloak/*.json **嵌进去**的。直接编辑 30 号就会出现
"改了 JSON、ConfigMap 还是旧的" —— 我 2026-11-10 就是这么踩的(去掉 description
之后跑出来的 ConfigMap 仍带着它，于是 sub 映射没建成，token 里 sub 又变回本地 id)。
所以这个 YAML 是**产物**，不手改；改源文件后跑这个脚本，再 kubectl apply。
14 号脚本会用 sha256 对照集群里的 ConfigMap 与这个产物，不一致就报出来。
"""
import glob, hashlib, io, os, sys

root = os.path.dirname(os.path.abspath(__file__))
script = io.open(os.path.join(root, "realm-script.sh"), encoding="utf-8").read().rstrip("\n")
files = sorted(glob.glob(os.path.join(root, "keycloak", "*.json")))
if not files:
    sys.exit("找不到 keycloak/*.json")

HEAD = '''# 产物，别手改 —— 由 `python3 poc/identity/build-realm-configmap.py` 从
#   poc/identity/realm-script.sh + poc/identity/keycloak/*.json 生成。
# 为什么 Keycloak 配置要这样放(四条都是实测，详细见 realm-script.sh 顶部注释):
#  - Keycloak 用的是容器可写层里的 dev-file 库，Pod 重建 = realm 配置没了 ⇒ 必须可重放。
#  - 一长串 kcadm `-s key=value` 建 LDAP provider 会得到 `Cannot parse the JSON [unknown_error]`，
#    只有 `create -f <json>` 可行。
#  - component 的 config 值必须是**数组**；protocol-mapper 的 config 是**普通字符串**；
#    两种端点形状不同，写错都只报同一句话。
#  - ProtocolMapperRepresentation / ComponentRepresentation **没有** description 字段 ⇒
#    说明写在 .py 与本文件注释里，不塞进 JSON。
apiVersion: v1
kind: ConfigMap
metadata:
  name: kc-realm-config
  namespace: identity
  labels: {app.kubernetes.io/part-of: aisanbox-poc3}
data:
  realm-script.sh: |
'''

TAIL = '''---
apiVersion: batch/v1
kind: Job
metadata:
  name: kc-realm
  namespace: identity
  labels: {app.kubernetes.io/part-of: aisanbox-poc3}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata: {labels: {app.kubernetes.io/part-of: aisanbox-poc3}}
    spec:
      restartPolicy: OnFailure
      containers:
        - name: kcadm
          image: quay.io/keycloak/keycloak:26.4     # 只为拿里面的 kcadm.sh
          command: ["/bin/bash", "/cfg/realm-script.sh"]
          volumeMounts: [{name: cfg, mountPath: /cfg, readOnly: true}]
          resources:
            requests: {cpu: 50m, memory: 128Mi}
            limits: {cpu: "1", memory: 512Mi}
      volumes:
        - name: cfg
          configMap: {name: kc-realm-config}
'''

def block(text, indent):
    pad = " " * indent
    return "\n".join((pad + l) if l.strip() else "" for l in text.split("\n"))

out = io.StringIO()
out.write(HEAD)
out.write(block(script, 4) + "\n")
sources = [("realm-script.sh", os.path.join(root, "realm-script.sh"))]
for f in files:
    key = os.path.basename(f)
    out.write("  %s: |\n" % key)
    out.write(block(io.open(f, encoding="utf-8").read().rstrip("\n"), 4) + "\n")
    sources.append((key, f))
out.write(TAIL)
dst = os.path.join(root, "30-keycloak-realm.yaml")
io.open(dst, "w", encoding="utf-8").write(out.getvalue())

# 同时把源文件哈希写在一个 sidecar 里，方便 14 号脚本核对"集群里的 = 源文件"
h = hashlib.sha256()
for key, f in sources:
    h.update(key.encode())
    h.update(io.open(f, "rb").read())
io.open(os.path.join(root, "BUILD-HASH"), "w", encoding="utf-8").write(h.hexdigest() + "\n")
print("wrote %s (%d bytes) from %d source files" % (dst, os.path.getsize(dst), len(sources)))
print("source sha256:", h.hexdigest())
