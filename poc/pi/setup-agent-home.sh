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
#
# ⚠ 实测坑(2026-11-09，这条让 POC-08 一度被判成"没有 trace"):
#   **pi-otel 不读 agent 目录根下的 settings.json。** 它的 dist/config.js 只从两个地方取配置:
#     join(homedir(), ".pi", "agent", "settings.json")   或   join(cwd, ".pi", "settings.json")
#   之前这里写的是 $DST/settings.json —— 路径不被读取，于是 pi-otel 全部退回默认值:
#     serviceName 默认 **"pi"**(不是 pi-agent)、captureContent 默认、logs 信号默认**开着**。
#   直接后果: 按 `service=pi-agent` 查 Jaeger 永远 0 条(而 trace 其实一直是通的，
#   只是登记在 `service=pi` 名下)。**"查不到"不一定是"没有"，先核对查询键。**
#   models.json 则**确实**是从 agent 目录根读的($DST/models.json 保持原样即可)——
#   两个文件的查找规则不一样，这是最容易写错的地方。
#   下面同时写两处: 正确位置($HOME/.pi/agent/，因为 HOME=$DST)保证 pi-otel 读到，
#   agent 目录根保留一份便于人工核对。
mkdir -p "$DST/.pi/agent"
cat > "$DST/.pi/agent/settings.json" <<JSON
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

cp "$DST/.pi/agent/settings.json" "$DST/settings.json"

# ⚠ 第二个坑，和上面那个是连在一起的: pi-otel 找配置用的是 **homedir()**，不是
#   PI_CODING_AGENT_DIR。所以调用 pi 之前必须 **HOME 与 PI_CODING_AGENT_DIR 同值**，
#   否则 $DST/.pi/agent/settings.json 还是读不到(实测: HOME=/tmp 时 service.name 又变回 "pi")。
#   本脚本自己的 HOME=$DST 只在**它自己的进程**里生效，export 不出去 —— 所以这里写出一个
#   env 文件，调用方 `. /tmp/pi-home.env` 就对了。少了这一步，配置又会被静默忽略。
# OTEL_SERVICE_NAME 是**确定性**的那一条: pi-otel 的取值顺序是
#   process.env.OTEL_SERVICE_NAME ?? settings.serviceName ?? "pi"
# 环境变量不依赖任何路径解析，所以两个都设(settings.json 里的 serviceName 保留，是因为
# captureContent / spanNaming / signals **只能**从 settings.json 取 —— 实测改对路径后
# span 名从 `pi.turn` 变成 POC2 §6.3 期望的 `invoke_agent pi` / `chat <model>`，
# 那就是 settings 被读到的直接证据)。
cat > "${DST}.env" <<EOF
export HOME="$DST"
export PI_CODING_AGENT_DIR="$DST"
export OTEL_SERVICE_NAME="${PI_SERVICE_NAME:-pi-agent}"
EOF
echo "PI_CODING_AGENT_DIR=$PI_CODING_AGENT_DIR (源=$SRC)"
echo "pi-otel settings=$DST/.pi/agent/settings.json  (用 . ${DST}.env 保证 HOME 同值)"
echo "otlp endpoint=${OTEL_EXPORTER_OTLP_ENDPOINT:-<未注入>} proto=${OTEL_EXPORTER_OTLP_PROTOCOL:-<未注入>}"
