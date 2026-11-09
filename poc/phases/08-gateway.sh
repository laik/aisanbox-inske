#!/usr/bin/env bash
# Phase 3 —— 每租户独立 OpenShell Gateway (POC2 §4.1–§4.4)
# 手工重现: bash poc/phases/08-gateway.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
OS_VERSION=${OS_VERSION:-0.1.7}
# CLI 必须与 gateway **同版本**(0.1.7)。它不在 ghcr 上(nvidia/openshell/cli 无 token)，
# 只能从 release asset 取 —— 用 scripts/gh-fetch.sh(见该文件的说明)。
CLI=vendor/openshell-cli-0.1.7/openshell
bash scripts/gh-fetch.sh NVIDIA/OpenShell v0.1.7 openshell-x86_64-unknown-linux-musl.tar.gz \
  openshell-cli-0.1.7.tar.gz >/dev/null
[ -x "$CLI" ] || { mkdir -p vendor/openshell-cli-0.1.7; tar xzf vendor/openshell-cli-0.1.7.tar.gz -C vendor/openshell-cli-0.1.7; }
chmod +x "$CLI"
echo "### CLI 版本(要和 chart/gateway 一致):"; "$CLI" --version 2>&1 | head -1 | sed 's/^/   /'
# CLI 找证书的目录是固定的(见下面 mtls 注释)，这里只保证它存在。
mkdir -p "$HOME/.config/openshell/gateways"

install_gateway() { # install_gateway <tenant>
  local t=$1
  helm --kube-context $CTX upgrade --install "os-$t" oci://ghcr.io/nvidia/openshell/helm-chart \
    --version "$OS_VERSION" --namespace "tenant-$t-gateway" \
    -f openshell2/gateway-values.yaml \
    --set server.name="tenant-$t-gateway" \
    --set server.otlp.serviceName="tenant-$t-gateway" \
    --set server.sandboxNamespace="tenant-$t-runtime" \
    --timeout 6m --wait
}

# ---------------------------------------------------------------------------
# 顺序是**硬要求**(实测): 先装 gateway、后装 workspace chart 的话，gateway 会
# CrashLoopBackOff，日志是
#   sandboxes.agents.x-k8s.io is forbidden: User
#   "system:serviceaccount:tenant-a-gateway:os-a-openshell" cannot list ...
#   in the namespace "tenant-a-runtime"
# 因为**租户 runtime ns 里的 Role 是 workspace chart 装的**。POC2 §4.2/§4.3 按
# "先 gateway 再 workspace" 写，实际必须先 workspace(或至少让 RBAC 先到位)。
# workspace chart 的 values 只写**一处**。原因见下面 1b 的实测坑:
# 同一个 release 跑两次 `helm upgrade --install`，第二次只给**部分** --set，
# 其余值会**回到 chart 默认**(helm 默认不 reuse-values)，而且不报错。
# 实测后果: sandboxServiceAccount.name 从 os-a-openshell-sandbox 退回默认 openshell-sandbox，
# 而 gateway 的 service_account_name 仍是 os-a-openshell-sandbox —— 于是**几阶段之后**
# 建 sandbox 才炸，报错在别的产品里:
#   Error: create sandbox failed: ApiError: pods "os-supervisor-…" is forbidden:
#          error looking up service account tenant-a-runtime/os-a-openshell-sandbox
install_workspace() { # install_workspace <tenant>
  local t=$1
  helm --kube-context $CTX upgrade --install "os-ws-$t" oci://ghcr.io/nvidia/openshell/openshell-workspace \
    --version "$OS_VERSION" --namespace "tenant-$t-runtime" \
    --set gateway.serviceAccount.name="os-$t-openshell" \
    --set gateway.serviceAccount.namespace="tenant-$t-gateway" \
    --set gateway.allowDriverConfig=true \
    --set sandboxServiceAccount.name="os-$t-openshell-sandbox" \
    --set networkPolicy.podSelector."app\\.kubernetes\\.io/instance"="os-$t" \
    --timeout 3m --wait >/dev/null
}

