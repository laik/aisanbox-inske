#!/usr/bin/env bash
# POC3 §二 —— 给 kube-apiserver 打开 OIDC 认证。
#
# 三条实测前提(决定了这里的做法，不是照抄文档):
#  1) issuer 必须是 **HTTPS**。apiserver 的 --oidc-issuer-url 只接受 https scheme，
#     所以 Keycloak 前面必须有 TLS 终止(见 20-keycloak.yaml 里的 nginx sidecar)。
#  2) issuer **不能用集群内 DNS**。kind 节点的 /etc/resolv.conf 里没有集群 DNS，
#     所以 issuer 用"节点 IP + NodePort"，并且证书 SAN 里必须含那个 IP。
#  3) --oidc-ca-file 要放在 apiserver **已经挂载**的目录里: 静态 Pod 已经把节点的
#     /etc/kubernetes/pki 挂进容器(readOnly)，所以不需要改 manifest 加 volume。
#     实测依据(取自 apiserver Pod 的 spec): volume `k8s-certs` = hostPath /etc/kubernetes/pki。
#
# 两个必须写下来的代价:
#  - 改静态 Pod manifest 会**重启 apiserver**(实测约 20~40s 控制面不可用)。POC2 的沙箱数据面不受影响
#    (不经过 apiserver)，但 kubectl 会短暂报错 —— 脚本末尾确认控制面恢复。
#  - kind 集群**重建**后这些 flag 就没了(manifest 由 kubeadm 建集群时生成)。所以这里同时把
#    OIDC 配置写进 kubeadm-config 的 ClusterConfiguration.authentication.oidc，让"集群该怎么配"有单一来源。
#
# ⚠ 有意让 kubeadm-config 与运行时 flag **写同一套值**(包括 required-claim) —— 否则"文档里的配置"
#   和"跑着的配置"不一致，正是这套 POC 一直在批评的那种失效。用 REQUIRE_AUD=no 可以关掉两边做对照。
#
# 幂等: 已加过 flag 就只更新值；值没变就不重启。
set -uo pipefail
CTX=${CTX:-kind-agent-runtime-poc}
NODE=${NODE:-agent-runtime-poc-control-plane}
REALM=${REALM:-aisanbox}
ISSUER=${ISSUER:-https://172.22.0.3:31443/realms/$REALM}
CLIENT_ID=${CLIENT_ID:-openshell-cli}
# ⚠ 路径要相对**脚本自身**，不是 cwd。我第一版写成 `poc/identity/certs/...`，在 /root/poc2 下跑
#   就找不到文件；`cat < 不存在的文件` 让节点上落了一个**空** CA，apiserver 起不来
#   ("Could not open file or uri for loading certificate") —— 报错很清楚，但根因在十几步之前。
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CA_SRC=${CA_SRC:-$HERE/certs/issuer-ca.crt}
REQUIRE_AUD=${REQUIRE_AUD:-yes}   # yes = 加 --oidc-required-claim=aud=<CLIENT_ID>
# ⚠ 实测(2026-11-10，本机 v1.37): --oidc-groups-claim **只能读顶层 claim**。
#   配成 "realm_access.roles" 时，token 里明明有 realm_access.roles，
#   `kubectl auth whoami` 却只看到 Groups=[system:authenticated] —— 不报错、不告警，
#   结果是"认证成功了但组是空的"，RBAC 全部落到 no。
#   所以这里默认用**顶层** claim 名(groups)。Keycloak 侧对应加一条 claim.name=groups 的
#   mapper(见 keycloak/25-claim-groups-toplevel.json)，而不是把 realm_access.roles 改名。
GROUPS_CLAIM=${GROUPS_CLAIM:-groups}

MAN=/etc/kubernetes/manifests/kube-apiserver.yaml

echo "   issuer=$ISSUER"
echo "   client-id=$CLIENT_ID  require-aud=$REQUIRE_AUD"

# 1) CA 送进节点的 pki 目录。
#    ⚠ 不要用 docker cp 到 /tmp: kind 节点的 /tmp 是 tmpfs，cp "成功"但 exec 看不到
#      (poc/kind/fix-apiserver-sans.sh 里同一条坑)。用 stdin 写最稳，
#      而且 /etc/kubernetes/pki 本来就是 apiserver 挂载的 hostPath。
if [ ! -s "$CA_SRC" ]; then echo "   ✗ CA 文件不存在或为空: $CA_SRC"; exit 1; fi
docker exec -i "$NODE" bash -c 'cat > /etc/kubernetes/pki/oidc-issuer-ca.crt' < "$CA_SRC"
docker exec "$NODE" bash -ec 'openssl x509 -in /etc/kubernetes/pki/oidc-issuer-ca.crt -noout -subject' | sed 's/^/     CA: /'

# 2) 先留回滚点，**再**改 manifest(顺序错了就没有回滚点了 —— 我第一版就是这个 bug)
docker exec "$NODE" bash -ec "[ -f /tmp/kube-apiserver.yaml.bak ] || cp $MAN /tmp/kube-apiserver.yaml.bak" \
  && echo "   回滚点: $NODE:/tmp/kube-apiserver.yaml.bak"

docker exec "$NODE" bash -ec "cat $MAN" > /tmp/kas-in.yaml
ISSUER="$ISSUER" CLIENT_ID="$CLIENT_ID" REQUIRE_AUD="$REQUIRE_AUD" GROUPS_CLAIM="$GROUPS_CLAIM" python3 - <<'PY'
import os, yaml
issuer = os.environ["ISSUER"]; client_id = os.environ["CLIENT_ID"]
want = {
    "--oidc-issuer-url": issuer,
    "--oidc-client-id": client_id,
    # 只给 issuer 的 CA，不给集群自带 CA: 这个文件只签 issuer 一个证书，信任范围最小。
    "--oidc-ca-file": "/etc/kubernetes/pki/oidc-issuer-ca.crt",
    # username-claim=sub: **故意**用 sub。preferred_username 更好读，但 K8s 文档明确写了
    # 非 sub 的 claim "不保证唯一"；而 OpenShell 侧就是按 subject 授权的 —— 两侧用同一个
    # 标识才是这套验证要证的东西(可读性代价见结论)。
    "--oidc-username-claim": "sub",
    # 组名**不加前缀**: RBAC 里直接写目录里的组名(tenant-a-users 等)。默认前缀是
    # oidc:groups:；不加是让"RBAC 与目录同名"可读，代价见结论。
    "--oidc-groups-claim": os.environ.get("GROUPS_CLAIM", "realm_access.roles"),
    # ⚠ 实测(--help，取自 v1.37 容器里的二进制): **不给** --oidc-username-prefix 时，
    #   "username claims other than 'email' are prefixed by the issuer URL" —— 也就是
    #   username 会变成 "https://172.22.0.3:31443/realms/aisanbox#<sub>"。
    #   那样 RBAC 里的 subject 长得跟 OpenShell 侧的 subject 完全不一样，POC3 §四要的
    #   "同一用户在两侧标识一致"就没法直接对照。所以这里显式写 "-"(文档: 给 "-" 就完全不加前缀)。
    #   代价必须写下来: 去掉前缀就丢掉了"避免与其他认证方式撞名"的保护。这个 POC 里 sub 是
    #   Keycloak 生成的 UUID，不可能与客户端证书的 CN 撞名；生产上要么保留前缀，要么在 RBAC
    #   里用 Group 而不是 User(见结论)。
    "--oidc-username-prefix": "-",
    # 组名**不加前缀**: 实测 --oidc-groups-prefix 不传就是不加前缀(help 里没有任何默认前缀)，
    # 所以 RBAC 里可以直接写目录里的组名(tenant-a-users 等)。这正是"同一份目录数据两侧通用"的关键。
    # 算法钉死，不给 alg=none 或意外算法通过的机会。
    "--oidc-signing-algs": "RS256",
}
if os.environ.get("REQUIRE_AUD", "yes") == "yes":
    # ⚠ 这条是**补架构约束里的洞**: 实测 kube-apiserver v1.37 的 --help 里**没有** --oidc-audience
    #   (在容器里枚举过全部 --oidc-* flag)，而 OpenShell 的 chart **会**校验 aud。
    #   也就是说同一张 token，"aud 对不对"只有一侧在管。用 required-claim 把另一侧补齐，
    #   14 号脚本实测它确实会拒 aud 不对的 token。
    want["--oidc-required-claim"] = "aud=%s" % client_id

doc = yaml.safe_load(open("/tmp/kas-in.yaml"))
cmd = doc["spec"]["containers"][0]["command"]
out, seen, changed = [], set(), False
for a in cmd:
    k = a.split("=", 1)[0]
    if k in want:
        new = "%s=%s" % (k, want[k])
        if a != new:
            changed = True
        out.append(new); seen.add(k)
    elif a.startswith("--oidc-required-claim") and "--oidc-required-claim" not in want:
        changed = True          # 关掉对照时要把旧的删掉
    else:
        out.append(a)
for k, v in want.items():
    if k not in seen:
        out.append("%s=%s" % (k, v)); changed = True
doc["spec"]["containers"][0]["command"] = out
yaml.safe_dump(doc, open("/tmp/kas-out.yaml", "w"))
open("/tmp/kas-changed", "w").write("1" if changed else "0")
PY

if [ "$(cat /tmp/kas-changed)" = "1" ]; then
  docker exec -i "$NODE" bash -c "cat > $MAN.new && rm -f $MAN.new.old && mv $MAN.new $MAN" < /tmp/kas-out.yaml
  echo "   已更新 manifest，等 apiserver 重启…"
  for i in $(seq 1 90); do kubectl --context $CTX get --raw=/readyz >/dev/null 2>&1 && break; sleep 2; done
  if kubectl --context $CTX get --raw=/readyz >/dev/null 2>&1; then
    echo "   readyz: ok (等了约 $((i*2))s)"
  else
    echo "   ✗ apiserver 没回来。回滚:"
    echo "       docker exec $NODE bash -ec 'cp /tmp/kube-apiserver.yaml.bak $MAN'"
    exit 1
  fi
else
  echo "   manifest 已是目标状态，不重启"
fi

# 3) 同一套值写进 kubeadm 的 ClusterConfiguration(单一来源)
kubectl --context $CTX -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /tmp/cc-in.yaml
CLIENT_ID="$CLIENT_ID" ISSUER="$ISSUER" REQUIRE_AUD="$REQUIRE_AUD" GROUPS_CLAIM="$GROUPS_CLAIM" python3 - <<'PY'
import os, yaml
cc = yaml.safe_load(open("/tmp/cc-in.yaml"))
oidc = {
    "issuerURL": os.environ["ISSUER"],
    "clientID": os.environ["CLIENT_ID"],
    "CAFile": "/etc/kubernetes/pki/oidc-issuer-ca.crt",
    "usernameClaim": "sub",
    "usernamePrefix": "-",
    "groupsClaim": os.environ["GROUPS_CLAIM"],
}
if os.environ.get("REQUIRE_AUD", "yes") == "yes":
    oidc["requiredClaims"] = {"aud": os.environ["CLIENT_ID"]}
cc.setdefault("authentication", {})["oidc"] = oidc
open("/tmp/cc-out.yaml", "w").write(yaml.safe_dump(cc, sort_keys=False))
PY
kubectl --context $CTX -n kube-system get cm kubeadm-config -o yaml > /tmp/cm-raw.yaml
python3 - <<'PY'
import yaml
raw = yaml.safe_load(open("/tmp/cm-raw.yaml"))
raw["data"]["ClusterConfiguration"] = open("/tmp/cc-out.yaml").read()
out = {"apiVersion": "v1", "kind": "ConfigMap",
       "metadata": {"name": "kubeadm-config", "namespace": "kube-system"},
       "data": raw["data"]}
yaml.safe_dump(out, open("/tmp/cm-out.yaml", "w"))
PY
kubectl --context $CTX apply -f /tmp/cm-out.yaml | sed 's/^/     /'

echo "   运行时生效的 OIDC flag:"
docker exec "$NODE" bash -ec "grep -o '\-\-oidc-[a-z-]*=[^\" ]*' $MAN" | sed 's/^/     /'
echo "   kubeadm-config 里的 OIDC 配置(应与上面一致):"
kubectl --context $CTX -n kube-system get cm kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' | sed -n '/^  oidc:/,/^  [a-z]/p' | sed 's/^/     /'
