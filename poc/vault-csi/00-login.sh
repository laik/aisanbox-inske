#!/usr/bin/env bash
# 刷新 os-tadmin 的 OIDC token（Keycloak 里这个 realm 的 token TTL 只有 30 分钟，
# 跑 POC 中途会过期，所以每次调用前重取一次；等价于 `openshell gateway login`，但非交互）。
# 用法: bash 00-login.sh [profile=user]
set -uo pipefail
PROF=${1:-os-tadmin}
ISS=${ISS:-https://192.168.5.221:31443/realms/aisanbox}
USER=${2:-tadmin}
PASS=${PASS:-poc3pass}
F=$HOME/.config/openshell/gateways/$PROF/oidc_token.json
[ -d "$(dirname "$F")" ] || { echo "没有 gateway profile $PROF（先 openshell gateway add）"; exit 1; }
curl -sk -X POST "$ISS/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=openshell-cli -d username="$USER" -d password="$PASS" \
  | python3 -c '
import json,sys,time
t=json.load(sys.stdin)
if "access_token" not in t: print("ERR",t); sys.exit(1)
json.dump({"access_token":t["access_token"],"refresh_token":t["refresh_token"],
           "expires_at":int(time.time())+t["expires_in"],
           "issuer":sys.argv[1],"client_id":"openshell-cli"},open(sys.argv[2],"w"))
print("token ok, ttl",t["expires_in"])' "$ISS" "$F"
