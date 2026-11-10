#!/bin/bash
# POC3 —— 把 Keycloak 配成"唯一 OIDC 提供商"。
#
# 设计上的两条硬要求(决定了为什么这样配):
#  1) 用户、组、租户属性**只来自 LDAP**。这里不手工建用户、不手工赋角色 —— 否则"映射没生效"
#     会被手工配置掩盖掉，POC3 §四要的"隔离假象"就测不出来。
#  2) 每条 claim 的来源都要能追到目录里的一个字段: departmentNumber -> tenant；
#     ou=groups 里的 groupOfNames -> realm_access.roles。
#
# 实测踩坑(都写进结论):
#  - kcadm 用一长串 `-s a=b` 建 LDAP provider 会得到 `Cannot parse the JSON [unknown_error]`(400)，
#    改成 `create -f <json>` 就成功。所以这里的配置是**独立的 JSON 文件**，可读可复验。
#  - `--fields id -c` 会报 "Cannot create CSV nor filter returned fields because the response is
#    compressed"；取 id 要用 `-o -i`(建成功时)或 pretty 输出 + grep(已存在时)。
#  - 26.x 的 UserStorageProvider **没有 syncMode**，只有 importEnabled。属性名一律来自
#    `kcadm get serverinfo`，不是凭记忆写的。
#  - 镜像里**没有** awk/jq/python/curl/tar(kubectl cp 也因此不可用)。
set -uo pipefail
KC=http://keycloak-admin.identity.svc.cluster.local:8080
K=/opt/keycloak/bin/kcadm.sh
REALM=aisanbox
CLIENT=openshell-cli     # 与 OpenShell CLI 的 --oidc-client-id 默认值、chart 的 audience 默认值一致
CFG=/cfg

$K config credentials --server $KC --realm master --user pocadmin --password pocadminpass >/dev/null 2>&1 || { echo "!! 登录失败"; exit 1; }

