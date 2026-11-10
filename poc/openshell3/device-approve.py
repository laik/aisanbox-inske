#!/usr/bin/env python3
"""以编程方式完成一次 Keycloak **Device Grant**(即"打开浏览器输 user code"那一步)。

为什么需要它(2026-11-10 实测出来的三步，少一步都拿不到 token):
  1) GET verification_uri_complete  -> 302 到 login-actions/authenticate
  2) POST username/password         -> 200，落在 login-actions/required-action?execution=OAUTH_GRANT
     ⚠ 这一步**必须带 -L**跟着跳，否则停在 302 上，看到的还是登录页 —— 我第一版就卡在这里，
       现象是"密码没错但设备一直 authorization_pending"。
  3) 在 OAUTH_GRANT 页 POST 那个带 `code`(Keycloak 的请求防伪)的表单 -> 302 到 /device/status
  之后设备端用 device_code 换 token 才会成功。

两个与 PKCE 有关的实测点(都是 400 的硬要求，不是可选加固):
  - device 授权请求必须带 code_challenge / code_challenge_method
    ("Missing parameter: code_challenge_method") —— 因为 client 上配了
    pkce.code.challenge.method=S256。
  - code_challenge 必须是 **base64url**(`-`/`_`、无 padding)。用标准 base64(`+`/`=`)会被拒:
    "Invalid parameter: code_challenge"。

用法: device-approve.py <username> <password> <verification_uri_complete> [--cacert FILE]
退出码 0 = 设备已授权(浏览器那条路走通)。
"""
import argparse, base64, hashlib, json, re, secrets, subprocess, sys, time, urllib.parse

KC_DEFAULT = "https://172.22.0.3:31443/realms/aisanbox"


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("username")
    ap.add_argument("password")
    ap.add_argument("verification_uri", help="CLI 打印的 …/device?user_code=XXXX-XXXX")
    ap.add_argument("--cacert", default="/tmp/issuer-ca.crt")
    ap.add_argument("--origin", default=KC_DEFAULT.rsplit("/realms", 1)[0])
    ap.add_argument("--cookiejar", default=None)
    a = ap.parse_args()

    jar = a.cookiejar or "/tmp/da-jar-%s" % secrets.token_hex(4)
    base = ["curl", "-sS", "-m", "25", "--cacert", a.cacert, "-c", jar, "-b", jar]

    def run(*extra):
        return subprocess.run(base + list(extra), capture_output=True, text=True)

    # 1) 打开验证地址(跟随重定向到登录表单)
    r = run("-L", "-o", "/tmp/da-p1.html", "-w", "%{http_code} %{url_effective}", a.verification_uri)
    if r.returncode:
        print("!! 打开验证地址失败: %s" % r.stderr.strip(), file=sys.stderr)
        return 2
    form_url = r.stdout.split()[-1]
    html = open("/tmp/da-p1.html").read()
    act = re.search(r'<form[^>]*action="([^"]*)"', html)
    if not act:
        print("!! 登录页里没有 <form action>（可能已经登录过，或页面结构变了）", file=sys.stderr)
        return 3
    url = act.group(1) if act.group(1).startswith("http") else a.origin + act.group(1)

    def hidden(h):
        return {m.group(1): m.group(2) for m in
                re.finditer(r'<input[^>]*type="hidden"[^>]*name="([^"]*)"[^>]*value="([^"]*)"', h)}

    args = ["-d", "username=%s" % a.username, "-d", "password=%s" % a.password]
    for k, v in hidden(html).items():
        args += ["-d", "%s=%s" % (k, urllib.parse.quote(v))]
    # 2) 提交登录。**必须 -L**: OAUTH_GRANT 是 required-action，302 之后才是确认页。
    r = run("-L", "-o", "/tmp/da-p2.html", "-w", "%{http_code} %{url_effective}", "-X", "POST", url, *args)
    grant_url = r.stdout.split()[-1]
    html2 = open("/tmp/da-p2.html").read()
    title = (re.search(r"<title>([^<]*)</title>", html2) or [None, "?"])[1]
    if "required-action" not in grant_url and "device" not in grant_url:
        print("!! 登录后没有落在授权确认页(url=%s, title=%s)" % (grant_url[:120], title), file=sys.stderr)
        return 4

    # 3) 确认把这台设备授权给该 client
    act2 = re.search(r'<form[^>]*action="([^"]*)"', html2)
    u2 = act2.group(1) if (act2 and act2.group(1).startswith("http")) else a.origin + (act2.group(1) if act2 else "")
    args2 = []
    for k, v in hidden(html2).items():
        args2 += ["-d", "%s=%s" % (k, urllib.parse.quote(v))]
    for n, v in (re.findall(r'<button[^>]*name="([^"]*)"[^>]*value="([^"]*)"', html2)
                 + re.findall(r'<input[^>]*type="submit"[^>]*name="([^"]*)"[^>]*value="([^"]*)"', html2)):
        args2 += ["-d", "%s=%s" % (n, urllib.parse.quote(v))]
    if not args2:
        print("!! 授权确认页里没有任何表单字段", file=sys.stderr)
        return 5
    r = run("-o", "/tmp/da-p3.html", "-w", "%{http_code} %{redirect_url}", "-X", "POST", u2, *args2)
    if "device" not in r.stdout:
        print("!! 确认授权后没跳到 device/status: %s" % r.stdout[:160], file=sys.stderr)
        return 6
    print("   已授权(user=%s)" % a.username)
    return 0


if __name__ == "__main__":
    sys.exit(main())