# ---------------------------------------------------------------------------
echo "### 1. 每个租户 runtime ns 的 workspace 前置(POC2 §4.3) —— 必须先装"
for t in a b; do install_workspace "$t"; done
echo "   装出来的 RBAC / NetworkPolicy:"
kubectl --context $CTX -n tenant-a-runtime get sa,role,rolebinding,netpol --no-headers 2>/dev/null | grep openshell-workspace | awk '{print "   "$1}'
echo "   gateway SA 在租户 ns 里能 list sandboxes 吗:"
kubectl --context $CTX auth can-i list sandboxes.agents.x-k8s.io -n tenant-a-runtime \
  --as=system:serviceaccount:tenant-a-gateway:os-a-openshell | sed 's/^/     /'
echo "   ⚠ gateway.serviceAccount.name 必须是**实际渲染出来的** gateway SA 名(带 release 前缀"
echo "     os-a-openshell)。照抄文档里的 openshell 会静默绑错，然后 RBAC 看起来"
echo "     "装了但没生效"。这是本轮最容易踩的一个坑。"

# ---------------------------------------------------------------------------
# 实测发现(shared 模式的一个必要平台步骤，POC2 §4.3 没有写):
# supervisor Pod 要挂载 **名字固定**的 client-TLS Secret 来验证 gateway 证书。
# v0.1.7 的驱动按 workspace_mode 决定从哪儿取它
# (crates/openshell-driver-kubernetes/src/config.rs):
#     if client_tls_secret_name.is_empty() -> Disabled
#     else if is_multi_namespace()         -> Bootstrap  # 驱动自己把 CA 塞进每次生成的 bootstrap Secret
#     else                                 -> Secret(name)  # **按名字挂 sandbox ns 里的 Secret**
# `is_multi_namespace()` 对 shared 模式是 false —— 所以 **shared 模式下这个 Secret 必须
# 存在于租户 runtime ns**。没有它 supervisor 卡在 ContainerCreating:
#   MountVolume.SetUp failed for volume "client-tls" : secret "openshell-client-tls" not found
# 而 sandbox Pod 本身已经 Running，所以现象是"沙箱起来了但 agent 连不上边界"——
# 很容易误判成网络问题。上一轮用 operator 模式不会遇到(走 Bootstrap 分支)。
# 做法: 开通流程把 gateway 的 client bundle 复制到该租户 runtime ns(名字保持 chart 默认)。
# ---------------------------------------------------------------------------
echo "### 1c. shared 模式需要: 把 client-TLS bundle 落到租户 runtime ns"
for t in a b; do
  kubectl --context $CTX -n "tenant-$t-runtime" get secret openshell-client-tls >/dev/null 2>&1 \
    && { echo "   tenant-$t 已有"; continue; }
  kubectl --context $CTX -n "tenant-$t-gateway" get secret openshell-client-tls -o yaml \
    | python3 -c "
import sys,yaml,json
o=yaml.safe_load(sys.stdin)
out={'apiVersion':'v1','kind':'Secret','metadata':{'name':'openshell-client-tls',
     'namespace':'tenant-$t-runtime'},'type':o['type'],'data':o['data']}
print(json.dumps(out))
" | kubectl --context $CTX apply -f - >/dev/null
  echo "   tenant-$t 已复制到 tenant-$t-runtime"
done
echo "   ⚠ 这是**平台**的责任，不是租户的: 证书归 gateway，ns 归租户。生产上应该由"
echo "     gateway 的部署流程/控制器保持这份副本与源同步(certgen 轮转时要跟着更新)。"

echo
echo "### 2. 两个租户各装一个 Gateway(POC-01)"
for t in a b; do
  if ! install_gateway "$t" >/dev/null; then
    echo "   ✗ tenant-$t gateway 安装失败"; exit 1
  fi
done
kubectl --context $CTX get pods -A -l app.kubernetes.io/name=openshell --no-headers \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.containerStatuses[0].ready | sed 's/^/   /'

