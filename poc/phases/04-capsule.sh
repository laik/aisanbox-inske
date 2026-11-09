#!/usr/bin/env bash
# Phase 1d —— Capsule 租户管理 (POC2 §3.4)
# 手工重现: bash poc/phases/04-capsule.sh
#
# 这一阶段验证 POC-02「租户只能使用自己的 Runtime Namespace」。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
CAPSULE_VERSION=${CAPSULE_VERSION:-0.15.2}
GRP_A=tenant-a-owners; GRP_B=tenant-b-owners

# POC2 §3.4 没写这一步，但 Capsule 0.15.2 的 chart 里有 cert-manager.io/v1 的
# Certificate/Issuer —— 没装 cert-manager 直接 install 会失败。这是实测发现的前提依赖。
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack
kubectl --context $CTX apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
kubectl --context $CTX -n cert-manager wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance=cert-manager --all --timeout=240s

# 实测坑(第二轮才发现): 只 `helm repo add` 不 `helm repo update`，在**干净机器**上会失败:
#   Error: no cached repo found. (try 'helm repo update')
# 第一轮能过是因为本机 helm 缓存里已经有这个 repo。加 update，并且不再吞掉报错。
helm repo add projectcapsule https://projectcapsule.github.io/charts
helm repo update projectcapsule
kubectl --context $CTX create ns capsule-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm --kube-context $CTX upgrade --install capsule projectcapsule/capsule --version $CAPSULE_VERSION \
  -n capsule-system --wait --timeout 5m

kubectl --context $CTX apply -f capsule2/tenants.yaml
kubectl --context $CTX apply -f capsule2/tenant-owners.yaml
sleep 5
echo "### tenants"
kubectl --context $CTX get tenants

# ---------------------------------------------------------------------------
# 关键发现: "把 namespace 归到某个租户"不能事后追认
# ---------------------------------------------------------------------------
# POC2 §4.1 写的是"由平台管理员创建 Gateway 和 Runtime Namespace，并确保这些 Namespace
# 归属于正确 Tenant"。在 Capsule 0.15 里这条路走不通，两条子路都被 webhook 挡住：
#   (1) 管理员直接建 -> ns 不带任何 capsule 标签，租户 status 也不登记它，
#       于是配额 / LimitRange / 策略都不会下发到这个 ns；
#   (2) 建完之后手工打 capsule.clastix.io/tenant 标签 ->
#       Error: namespaces.validating.projectcapsule.dev denied the request:
#       namespace can not be patched into a tenant
# 归属只在**创建那一刻**由 mutating webhook 注入。因此本 POC 的做法是：
# **由 tenant owner 身份创建这些 ns，名字由平台规定(前缀强制)，权限由平台规定。**
# 也就是说"平台决定名字和边界，租户执行创建动作"。
echo
echo "### POC-02 验收 1: Gateway / Runtime namespace 归属租户"
kubectl --context $CTX delete ns tenant-a-scratch freeloaders tenant-a-steal --ignore-not-found --wait=true >/dev/null 2>&1
for t in a b; do for k in gateway runtime; do
  kubectl --context $CTX delete ns tenant-$t-$k --ignore-not-found --wait=true >/dev/null 2>&1
done; done
# 坑①: `create ns --as=… | kubectl apply -f -` 会把身份丢掉 —— apply 那一步是管理员身份,
#       于是 ns 建出来了但没有归属标签、也没有配额(正是 POC-02 要防的情况)。
# 坑②: 改成 apply --as=alice 也不行: apply 要先 GET 目标对象, 而 tenant owner 对
#       namespace 对象本身没有 get 权限 -> "cannot get resource namespaces"。
# 结论: 租户侧的 ns 创建就用 plain `kubectl create ns --as=…`；要幂等就先删。
for k in gateway runtime; do
  kubectl --context $CTX delete ns tenant-a-$k --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl --context $CTX delete ns tenant-b-$k --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl --context $CTX create ns tenant-a-$k --as=alice --as-group=$GRP_A
  kubectl --context $CTX create ns tenant-b-$k --as=bob --as-group=$GRP_B
done
# 归属标签与配额是 Capsule controller 异步 reconcile 出来的，等它落地再断言。
# (sleep 4 太短，会看到 ns 已建但标签为空 —— 别把它当成"归属失败"。)
for i in $(seq 1 45); do
  # 等的是**配额下发**，不是标签：标签先到(约 2s)，ResourceQuota 与 Tenant.status
  # 的登记更晚。只等标签会让下面两行读到旧状态，看起来像"没归属"。
  kubectl --context $CTX -n tenant-a-runtime get resourcequota --no-headers 2>/dev/null | grep -q . && break
  sleep 2
