#!/usr/bin/env bash
# 本机 Go 系工具(kubectl/helm)被本机 TUN 代理挡住时的备用通道: SSH 本地转发。
# 用法: bash poc/kind/ssh-tunnel.sh   (保持前台; Ctrl-C 结束)
set -euo pipefail
REMOTE=${REMOTE:-root@192.168.5.190}
LOCAL_PORT=${LOCAL_PORT:-16443}
echo "127.0.0.1:${LOCAL_PORT} -> ${REMOTE}:6443  (Ctrl-C 结束)"
ssh -N -o ServerAliveInterval=30 -L "${LOCAL_PORT}:127.0.0.1:6443" "$REMOTE"