echo
echo "### 1b. workspace chart 装了哪些前置资源(核对 POC2 §4.3 的描述)"
for t in a b; do install_workspace "$t"; done
echo "   一致性断言: gateway.toml 里的 service_account_name 必须 == runtime ns 里真实存在的 SA"
for t in a b; do
  sa=$(kubectl --context $CTX -n "tenant-$t-gateway" get cm -l app.kubernetes.io/name=openshell \
        -o 'jsonpath={.items[0].data.gateway\.toml}' | awk -F'"' '/service_account_name/{print $2}')
  printf "   %-8s gateway 要求 SA=%-28s " "tenant-$t" "$sa"
  kubectl --context $CTX -n "tenant-$t-runtime" get sa "$sa" >/dev/null 2>&1 \
    && echo "存在 ✓" || echo "不存在 ✗ <== 就是这个让 sandbox 建不出来"
done
echo "   装出来的东西:"
kubectl --context $CTX -n tenant-a-runtime get sa,role,rolebinding,netpol -l app.kubernetes.io/name=openshell-workspace --no-headers 2>/dev/null | awk '{print "   "$1}' | head -8
echo "   ⚠ POC2 §4.3 说 workspace chart 负责 SA/Role/RoleBinding/NetworkPolicy —— 实测确认无误。"
echo "     注意 gateway.serviceAccount.name 必须是**实际部署出来的** gateway SA 名"
echo "     (这里带 release 前缀 os-a-openshell)，照抄文档里的 openshell 会绑错。"