done
[ "$i" -le 45 ] && echo "   (归属 + 配额下发完成, 用时约 $((i*2))s)" || echo "   (!) 等待 90s 后租户-a-runtime 仍没有 ResourceQuota"
echo "   Capsule 注入的归属标签 + 租户自定义标签:"
# 坑③: custom-columns 里 label 的点号必须转义，写错会**全部显示 <none>**，
#       很容易被误读成"归属没生效"。改用 jsonpath（下面的写法已实测可用）。
kubectl --context $CTX get ns -l capsule.clastix.io/tenant --no-headers \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"   capsule-tenant="}{.metadata.labels.capsule\.clastix\.io/tenant}{"   platform-tenant="}{.metadata.labels.platform\.example\.com/tenant}{"\n"}{end}' \
  | sed 's/^/      /'
echo
echo "   Tenant.status 里登记的 namespace(= 配额与策略的作用范围):"
kubectl --context $CTX get tenant --no-headers \
  -o 'jsonpath={range .items[*]}{.metadata.name}{" -> "}{.status.namespaces}{"\n"}{end}' | sed 's/^/      /'
echo "   自动下发的 ResourceQuota / LimitRange(POC2 §3.5 要求的 requests/limits 由此兜住):"
kubectl --context $CTX -n tenant-a-runtime get resourcequota,limitrange --no-headers 2>&1 | cut -c1-118 | sed 's/^/      /'

# ---------------------------------------------------------------------------
# POC2 §4.1: 标签「由平台管理，租户不可自行修改」。
# 这一步**必须存在**，不是装饰: gatekeeper/constraints.yaml 里
# poc-tenant-pod-boundary 的 namespaceSelector 用的就是
#   platform.example.com/tenant=<t> AND platform.example.com/runtime="true"
# 少了 runtime 标签，约束就**静默不生效** —— 这正是 §3.5 警告的"宽泛豁免"的反面教材:
# 不是豁免太宽，而是**作用域为空**，规则看起来装了、其实一条都没管。
# 实测(第二轮): 第一轮没写这一步，05 阶段的"平台身份应放行"和"租户身份应被拒"
# 全部通过 —— 但通过的原因是**没有任何约束在管**，属于假通过。
# ---------------------------------------------------------------------------
echo
echo "### 平台标签: 只有 runtime ns 带 platform.example.com/runtime=true"
for t in a b; do
  kubectl --context $CTX label ns tenant-$t-runtime platform.example.com/runtime=true --overwrite >/dev/null
  kubectl --context $CTX label ns tenant-$t-gateway platform.example.com/runtime- >/dev/null 2>&1 || true
done
kubectl --context $CTX get ns -l capsule.clastix.io/tenant --no-headers \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"  tenant="}{.metadata.labels.platform\.example\.com/tenant}{"  runtime="}{.metadata.labels.platform\.example\.com/runtime}{"\n"}{end}' \
  | sed 's/^/      /'
echo "   → gateway ns 故意**不带** runtime: Gateway chart 的 certgen Job 不写 resources，"
echo "     按 namespace 生效的'必须显式 requests/limits'会把平台自己的安装卡死(实测 08 阶段)。"
echo "     这条边界是按**角色**划的，不是按租户一刀切豁免(POC2 §3.5)。"

echo
echo "### POC-02 验收 2: 租户 owner 只能建自己前缀的 ns"
echo "   (a) alice 建 tenant-a-scratch -> 期望允许:"
kubectl --context $CTX create ns tenant-a-scratch --as=alice --as-group=$GRP_A 2>&1 | sed 's/^/      /'
echo "   (b) alice 建 tenant-b-steal -> 期望被拒:"
kubectl --context $CTX create ns tenant-b-steal --as=alice --as-group=$GRP_A 2>&1 | sed 's/^/      /'
echo "   (c) alice 建无租户前缀的 ns -> 期望被拒:"
kubectl --context $CTX create ns freeloaders --as=alice --as-group=$GRP_A 2>&1 | sed 's/^/      /'
echo "   (d) alice 想改 tenant-b-gateway 的标签 -> 期望被拒:"
kubectl --context $CTX label ns tenant-b-gateway platform.example.com/tenant=tenant-a --overwrite \
  --as=alice --as-group=$GRP_A 2>&1 | sed 's/^/      /'
echo "   (e) alice 在 tenant-b-runtime 里建 pod -> 期望被拒:"
kubectl --context $CTX -n tenant-b-runtime run x --image=alpine --as=alice --as-group=$GRP_A \
  --dry-run=server -o name 2>&1 | sed 's/^/      /'
echo
echo "### POC-02 验收 3: 租户能看到的 namespace 集合"
kubectl --context $CTX get ns --as=alice --as-group=$GRP_A -o custom-columns=N:.metadata.name --no-headers 2>&1 | sed 's/^/      /'
echo "   (对比: bob)"
kubectl --context $CTX get ns --as=bob --as-group=$GRP_B -o custom-columns=N:.metadata.name --no-headers 2>&1 | sed 's/^/      /'
echo
echo "### 说明: platform.example.com/* 这类标签由平台管理"
echo "   上面的 additionalMetadata 让 Capsule 在创建时注入它，且 Capsule 会阻止"
echo "   租户改写带 capsule/平台前缀的标签(见验收 2 的 (d))。"
kubectl --context $CTX delete ns tenant-a-scratch --ignore-not-found >/dev/null 2>&1
