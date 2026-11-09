#!/usr/bin/env bash
# Phase 1b —— Antrea 作为唯一 CNI (POC2 §3.3)
# 手工重现: bash poc/phases/02-antrea.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
ANTREA_VERSION=${ANTREA_VERSION:-2.7.0}
# release asset(charts.antrea.io 指向 github releases 的 tgz)在某些网络下 503/504。
# 用 scripts/gh-fetch.sh 先取到 vendor/，再从本地装 —— 结果与在线装完全一致。
ANTREA_CHART=${ANTREA_CHART:-vendor/antrea-2.7.0.tgz}

helm repo add antrea https://charts.antrea.io >/dev/null 2>&1 || true
helm repo update antrea >/dev/null 2>&1 || true
helm upgrade --install antrea "$ANTREA_CHART" --kube-context $CTX \
  --namespace kube-system --version "$ANTREA_VERSION"
# 冷集群要现拉 antrea 镜像(约 200MB)，180s 不够(实测重建第二轮正好卡在这里，
# 而节点在超时之后几十秒就 Ready 了 —— 这种"脚本报错但实际会成功"要放大超时，
# 而不是让阶段看起来失败)。
kubectl --context $CTX rollout status ds/antrea-agent -n kube-system --timeout=420s
kubectl --context $CTX get nodes -o wide