# create_or_keep <endpoint> <args...> —— 已存在就算成功，并把新建对象的 id 打出来
create_or_keep() {
  local ep=$1; shift
  local out rc
  # ⚠ -o 与 -i 互斥(实测报 "Options -o and -i are mutually exclusive")。取 id 只用 -i。
  out=$($K create "$ep" -r $REALM "$@" -i 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    if echo "$out" | grep -qiE "already exists|Entity exists|unique|exists with same name"; then
      echo "     (已存在)"; return 0
    fi
    echo "     !! $(echo "$out" | tr '\n' ' ' | cut -c1-300)"; return 1
  fi
  echo "     id=$out"
}

# find_id <endpoint> <query> <字段名> <期望值> —— 已存在时取 id(pretty 输出 + grep)
find_id() {
  $K get "$1" -r $REALM -q "$2" 2>/dev/null | grep -m1 '"id"' | sed 's/.*"id" : "//;s/".*//'
}

echo "=== 1) realm ==="
# ⚠ 实测坑: `delete realms/x` 是**异步级联**的 —— 命令返回后，CLIENT/CLIENT_SCOPE 等行还在删。
#   如果紧接着重建同名 realm，会撞唯一索引(HH 23505: UK_CLI_SCOPE_INDEX_7 / UK_B71...),
#   于是 client 与 client scope **建不出来**，而 kcadm 只报 "Cannot parse the JSON"。
#   现象是"realm 在、里面是空的"，很容易被读成"配置写错了"。所以这里先等它真的消失。
if $K get realms/$REALM >/dev/null 2>&1; then
  echo "     realm 已存在，等它处于稳定状态"
else
  for i in $(seq 1 60); do
    $K get realms/$REALM >/dev/null 2>&1 || break
    echo "     上一次删除还没级联完成($i)"; sleep 5
  done
fi
# ⚠ 实测: realm 上**没有** `protocol` 这个属性(那是 client / client-scope 的)。带上它，
#   kcadm 报的是 **"unable to read contents from stream"** —— 听起来像 I/O 故障，实际是服务端
#   拒绝了请求体。这类"错误信息与原因无关"的地方只能靠**逐字段二分**定位(我就是这样找到的)，
#   所以这里的 realm JSON 保持最小: 只写确认存在的属性。
$K create realms -f $CFG/00-realm.json >/dev/null 2>&1 || echo "     (已存在或创建失败 —— 见上面)"
RID=$($K get realms/$REALM 2>/dev/null | grep -m1 '"id"' | sed 's/.*"id" : "//;s/".*//')
echo "     realm_id=$RID"

echo "=== 2) client: $CLIENT ==="
# ⚠ 这里**必须** update，不能只 create。原因与 §3 的 mapper 完全一样:
#   只 create 的话，改了配置文件里的 attributes 对**已存在**的 client 无效(第二次跑只会"已存在")。
#   2026-11-10 就是靠这条才发现的: `openshell gateway add --oidc-issuer` 走完注册后卡在
#     Device authorization request failed (status 400): {"error":"unauthorized_client",
#      "error_description":"Client is not allowed to initiate OAuth 2.0 Device Authorization Grant.
#                           The flow is disabled for the client."}
#   配置项是 client 属性 `oauth2.device.authorization.grant.enabled` = "true"
#   (写在 10-client.json 的 attributes 里 —— 说明只能写在这里，JSON 里不能带注释)。
#   ⚠ 容易误判: realm 的 .well-known **确实**在 grant_types_supported 里列着 device_code，
#     但那是 **realm** 的能力，**client 级要单独开**。OpenShell CLI 的 OIDC 登录
#     走的正是 device flow(oidc_auth.rs 里的 urn:ietf:params:oauth:grant-type:device_code)，
#     所以这条属于身份链路的必需配置，不是可选项。
create_or_keep clients -f $CFG/10-client.json
CID=$(find_id clients "clientId=$CLIENT" id x)
echo "     CID=$CID"
if [ -n "$CID" ]; then
  # 用同一个文件 update ⇒ "集群里的 client = 配置文件里的 client"是构造出来的。
  # ⚠ `-r $REALM` 不能漏: 漏了 kcadm 会用**凭据里的 realm(master)**，
  #   得到 "Resource not found for url: .../admin/realms/master/clients/<id>" ——
  #   报错听起来像"client 不存在"，实际是打错了 realm。
  UOUT=$($K update "clients/$CID" -r $REALM -f $CFG/10-client.json 2>&1)
  if [ $? -eq 0 ]; then echo "     已按 10-client.json 更新"; else
    echo "     !! update 失败: $(echo "$UOUT" | tr "\n" " " | cut -c1-300)"; fi
  echo -n "     生效的 grant 开关: "
  $K get "clients/$CID" -r $REALM 2>/dev/null | grep -oE "\"oauth2.device.authorization.grant.enabled\" : \"[a-z]+\"" | head -1
  echo -n "     pkce: "
  $K get "clients/$CID" -r $REALM 2>/dev/null | grep -oE "\"pkce.code.challenge.method\" : \"[A-Z0-9]+\"" | head -1
fi

echo "=== 2b) 第二个 client: poc3-other-aud —— 只为 K-05(同一个人、aud 不对) ==="
# 为什么要单独一个 client: 实测 `client_id=openshell-cli&audience=someone-else` **不会**
# 产出 aud=someone-else 的 token —— Keycloak 签出来的 aud 仍是 `openshell-cli`(client 自己的
# audience 优先于请求里的 audience 参数)。于是"用 aud 不对的 token 去撞 apiserver"这条
# 用例**没有输入**，K-05 只能判 FAIL(那不是策略没生效，是探针造不出输入)。
# 正确的做法是换 client: 同一个用户、同一个 issuer、同样的 groups/tenant claim，只有 aud 不同。
# apiserver 侧靠 `--oidc-required-claim=aud=openshell-cli` 拒它(v1.37 **没有** --oidc-audience)。
create_or_keep clients -f $CFG/11-client-other-aud.json
OID=$(find_id clients "clientId=poc3-other-aud" id x)
if [ -n "$OID" ]; then
  $K update "clients/$OID" -r $REALM -f $CFG/11-client-other-aud.json >/dev/null 2>&1 \
    && echo "     已按 11-client-other-aud.json 更新" || echo "     !! update 失败"
  # ⚠ 光建 client 不够: realm 的 **default client scope** `poc3-claims` 里挂着
  #   23-claim-audience(`included.client.audience=openshell-cli`)，它会给**所有** client
  #   的 token 把 aud 改写成 openshell-cli —— 实测这个 client 签出来的 aud 仍是 openshell-cli，
  #   于是 K-05 又变成"没有 aud 不对的 token 可用"。把这个 scope 从它的 default 里摘掉。
  for sc in $($K get "clients/$OID/default-client-scopes" -r $REALM 2>/dev/null \
             | grep '"id" :' | sed 's/.*"id" : "//;s/".*//'); do
    $K delete "clients/$OID/default-client-scopes/$sc" -r $REALM >/dev/null 2>&1
  done
  echo -n "     还挂着的 default scope 数: "
  $K get "clients/$OID/default-client-scopes" -r $REALM 2>/dev/null | grep -c '"id" :'
  # 这里不验 aud: 镜像里没有 curl(实测)，token 的 aud 由 14 号脚本 K-05 现场读 JWT 断言的。
fi

echo "=== 3) client scope: poc3-claims(三条 claim 都挂在它上面，且是 default scope) ==="
# ⚠ 其中 24-claim-sub-from-ldap 是**必须**的一条，不是可选优化。实测:
#   LDAP 联邦用户的 sub 默认是 **Keycloak 本地 id**，它会随导入重新生成 ——
#   同一个人我三次实测拿到 85c4020a… / fdb71a5b… / 4121c1c7… 三个不同的 sub。
#   而 OpenShell 的 `workspace member add --subject <OIDC subject>` 就是按 sub 授权的，
#   K8s 侧 --oidc-username-claim=sub 也一样 —— 默认配置下成员资格会在重新导入后**悄悄失效**。
#   把 sub 映射到 LDAP_ID(=目录里的 entryUUID)之后实测稳定: 删掉本地副本再导入，
#   sub 仍是 3affaeaa-70f6-1041-996a-41648389b70a，与目录里的 entryUUID 逐字相同。
#   ⚠ 这不是配了 uuidLDAPAttribute 就自动生效的: 那个属性只管 Keycloak 内部如何定位条目，
#     **不**改变 token 里的 sub。
create_or_keep client-scopes -f $CFG/20-scope.json
SID=$(find_id client-scopes "name=poc3-claims" id x)
echo "     SID=$SID"
# ⚠ 三条实测坑，合起来决定了这里的写法:
#  (1) 只 create 的话，改了 JSON 里的 claim.name 也不会生效(第二次跑只会"已存在")。
#      "配置文件改了、跑着的没变"正是这套 POC 要避免的失效。
#  (2) `update -f` 会更严格: ProtocolMapperRepresentation **没有** description 字段，
#      带上就报 "Invalid json representation ... Unrecognized field \"description\""。
#      所以说明只能写在 YAML 注释里，不能写进这些 JSON。
#  (3) 取 id 用 `grep -B1`: 服务端 pretty 输出里 `"id"` 正好在 `"name"` 前一行，
#      这比 paste+多字段 grep 稳(我第一版那样写，取到过 null)。
#      ⇒ 结论: 按名字删掉再按配置文件重建 —— 这样"集群里的 = 配置文件里的"是构造出来的，不是假设的。
for m in 21-claim-tenant 22-claim-roles 23-claim-audience 24-claim-sub-from-ldap; do
  nm=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG/$m.json" | head -1)
  [ -z "$nm" ] && { echo "     !! $m 里没有 name 字段"; continue; }
  old=$($K get client-scopes/$SID/protocol-mappers/models -r $REALM 2>/dev/null | \
        grep -B1 "\"name\" : \"$nm\"" | grep '"id"' | head -1 | sed 's/.*"id" : "//;s/".*//')
  if [ -n "$old" ]; then
    $K delete "client-scopes/$SID/protocol-mappers/models/$old" -r $REALM >/dev/null 2>&1 \
      && echo "     $nm: 删除旧实例后按配置文件重建"
  fi
  create_or_keep client-scopes/$SID/protocol-mappers/models -f "$CFG/$m.json"
done

# 允许清单 = 配置文件里声明的 mapper 名。
# ⚠ 必须用 JSON 里的 name 字段，不能用文件名 —— 两者不同(21-claim-tenant 里的 name 是 poc3-tenant)。
KEEP=""
for m in 21-claim-tenant 22-claim-roles 23-claim-audience 24-claim-sub-from-ldap; do
  KEEP="$KEEP $(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG/$m.json" | head -1)"
