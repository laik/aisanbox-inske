#!/bin/sh
# 数据 Agent 的 AI 部分（软验证）：opencode 经 OpenShell provider 代理调模型。
# 本地模型有时返回空且退出码 0（POC2 实测）—— 所以只打印字节数，不拿模型
# 输出当可复现结论。平台侧确定的是：占位 key 可用、真实 key 不进 sandbox。
mkdir -p /tmp/da-home /tmp/da-work
export HOME=/tmp/da-home
export XDG_DATA_HOME=/tmp/da-home/.local/share
export XDG_CONFIG_HOME=/tmp/da-home/.config
cp /usr/share/da/opencode.json /tmp/da-work/opencode.json
cd /tmp/da-work
LATEST=$(ls -t /data/output/result-*.csv 2>/dev/null | head -1)
[ -n "$LATEST" ] || { echo "[da-ai] 没有结果文件，先跑 da-agent.sh"; exit 1; }
timeout 150 opencode run "读取文件 $LATEST ，用一句中文说明哪个 region 的金额最高。只输出一句话。" \
  > /tmp/da-ai.out 2>&1
RC=$?
echo "[da-ai] exit=$RC bytes=$(wc -c < /tmp/da-ai.out)"
cat /tmp/da-ai.out