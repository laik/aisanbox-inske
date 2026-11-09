#!/usr/bin/env bash
# Phase 1c —— POC2 §3.3 的验收: 用**真实连接**证明 Antrea 会执行 NetworkPolicy 的
# ingress 和 egress，而不是只看对象有没有创建成功。
# 手工重现: bash poc/phases/03-netpol-verify.sh
#
# 踩过的坑(写下来省得下次再踩):
#   * `nc -l -p 8080 -k -s 127.0.0.1` 只绑 loopback —— 跨 pod 连接必然失败，
#     会让人误判 "CNI 不执行 NetworkPolicy"。不要给 -s。
#   * `httpd` 会 daemonize，容器立刻退出。要用前台进程。
#   * 两个 pod 必须落在**不同节点**，才能顺带证明 overlay 路径上的策略也生效。
set -uo pipefail
CTX=kind-agent-runtime-poc
NS=netpol-verify
PASS=0; FAIL=0

chk() { # chk <说明> <期望 PASS|FAIL> <实际>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '   ✓ %-46s 期望=%s 实际=%s\n' "$1" "$2" "$3"
  else FAIL=$((FAIL+1)); printf '   ✗ %-46s 期望=%s 实际=%s  <== 不符合预期\n' "$1" "$2" "$3"; fi
}

# 每轮从头开始: 直接删掉这个 ns 重建，避免残留对象造成假失败。
kubectl --context $CTX delete ns $NS --wait=true >/dev/null 2>&1
kubectl --context $CTX create ns $NS >/dev/null

# 一个 Deployment 起 server，podAntiAffinity 保证 client/server 跨节点。
kubectl --context $CTX apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: netpol-harness, namespace: netpol-verify}
spec:
  replicas: 1
  selector: {matchLabels: {app: np-server}}
  template:
    metadata: {labels: {app: np-server}}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector: {matchLabels: {run: np-client}}
      containers: [{name: agent, image: alpine:latest,
                    command: ["nc", "-l", "-p", "8080", "-k"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: np-client, namespace: netpol-verify, labels: {run: np-client}}
spec:
  containers: [{name: agent, image: alpine:latest, command: ["sleep", "3600"]}]
YAML
kubectl --context $CTX -n $NS wait --for=condition=Ready pod -l app=np-server --timeout=90s >/dev/null
kubectl --context $CTX -n $NS wait --for=condition=Ready pod np-client --timeout=90s >/dev/null

S=$(kubectl --context $CTX -n $NS get pod -l app=np-server -o jsonpath='{.items[0].status.podIP}')
SN=$(kubectl --context $CTX -n $NS get pod -l app=np-server -o jsonpath='{.items[0].spec.nodeName}')
CN=$(kubectl --context $CTX -n $NS get pod np-client -o jsonpath='{.spec.nodeName}')
printf '   server=%s on %s\n   client-pod=np-client on %s\n' "$S" "$SN" "$CN"
[ "$SN" != "$CN" ] && echo "   (跨节点, 会经过 Antrea overlay/OVS)" || echo "   (!) 同节点: 这一轮只验证了本机路径"

conn() { kubectl --context $CTX -n $NS exec np-client -- sh -c "nc -z -w 4 $1 $2 && echo PASS || echo FAIL"; }
dns()  { kubectl --context $CTX -n $NS exec np-client -- sh -c "nslookup kubernetes.default 2>&1 | grep -q Address: && echo PASS || echo FAIL"; }

echo; echo "### 1. 没有任何策略时，连接与 DNS 都应通"
chk "ingress client->server:8080 (无策略)" PASS "$(conn $S 8080)"
chk "egress DNS -> CoreDNS (无策略)"       PASS "$(dns)"

echo; echo "### 2. 应用 deny-all(Ingress+Egress) 后都应被拦"
kubectl --context $CTX apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: np-deny-all, namespace: netpol-verify}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
YAML
sleep 15
chk "ingress 被拒" FAIL "$(conn $S 8080)"
chk "egress 到集群外 IP 被拒" FAIL "$(conn 1.1.1.1 53)"
chk "egress DNS 被拒"        FAIL "$(dns)"

echo; echo '### 3. 只放行 ingress(带白名单) —— 证明是「按规则」而不是全放行'
kubectl --context $CTX -n $NS delete netpol np-deny-all >/dev/null
kubectl --context $CTX -n $NS run np-other --image=alpine --command -- sleep 900 >/dev/null 2>&1
kubectl --context $CTX -n $NS wait --for=condition=Ready pod np-other --timeout=60s >/dev/null 2>&1
kubectl --context $CTX apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: np-allow-only-client, namespace: netpol-verify}
spec:
  podSelector: {matchLabels: {app: np-server}}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {matchLabels: {run: np-client}}}], ports: [{port: 8080}]}]
YAML
sleep 12
chk "未被白名单选中的 pod -> server 被拒" FAIL "$(kubectl --context $CTX -n $NS exec np-other -- sh -c "nc -z -w 4 $S 8080 && echo PASS || echo FAIL")"
sleep 5
chk "白名单里的 client -> server 放行"    PASS "$(conn $S 8080)"

echo; echo "### 4. 证明策略进了 Antrea 自己的控制面与 OVS 流表(不只是 kubectl 对象)"
# 注意: antctl 里的 name 是 Antrea 内部 UUID，按**源对象**检索要用 -n <ns> 列出后看 SOURCE 列。
NODE=$(kubectl --context $CTX -n $NS get pod -l app=np-server -o jsonpath='{.items[0].spec.nodeName}')
# 关键: antctl 只看**本节点**的策略，必须 exec 到 server 所在节点的那个 agent pod。
AGENT=$(kubectl --context $CTX -n kube-system get pods -l app=antrea \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | awk -v n="$NODE" '$2==n {print $1}' | head -1)
echo "   server 所在节点=$NODE, antrea-agent=$AGENT"
kubectl --context $CTX -n kube-system exec $AGENT -c antrea-agent -- \
  antctl get networkpolicy -n $NS 2>&1 | cut -c1-140 | sed 's/^/   /' 
n0=$(kubectl --context $CTX -n kube-system exec $AGENT -c antrea-agent -- ovs-ofctl dump-flows br-int 2>/dev/null | grep -c cookie)
kubectl --context $CTX -n $NS apply -f - >/dev/null <<'Y'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: np-deny-all2, namespace: netpol-verify}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
Y
sleep 12
n1=$(kubectl --context $CTX -n kube-system exec $AGENT -c antrea-agent -- ovs-ofctl dump-flows br-int 2>/dev/null | grep -c cookie)
chk "deny-all 使 br-int 流表增加($n0 -> $n1)" OK "$( [ "$n1" -gt "$n0" ] && echo OK || echo NO )"
kubectl --context $CTX -n $NS delete netpol np-deny-all2 >/dev/null
sleep 8
n2=$(kubectl --context $CTX -n kube-system exec $AGENT -c antrea-agent -- ovs-ofctl dump-flows br-int 2>/dev/null | grep -c cookie)
chk "撤销后流表回落($n1 -> $n2)" OK "$( [ "$n2" -le "$n0" ] && echo OK || echo NO )"

echo; echo "### 结果: PASS=$PASS FAIL=$FAIL"
echo "清理: kubectl --context kind-agent-runtime-poc delete ns $NS"
exit $([ "$FAIL" = 0 ] && echo 0 || echo 1)