done
# 清掉不在配置文件里的 poc3-* mapper: 手工实验留下的一条 mapper 会**悄悄多带一条 claim**，
# 而且和配置文件里的 claim 同名时谁生效取决于顺序 —— 这种状态比报错更难查。
# 清掉不在配置文件里的 poc3-* mapper: 手工实验留下的一条会**悄悄多带一条 claim**，
# 同名时谁生效取决于顺序 —— 这种状态比报错更难查。
$K get client-scopes/$SID/protocol-mappers/models -r $REALM 2>/dev/null > /tmp/mappers.json
grep -n '"name" : "poc3-' /tmp/mappers.json | sed 's/:.*"name" : "//;s/".*//' | while read -r nm; do
  keep=no
  for want in $KEEP; do [ "$nm" = "$want" ] && keep=yes; done
  [ "$keep" = yes ] && continue
  # ⚠ 实测坑: 变量展开为空时 `sed -n "" file` 会把**文件名**当成 sed 脚本
  #   (报 "invalid option -- '1'")。任何用行号做 sed 的地方都要先确认行号非空。
  ln=$(grep -n "\"name\" : \"$nm\"" /tmp/mappers.json | head -1 | cut -d: -f1)
  [ -z "$ln" ] && continue
  mid=$(sed -n "$((ln-1))p" /tmp/mappers.json | sed 's/.*"id" : "//;s/".*//')
  if [ -n "$mid" ]; then
    $K delete "client-scopes/$SID/protocol-mappers/models/$mid" -r $REALM >/dev/null 2>&1 \
      && echo "     清掉不在配置文件里的 mapper: $nm"
  fi