echo
echo "### 3. CLI 用 mTLS 连两个 gateway(POC-01: 租户拥有独立管理状态)"
# 端口必须是数字: 早期写成 1844$t(t=a)会生成非法端口 "1844a"，表现是 CLI 连不上，
# 很容易被误判成 gateway 没起来。
pkill -f "port-forward svc/os-" >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 >/tmp/pf-a.log 2>&1 &
kubectl --context $CTX -n tenant-b-gateway port-forward svc/os-b-openshell 18442:8080 >/tmp/pf-b.log 2>&1 &
sleep 4
# 客户端证书就在 gateway ns 的 openshell-client-tls 里(Secret 有 ca.crt/tls.crt/tls.key)。
# CLI 找的是 ~/.config/openshell/gateways/<name>/mtls/{ca.crt,tls.crt,tls.key}
# —— 少 ca.crt 或放错目录，`gateway add --local` 会说 "mTLS certificates were not found"，
# 而这个报错读起来像证书坏了。实测踩过，按这个路径放。
for t in a b; do
  d="$HOME/.config/openshell/gateways/poc2-$t/mtls"
  mkdir -p "$d"
  # Secret 的 key 里有 . ，jsonpath 必须转义成 tls\.crt —— 直接在 shell 里拼很容易
  # 拼错，结果就是写出 0 字节的证书文件(报错变成"no private key found in TLS key PEM")。
  for k in "ca.crt:ca\.crt" "tls.crt:tls\.crt" "tls.key:tls\.key"; do
    out=${k%%:*}; jp=${k#*:}
    kubectl --context $CTX -n "tenant-$t-gateway" get secret openshell-client-tls -o "jsonpath={.data.$jp}" | base64 -d > "$d/$out"
    [ -s "$d/$out" ] || echo "     ✗ $d/$out 是空的 —— jsonpath 转义写错了"
  done
  $CLI gateway add "https://127.0.0.1:1844$( [ "$t" = a ] && echo 1 || echo 2 )" --name "poc2-$t" --local 2>&1 | grep -E "added|✓|Error" | head -2 | sed "s/^/     /"
done
OSCLI_A() { $CLI -g poc2-a "$@"; }
OSCLI_B() { $CLI -g poc2-b "$@"; }
echo "   两边都连上并且各自独立认证:"
OSCLI_A status 2>&1 | grep -E "Status:|Authentication:|Version:" | sed 's/^/     A /'
OSCLI_B status 2>&1 | grep -E "Status:|Authentication:|Version:" | sed 's/^/     B /'

echo "### 4. 状态隔离证据: 两个 gateway 各自一套状态，互不可见"
echo "   各自创建同名 workspace + sandbox，看对方是否看得到:"
OSCLI_A workspace create --name poc-shared 2>&1 | grep -iE "created|Error" | head -1 | sed 's/^/   A workspace: /'
OSCLI_B workspace create --name poc-shared 2>&1 | grep -iE "created|Error" | head -1 | sed 's/^/   B workspace: /'
sleep 2
echo "   两边都各自有同名 workspace —— 名字不冲突，因为状态本来就不共享:"
OSCLI_A workspace list 2>&1 | grep -iE "poc-shared|WORKSPACE" | head -3 | sed 's/^/   A 侧: /'
OSCLI_B workspace list 2>&1 | grep -iE "poc-shared|WORKSPACE" | head -3 | sed 's/^/   B 侧: /'
echo "   各自的 gateway_id / 自己的 SQLite PVC(状态存储独立):"
kubectl --context $CTX get pvc -A 2>/dev/null | grep openshell-data | awk '{print "     "$1" "$2" "$3}'
for t in a b; do
  kubectl --context $CTX -n "tenant-$t-gateway" get configmap -l app.kubernetes.io/name=openshell -o 'jsonpath={.items[0].data.gateway\.toml}' | grep -E '^ *gateway_id|^ *db_url|^ *namespace =' | tr '\n' ' ' | sed "s/^/     $t: /"; echo
done

echo "### 5. 一个 gateway 只管自己被指派的 runtime namespace(POC2 §14.3 问题 2)"
echo "   配置里的 namespace 字段(shared 模式)就是它唯一会写资源的地方:"
kubectl --context $CTX -n tenant-a-gateway get configmap -l app.kubernetes.io/name=openshell -o 'jsonpath={.items[0].data.gateway\.toml}' | grep -E "^ *namespace =" | sed 's/^/   A: /'
kubectl --context $CTX -n tenant-b-gateway get configmap -l app.kubernetes.io/name=openshell -o 'jsonpath={.items[0].data.gateway\.toml}' | grep -E "^ *namespace =" | sed 's/^/   B: /'
echo "   gateway 在**对方**的 runtime ns 里没有权限(RBAC 层面就是隔离的):"
printf '   A 的 SA 能否 list tenant-b-runtime 的 sandboxes: '
kubectl --context $CTX auth can-i list sandboxes.agents.x-k8s.io -n tenant-b-runtime \
  --as=system:serviceaccount:tenant-a-gateway:os-a-openshell
printf '   A 的 SA 能否 list tenant-a-runtime 的 sandboxes: '
kubectl --context $CTX auth can-i list sandboxes.agents.x-k8s.io -n tenant-a-runtime \
  --as=system:serviceaccount:tenant-a-gateway:os-a-openshell

echo
echo "### 6. 平台组件被安装时踩到的两处真实边界(值得进报告)"
echo "   (a) Gateway chart 的 certgen hook Job **不写 resources**。"
echo "       在带 ResourceQuota(limits.*) 的租户 namespace 里会被挡:"
kubectl --context $CTX -n tenant-b-gateway get events --field-selector reason=FailedCreate 2>/dev/null | tail -2 | cut -c1-160 | sed 's/^/       /' || echo "       (本已经没有失败事件 —— LimitRange default 把它补上了)"
echo "       → 结论: **租户 namespace 里有 limits.* 配额，就必须同时有 LimitRange default**，"
echo "         否则平台自己的安装在租户 ns 里起不来。这条要写进报告的'生产前必须解决'。"
echo "   (b) 同理，"必须显式写 requests/limits"这条 Gatekeeper 规则不能套在 gateway ns 上。"
echo "       POC2 §4.1 给的 platform.example.com/runtime 标签正是用来划这条线的:"
kubectl --context $CTX get ns -l capsule.clastix.io/tenant --no-headers \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"  runtime="}{.metadata.labels.platform\.example\.com/runtime}{"\n"}{end}' | sed 's/^/       /'
