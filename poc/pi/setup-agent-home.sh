#!/bin/sh
# 在**沙箱内**运行: 把镜像里只读的 Pi agent 目录复制成可写的工作副本，并写入
# 本次场景需要的 models.json / settings.json。
#
# 为什么要在运行期复制(而不是直接用镜像里那份): Pi 会往 agent 目录写
# trust.json.lock / sessions / auth.json —— 只读目录会直接 EACCES。
# 为什么源在 /usr/local(不是 /opt): 见 Dockerfile 注释 —— OpenShell 的默认
# 文件系统基线包含 /usr，不含 /opt。
#
# OTLP endpoint **不在这里写**: OpenShell 给每个 sandbox 注入
# OTEL_EXPORTER_OTLP_ENDPOINT / _PROTOCOL(指向该 sandbox 自己的 supervisor relay)，
# pi-otel 读这两个环境变量。这样 agent 不需要知道 Collector 地址，也不需要凭据
# (POC2 §8.2)。
set -e
SRC="${PI_AGENT_DIR:-/usr/local/pi-home}"
DST="${PI_HOME:-/tmp/pi-home}"
rm -rf "$DST"
cp -r "$SRC" "$DST"
HOME="$DST"
PI_CODING_AGENT_DIR="$DST"

# 模型端点: OpenAI-compatible。apiKey 用 $OPENAI_API_KEY 插值 —— 沙箱里那个值是
# OpenShell 的**代理占位符**(openshell:resolve:env:...)，真实 key 只在边界上注入。
cat > "$DST/models.json" <<JSON
{
  "providers": {
    "poc-model": {
      "name": "PoC model (OpenAI-compatible)",
      "baseUrl": "${POC_MODEL_BASE_URL:-http://192.168.5.190:8080/v1}",
      "apiKey": "$OPENAI_API_KEY",
      "api": "openai-completions",
      "authHeader": true,
      "models": [
        { "id": "${POC_MODEL_ID:-qwen3.8-flash-next}",
          "name": "${POC_MODEL_ID:-qwen3.8-flash-next}",
          "input": ["text"],
          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
          "contextWindow": 131072, "maxTokens": 4096 }
      ]
    }
  }
}
JSON

# POC2 §6.2 的配置。captureContent=metadata_only 是 §6.2 明确要求的:
# 不采完整 prompt / 思维内容 / token。
cat > "$DST/settings.json" <<JSON
{
  "packages": ["npm:pi-otel@0.3.0"],
  "otel": {
    "enabled": true,
    "protocol": "http/protobuf",
    "serviceName": "pi-agent",
    "captureContent": "metadata_only",
    "spanNaming": "genai",
    "sampleRatio": 1.0,
    "signals": { "traces": true, "metrics": false, "logs": false }
  }
}
JSON

echo "PI_CODING_AGENT_DIR=$PI_CODING_AGENT_DIR (源=$SRC)"
echo "otlp endpoint=${OTEL_EXPORTER_OTLP_ENDPOINT:-<未注入>} proto=${OTEL_EXPORTER_OTLP_PROTOCOL:-<未注入>}"