done

$K create clients/$CID/default-client-scopes -r $REALM -s id=$SID >/dev/null 2>&1 \
  && echo "     已挂为 default scope" || echo "     (default scope 已挂过)"

echo "=== 4) LDAP 联邦 + 两条映射(用户/组/租户没有一条是手工建的) ==="
# ⚠ 两条实测坑:
#  (a) 组件**没有** components/<id>/mappers 这个子资源(实测 Resource not found)。LDAP mapper 与
#      storage provider 一样都是 component，只是 parentId 指向 provider —— 所以用
#      `create components -f <json> -s parentId=$PID`。
#  (b) 组件**不像 client 那样按名字唯一**，重复 create 会**再多建一个**同名 provider(我第一次就踩了，
#      得到两条 ldap-poc3)。所以这里**先查后建**，而不是"建失败当作已存在"。
ensure_component() {   # ensure_component <json 文件> [parentId]
  local f=$1 pid=${2:-} nm
  # ⚠ 这里的正则必须**同时**容忍 `"name": "x"`(我们自己的 JSON)和 `"name" : "x"`(kcadm 的输出)。
  #   我第一版只匹配了带空格的那种，于是 nm 为空 -> -q name= 返回**所有**组件 -> 取到第一个内置组件的 id，
  #   LDAP mapper 就被挂到了错误的 parentId 上，而且**不报错**。
  nm=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
  [ -z "$nm" ] && { echo "     !! 读不出 $f 里的 name，拒绝继续(否则会挂错父组件)" >&2; return 1; }
  local exist
  exist=$($K get components -r $REALM -q "name=$nm" 2>/dev/null | grep -m1 '"id"' | sed 's/.*"id" : "//;s/".*//')
  # ⚠ 实测坑: 这个函数**只能**往 stdout 打 id。第一版把 "已存在 id=…" 也打到 stdout，
  #   调用方 `PID=$(ensure_component …)` 就把日志和 id 一起吞进变量；再 `-s parentId=$PID`
  #   时按空格切开，实际传出去的是 `parentId=ldap-poc3`(名字，不是 id) —— 不报错，
  #   只是 mapper 挂到了一个不存在的父组件上，于是 claim 永远是空的。人看的输出走 stderr。
  if [ -n "$exist" ]; then echo "     $nm 已存在 id=$exist" >&2; printf '%s' "$exist"; return 0; fi
  local out
  if [ -n "$pid" ]; then out=$($K create components -r $REALM -f "$f" -s parentId=$pid -i 2>&1)
  else out=$($K create components -r $REALM -f "$f" -i 2>&1); fi
  if [ $? -ne 0 ]; then echo "     !! $nm: $(echo "$out" | tr '\n' ' ' | cut -c1-300)" >&2; return 1; fi
  echo "     $nm id=$out" >&2
  printf '%s' "$out"
}
PID=$(ensure_component $CFG/30-ldap.json)
[ -z "$PID" ] && { echo "!! 没有 provider，后面都建不了"; exit 1; }
for m in 31-ldap-attr-tenant 32-ldap-roles-from-dir; do
  ensure_component $CFG/$m.json $PID >/dev/null
