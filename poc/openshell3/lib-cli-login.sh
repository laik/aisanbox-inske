# 让 OpenShell CLI 以**指定身份**登录一台 OIDC Gateway —— 走的是产品自己的 device flow，
# 不是我把 token 塞进去。这一点很重要: 塞 token 只能证明"gateway 认这张 JWT"，
# 走 CLI 的登录流程才能证明**这条链在真实使用方式下是通的**(§五"身份链路")。
#
# 用法: cli_login_as <profile名> <用户> <密码> <issuer> <endpoint>
# 结果: ~/.config/openshell/gateways/<profile>/oidc_token.json 里有了该身份的 token。
cli_login_as() { # cli_login_as <profile> <user> <pass> <issuer> <endpoint>
  local prof=$1 user=$2 pass=$3 issuer=$4 ep=$5
  local C=$CLI L=/tmp/os-add-$prof.log
  rm -rf "$HOME/.config/openshell/gateways/$prof"
  # ⚠ OPENSHELL_NO_BROWSER=1: 不弹浏览器(远端没有浏览器)，CLI 会把验证 URL 打到 stdout。
  # ⚠ OPENSHELL_GATEWAY_INSECURE 的取值是 **true/false**，给 1 会被拒("[possible values: true, false]")。
  OPENSHELL_NO_BROWSER=1 OPENSHELL_GATEWAY_INSECURE=true timeout 150 \
    "$C" gateway add "$ep" --name "$prof" --oidc-issuer "$issuer" --oidc-client-id openshell-cli \
    > "$L" 2>&1 &
  local pid=$! VL=""
  for i in $(seq 1 30); do
    VL=$(grep -m1 -oE 'https://[^ ]*/device\?user_code=[A-Z]+-[A-Z]+' "$L")
    [ -n "$VL" ] && break
    sleep 1
  done
  if [ -z "$VL" ]; then
    echo "✗ 没拿到设备码 URL:"; tail -6 "$L" | sed 's/^/     /'; kill $pid 2>/dev/null; return 1
  fi
  # device-approve.py 扮演"人打开浏览器输 code 再点确认"这三步(它的 docstring 里
  # 记着每一步的坑，尤其是登录后必须跟随 302 到 OAUTH_GRANT 那一跳)。
  python3 "$(dirname "$BASH_SOURCE")/device-approve.py" "$user" "$pass" "$VL" || {
    echo "✗ device 授权失败"; kill $pid 2>/dev/null; return 1; }
  wait $pid 2>/dev/null
  if [ -f "$HOME/.config/openshell/gateways/$prof/oidc_token.json" ]; then
    return 0
  fi
  echo "✗ 没有 oidc_token.json:"; tail -6 "$L" | sed 's/^/     /'; return 1
}
# 矩阵里所有 CLI 调用都要带这两个: gateway 服务器证书是 certgen 自签的，
# --gateway-insecure 跳过的只是**CLI 校验服务端证书**，与被测的"调用者是谁"无关(代价见结论)。
OSC() { local prof=$1; shift; OPENSHELL_GATEWAY_INSECURE=true "$CLI" -g "$prof" "$@"; }
