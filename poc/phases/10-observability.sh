#!/usr/bin/env bash
# Phase 5-pre —— 统一遥测接入点 (POC2 §7.3 / §8 / §12)
# 手工重现: bash poc/phases/10-observability.sh
#
# 为什么放在 Gateway **之前**装: openshell2/gateway-values.yaml 里 otlp.endpoint 指向
# otel-collector.observability.svc:4317。先装 gateway 的话，启动初期所有 export 都失败，
# 于是"gateway 没有 trace"这件事会被误读成"OpenShell 的 OTLP 没配好"。
# 顺序本身不是功能要求(OTLP 会重试/丢弃后继续)，但它决定**第一屏看到的是不是干净信号**。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc

# Jaeger 镜像的 registry 换过(cr.jaegertracing.io 是新地址；quay.io 上的旧地址还在)。
# 这里用 observability2/collector.yaml 里写死的 cr.jaegertracing.io —— 实测可拉。
kubectl --context $CTX create ns observability --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 把宿主 LAN IP 写进 manifest 的副本再 apply(见 collector.yaml 里 HOST_LAN_IP 的注释)。
HOST_LAN_IP=${HOST_LAN_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')}
MANIFEST=$(mktemp)
sed "s/__HOST_LAN_IP__/${HOST_LAN_IP}/" observability2/collector.yaml > "$MANIFEST"
echo "   第二出口(演示用 Tempo)目标: http://${HOST_LAN_IP}:4317"
kubectl --context $CTX apply -f "$MANIFEST" >/dev/null
rm -f "$MANIFEST"
# 实测坑: 改 ConfigMap **不会**让 Deployment 重建 Pod(没有 checksum 注解)。
# 于是旧 Pod 继续用旧配置 CrashLoopBackOff，而 `rollout status` 会一直等到超时 ——
# 报错读起来像"镜像拉不下来"，其实是配置没生效。要么加 checksum 注解(生产做法),
# 要么显式 restart(POC 的做法)。
kubectl --context $CTX -n observability rollout restart deploy/otel-collector deploy/jaeger >/dev/null
kubectl --context $CTX -n observability rollout status deploy/otel-collector --timeout=240s
kubectl --context $CTX -n observability rollout status deploy/jaeger --timeout=240s

echo "### 组件"
kubectl --context $CTX -n observability get pods -o wide --no-headers \
  -o custom-columns=N:.metadata.name,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName | sed 's/^/   /'

echo
echo "### 先自证 collector 本身活着(不等 agent): 自己发一条 OTLP trace 进去"
# 用一个最小 OTLP/HTTP 请求打进 4318。这样"后面没有 trace"就只能解释为"agent 没发"，
# 而不是"接入点没通"。这是观测栈里最容易混淆的一组假阴性。
kubectl --context $CTX -n observability delete pod net-probe --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX apply -f observability/net-probe.yaml >/dev/null
kubectl --context $CTX -n observability wait --for=jsonpath='{.status.phase}=Succeeded' pod/net-probe --timeout=120s >/dev/null 2>&1
kubectl --context $CTX -n observability logs net-probe 2>&1 | sed 's/^/   /'
kubectl --context $CTX -n observability delete pod net-probe --wait=false >/dev/null 2>&1
# 顺序: OTLP 提交与 Jaeger 查询在**同一个 pod**里，中间要留时间让
# collector(batch processor) 与 Jaeger 索引落地，否则"查不到"只是时序问题。
# Jaeger 的 /api/services 在第一条 span 到达后才非空。
echo "   collector 侧收到多少(它的 debug exporter):"
kubectl --context $CTX -n observability logs deploy/otel-collector --tail=200 2>/dev/null \
  | grep -E "Traces|Span" | tail -3 | cut -c1-140 | sed 's/^/     /'

# 第二出口是否在收: 用 Tempo 自己的查询端口确认。
# 实测: 这台宿主上的 tempo 用 --net=host 起，监听 3200(query)/4317-4318(OTLP)/9095，
# **不是** 3100。探测端口写错会得到"没有 Tempo"，其实是探测写错。
echo
echo "### 第二出口(Tempo)是否在收"
if curl -sS --max-time 5 -o /dev/null "http://${HOST_LAN_IP}:3200/metrics" 2>/dev/null; then
  echo "   Tempo query 端口可达(${HOST_LAN_IP}:3200)"
  echo "   Grafana(演示入口): http://${HOST_LAN_IP}:3000"
else
  echo "   宿主上没有 Tempo(:3200) —— 第二出口会一直重试(不影响 Jaeger 那条断言)"
fi

echo "### 外部可访问: Jaeger UI NodePort"
kubectl --context $CTX -n observability get svc jaeger --no-headers \
  -o 'jsonpath={.spec.ports[?(@.name=="ui")].nodePort}{"\n"}' | awk '{print "   http://<宿主IP>:"$1}'
echo "   ⚠ NodePort **不会**自动发布到宿主 —— kind 里必须用 extraPortMappings 显式映射
   (见 kind/poc2-cluster.yaml)。没映射时: 集群内可访问、宿主上 curl 不通，
   很容易误判成 Jaeger 没起来。"