done

echo "=== 4b) 清掉**陈旧**的本地用户副本(改了映射却看不到变化的常见原因) ==="
# 实测坑: 用户一旦被导入到本地，改 LDAP mapper **不会**自动回填已导入的用户；
# 而删掉 storage provider 也不会删本地用户，只会把 federationLink 变陈旧。
# 结果就是"明明配对了，claim 还是空的"。判定条件用 federationLink != 当前 provider，
# 而不是"用户存在" —— 后者会把正常情况也删掉。
for u in alice tadmin bob; do
  UID_=$($K get users -r $REALM -q "search=$u" 2>/dev/null | grep -m1 '"id"' | sed 's/.*"id" : "//;s/".*//')
  [ -z "$UID_" ] && continue
  FL=$($K get users/$UID_ -r $REALM --fields federationLink 2>/dev/null | grep -oE '"federationLink" : "[^"]*"' | sed 's/.*: "//;s/"//')
  if [ "$FL" != "$PID" ]; then
    echo "     $u: federationLink=${FL:-无} != 当前 provider -> 删除本地副本，重新导入"
    $K delete users/$UID_ -r $REALM 2>&1 | head -1
  fi
done

echo "=== 5) 触发同步 ==="
# ⚠ 实测: components/<id>/action 这个端点**不存在**(Resource not found)，26.x 的 action 走
#   components/<id>/config/action(POST)。这里不去猜 URL —— 直接用第 6 步的检索触发惰性导入，
#   它本身就是 POC3 要观察的路径(首次登录才导入)，更贴近真实失效形态。
echo "     不显式触发同步: 下面的检索会触发惰性导入(importEnabled=true)"

echo "=== 6) 校验: 联邦是否真的把目录里的用户带进来了 ==="
# ⚠ 这里**只**校验"用户经联邦存在 + 挂了几条 mapper"。租户/角色 claim 的最终判定是
#   **解码一张真实 token**(poc/phases/14 在宿主上做):
#     - tenant 属性配了 always.read.value.from.ldap=true，它**不会**出现在 user representation 的
#       attributes 里 —— 用那个字段判断"映射没生效"会得到假的失败;
#     - 目录来源的角色也不以本地 realm 角色的形式存在，`--fields realmMappings` 同样看不见。
#   两次假失败我都踩过，所以把判据写在这里。
for u in alice tadmin bob; do
  UID_=$($K get users -r $REALM -q "search=$u" 2>/dev/null | grep -m1 '"id"' | sed 's/.*"id" : "//;s/".*//')
  [ -z "$UID_" ] && { echo "     $u: !! 目录里有、Keycloak 里没有 —— 联邦没生效"; continue; }
  echo "     $u: id=$UID_"
  echo "        federationLink=$(echo "$($K get users/$UID_ -r $REALM --fields federationLink 2>&1)" | tr -d ' \n' | cut -c1-80)"
  # LDAP_ID 是 entryUUID 的映射 —— 这就是"sub 有稳定来源"的证据(POC3 结论里的一条)
  echo "        LDAP_ID=$(echo "$($K get users/$UID_ -r $REALM --fields attributes 2>&1)" | tr -d '\n' | grep -oE '"LDAP_ID" : \[[^]]*\]' | head -1)"
done
echo "=== 7) mapper 是否挂在正确的 provider 下(parentId 必须是 provider 的 id) ==="
$K get components -r aisanbox 2>/dev/null | grep -E "^  \"(name|parentId)\"" | paste - - | \
  grep -E "tenant-attr|dir-roles" | sed 's/^ *//' | sed 's/\"//g' | sed 's/^/     /'
echo "=== 完成 ==="
