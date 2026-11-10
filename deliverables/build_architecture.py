#!/usr/bin/env python3
"""Generate the target architecture diagram as SVG (1920x1080).

Run:  python3 deliverables/build_architecture.py
Out:  deliverables/architecture.svg  (+ architecture.html for rendering)

Legend: solid = measured in the POC, dashed = design / not yet verified.
"""
import os

W, H = 1920, 1080

INK = "#0B1220"
INK2 = "#1E293B"
MUTED = "#5B6B82"
FAINT = "#8A99AE"
LINE = "#DCE3EE"
SOFT = "#F4F7FB"
PANEL = "#F7F9FC"
WHITE = "#FFFFFF"
TEAL = "#0F766E"
TEAL_M = "#14B8A6"
TEAL_L = "#E7F5F2"
BLUE = "#1D4ED8"
BLUE_L = "#E8EFFD"
AMBER = "#B45309"
AMBER_L = "#FEF3C7"
GREEN = "#15803D"
GREEN_L = "#DCFCE7"
RED = "#B91C1C"
RED_L = "#FEE2E2"

FONT = "'Hiragino Sans GB','PingFang SC','Microsoft YaHei','Noto Sans CJK SC',sans-serif"
MONO = "'Menlo','SF Mono','Consolas',monospace"

out = []


def add(s):
    out.append(s)


def esc(t):
    return (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def rect(x, y, w, h, fill="none", stroke="none", sw=1, rx=0, dash=None, opacity=1):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d} opacity="{opacity}"/>')


def text(x, y, s, size=12, fill=INK2, weight="400", anchor="start",
         family=FONT, ls=0, opacity=1):
    add(f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" '
        f'fill="{fill}" font-weight="{weight}" text-anchor="{anchor}" '
        f'letter-spacing="{ls}" opacity="{opacity}">{esc(s)}</text>')


def lines(x, y, arr, size=12, fill=MUTED, lh=17, weight="400", anchor="start",
          family=FONT):
    for i, s in enumerate(arr):
        text(x, y + i * lh, s, size=size, fill=fill, weight=weight,
             anchor=anchor, family=family)


def badge(x, y, label, fg, bg, w=None, border=None):
    if w is None:
        w = 12 + len(label) * 7.2
    rect(x, y, w, 22, fill=bg, stroke=(border or bg), sw=1, rx=11)
    text(x + w / 2, y + 15, label, size=10.5, fill=fg, weight="600",
         anchor="middle")


def arrow(pts, color=FAINT, sw=2, dash=None, head="arrow-gray"):
    d = "M " + " L ".join(f"{x},{y}" for x, y in pts)
    da = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}"{da} '
        f'stroke-linecap="round" stroke-linejoin="round" marker-end="url(#{head})"/>')


def curve(x1, y1, x2, y2, color=FAINT, sw=2, dash=None, head="arrow-gray"):
    mx = (x1 + x2) / 2
    d = f"M {x1},{y1} C {mx},{y1} {mx},{y2} {x2},{y2}"
    da = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}"{da} '
        f'stroke-linecap="round" marker-end="url(#{head})"/>')


def head(x, y, title, sub=None, color=INK):
    text(x, y, title, size=17, fill=color, weight="700")
    if sub:
        text(x, y + 19, sub, size=11.5, fill=MUTED)


# ----------------------------------------------------------------------------
# defs
# ----------------------------------------------------------------------------
add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    f'viewBox="0 0 {W} {H}" role="img">')
add('<title>安全 AI Agent Runtime 架构</title>')
add('<desc>既有容器平台 + LDAP/Keycloak OIDC + OpenShell 多租户运行时 + Tetragon + OTel 数据底座</desc>')
add('<defs>')
for name, col in [("arrow-gray", FAINT), ("arrow-teal", TEAL_M),
                  ("arrow-blue", BLUE), ("arrow-amber", AMBER),
                  ("arrow-green", GREEN)]:
    add(f'<marker id="{name}" viewBox="0 0 10 10" refX="9" refY="5" '
        f'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
        f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{col}"/></marker>')
add('</defs>')

rect(0, 0, W, H, fill=WHITE)
rect(0, 0, 8, H, fill=TEAL_M)

# ----------------------------------------------------------------------------
# header
# ----------------------------------------------------------------------------
text(60, 56, "AISANBOX-INSKE  ·  多租户 AI AGENT 平台  ·  2026-11",
     size=12, fill=TEAL, weight="700", ls=1.2)
text(60, 100, "安全 AI Agent Runtime 架构", size=44, fill=INK, weight="700")
text(60, 140,
     "既有容器平台之上，叠加 OpenShell 执行面、Tetragon 内核监测与 OTel 统一遥测",
     size=18, fill=MUTED)
text(1860, 60, "三轮 POC 实测  ·  49/49 身份与隔离矩阵",
     size=12, fill=FAINT, anchor="end")
rect(60, 168, 1800, 1, fill=LINE)

# ----------------------------------------------------------------------------
# 1) identity
# ----------------------------------------------------------------------------
text(60, 196, "① 身份与授权", size=14, fill=TEAL, weight="700", ls=0.8)
text(1860, 196, "LDAP 是唯一事实源，Keycloak 只做 OIDC 中继", size=12,
     fill=FAINT, anchor="end")

# LDAP
rect(60, 214, 240, 104, fill=WHITE, stroke=LINE, rx=10)
text(76, 240, "自研 LDAP", size=16.5, fill=INK, weight="700")
lines(76, 262, ["tenant-a / tenant-b", "tenant = departmentNumber",
                "groups = groupOfNames"], size=11.5, fill=MUTED, lh=16)
text(76, 306, "sub = entryUUID", size=11, fill=TEAL, family=MONO, weight="600")

# Keycloak
rect(340, 214, 300, 104, fill=TEAL_L, stroke=TEAL_M, rx=10)
text(356, 240, "Keycloak · OIDC 中继", size=16.5, fill=TEAL, weight="700")
lines(356, 262, ["User Federation · READ_ONLY",
                 "issuer: …/realms/aisanbox（唯一）",
                 "claims: sub / tenant / groups / aud"], size=11.5, fill=TEAL, lh=16)

# JWT
rect(680, 214, 420, 104, fill=WHITE, stroke=INK, sw=1.4, rx=10)
text(696, 240, "同一个 JWT", size=16.5, fill=INK, weight="700")
text(696, 263, "sub = entryUUID · tenant · groups（顶层扁平） · aud",
     size=11.5, fill=INK2, family=FONT)
text(696, 285, "aud = openshell-cli", size=11, fill=MUTED, family=MONO)
text(696, 306, "apiserver 与 Gateway 各取所需", size=10.2, fill=BLUE, weight="600")

# note
rect(1140, 214, 720, 104, fill=SOFT, stroke="none", rx=10)
text(1160, 240, "两侧一致性 = 同一个 claim，不是配置巧合", size=13,
     fill=INK, weight="700")
lines(1160, 264, [
    "kube-apiserver：--oidc-groups-claim=groups（只读顶层，嵌套会静默失效）",
    "OpenShell Gateway：roles_claim = \"groups\" · adminRole=os-admin · userRole=os-user"],
      size=11.5, fill=MUTED, lh=18)
text(1160, 304, "→ sub / groups 在两侧逐字相同，这是跨系统一致性的判据",
     size=10.8, fill=TEAL, weight="600")

arrow([(300, 266), (340, 266)], color=FAINT, sw=2)
arrow([(640, 266), (680, 266)], color=FAINT, sw=2)

# OIDC bus
add(f'<path d="M 890,318 L 890,340 L 390,340 L 390,408" fill="none" '
    f'stroke="{BLUE}" stroke-width="2" stroke-linejoin="round" '
    f'marker-end="url(#arrow-blue)"/>')
add(f'<path d="M 890,340 L 736,340 L 736,475 L 764,475" fill="none" '
    f'stroke="{BLUE}" stroke-width="2" stroke-linejoin="round" '
    f'marker-end="url(#arrow-blue)"/>')
add(f'<path d="M 890,340 L 1288,340 L 1288,475 L 1322,475" fill="none" '
    f'stroke="{BLUE}" stroke-width="2" stroke-linejoin="round" '
    f'marker-end="url(#arrow-blue)"/>')
text(600, 332, "OIDC · 同一个 issuer / audience", size=10.5, fill=BLUE,
     weight="600")

# ----------------------------------------------------------------------------
# 2) kubernetes control plane
# ----------------------------------------------------------------------------
text(680, 368, "② 容器平台控制面", size=14, fill=BLUE, weight="700",
     anchor="end", ls=0.8)
rect(60, 386, 620, 404, fill=PANEL, stroke="#E5EBF3", rx=16)

# apiserver
rect(84, 408, 572, 92, fill=WHITE, stroke=BLUE, sw=1.2, rx=10)
text(100, 432, "kube-apiserver", size=16.5, fill=INK, weight="700")
lines(100, 456, [
    "认证：OIDC（新增） / webhook → 自研 LDAP（存量）",
    "授权：RBAC 按租户 namespace；--oidc-required-claim=aud=openshell-cli"],
      size=11.5, fill=MUTED, lh=17)
badge(500, 416, "OIDC 实测", GREEN, GREEN_L, w=86)

# gatekeeper
rect(84, 520, 264, 76, fill=WHITE, stroke=LINE, rx=8)
text(100, 542, "Gatekeeper", size=14.5, fill=INK, weight="700")
lines(100, 562, ["准入：privileged / hostNetwork", "hostPID / hostPath / 借用 SA"],
      size=10.8, fill=MUTED, lh=15)
arrow([(216, 500), (216, 520)], color=BLUE, sw=1.6, head="arrow-blue")
text(228, 514, "AdmissionReview", size=9.5, fill=BLUE)

# capsule
rect(84, 612, 264, 76, fill=WHITE, stroke=LINE, rx=8)
text(100, 634, "Capsule", size=14.5, fill=INK, weight="700")
lines(100, 654, ["Tenant · 多 namespace", "配额 · 租户网络策略下发"],
      size=10.8, fill=MUTED, lh=15)

# antrea
rect(84, 704, 264, 76, fill=WHITE, stroke=LINE, rx=8)
text(100, 726, "Antrea", size=14.5, fill=INK, weight="700")
lines(100, 746, ["NetworkPolicy 执行", "跨节点 · OVS 流表可见"],
      size=10.8, fill=MUTED, lh=15)

# right column notes
text(372, 526, "拒绝不安全 Pod", size=12, fill=BLUE, weight="600")
lines(372, 546, ["同一 ns 内按身份区分，", "无 ns 级豁免"], size=10.8,
      fill=MUTED, lh=15)
arrow([(348, 558), (368, 558)], color=FAINT, sw=1.4)

text(372, 618, "租户 namespace", size=12, fill=TEAL, weight="600")
lines(372, 638, ["tenant-a-gateway / tenant-a-runtime",
                 "tenant-b-gateway / tenant-b-runtime"],
      size=10.2, fill=INK2, lh=15, family=MONO)
text(372, 680, "归属 · 配额 · networkPolicies", size=10.2, fill=FAINT)
arrow([(348, 650), (368, 650)], color=FAINT, sw=1.4)

text(372, 710, "L4 微分段", size=12, fill=GREEN, weight="600")
lines(372, 730, ["跨租户 BLOCKED（正对照 REACHED）", "沙箱仅到自己的 supervisor:5500"],
      size=10.2, fill=MUTED, lh=15)
arrow([(348, 742), (368, 742)], color=FAINT, sw=1.4)

# ----------------------------------------------------------------------------
# 3) openshell runtime
# ----------------------------------------------------------------------------
text(1860, 368, "③ OpenShell 多租户运行时", size=14, fill=TEAL, weight="700",
     anchor="end", ls=0.8)
rect(720, 386, 1140, 404, fill=PANEL, stroke="#E5EBF3", rx=16)

for lane_x, tag, tenant, ws, sb, sub in [
        (744, "Tenant A", "tenant-a", "ws-tenant-a", "ws-tenant-a--pi-dev", "pi-dev"),
        (1302, "Tenant B", "tenant-b", "ws-tenant-b", "ws-tenant-b--agent-b", "agent-b")]:
    rect(lane_x, 408, 536, 362, fill=WHITE, stroke=LINE, rx=12)
    text(lane_x + 20, 432, tag, size=13, fill=INK, weight="700")
    text(lane_x + 92, 432, "· 独立 Gateway", size=9.8, fill=FAINT)

    # gateway
    rect(lane_x + 20, 444, 236, 62, fill=WHITE, stroke=TEAL_M, sw=1.2, rx=8)
    text(lane_x + 34, 466, f"Gateway · {tenant}", size=13.5, fill=INK, weight="700")
    text(lane_x + 34, 486, "OIDC · StatefulSet · SQLite", size=10.3, fill=MUTED)
    text(lane_x + 224, 466, "†", size=12, fill=AMBER, weight="700", anchor="end")

    # workspace
    rect(lane_x + 276, 444, 240, 62, fill=TEAL_L, stroke="none", rx=8)
    text(lane_x + 290, 466, f"Workspace {ws}", size=12.8, fill=TEAL, weight="700")
    text(lane_x + 290, 486, "成员按 subject · os-admin / os-user", size=9.8, fill=TEAL)
    arrow([(lane_x + 256, 475), (lane_x + 276, 475)], color=TEAL_M, sw=1.5,
          head="arrow-teal")

    # sandbox
    rect(lane_x + 20, 524, 496, 228, fill=SOFT, stroke="#E5EBF3", rx=10)
    text(lane_x + 34, 546, f"Sandbox  {sb}", size=11.5, fill=INK, weight="700",
         family=MONO)
    text(lane_x + 34, 564, "Sandbox CR · supervisor + workload · 2 Service + 1 PVC",
         size=9.8, fill=FAINT)

    # pods
    rect(lane_x + 34, 576, 222, 78, fill=WHITE, stroke=TEAL_M, rx=8)
    text(lane_x + 46, 596, "supervisor", size=12, fill=TEAL, weight="700")
    lines(lane_x + 46, 614, ["128Mi · :5500", "OTLP relay · OCSF"], size=9.4,
          fill=MUTED, lh=13)

    rect(lane_x + 272, 576, 230, 78, fill=WHITE, stroke=AMBER, rx=8)
    text(lane_x + 284, 596, "workload (agent)", size=12, fill=AMBER, weight="700")
    lines(lane_x + 284, 614, ["uid 10001 · 1Gi", "凭据只有占位符"], size=9.4,
          fill=MUTED, lh=13)
    arrow([(lane_x + 272, 615), (lane_x + 256, 615)], color=AMBER, sw=1.4,
          head="arrow-amber")

    # sandbox foot
    rect(lane_x + 34, 672, 150, 24, fill=WHITE, stroke=LINE, rx=6)
    text(lane_x + 109, 688, "2× Service", size=9.4, fill=MUTED, anchor="middle")
    rect(lane_x + 192, 672, 108, 24, fill=WHITE, stroke=LINE, rx=6)
    text(lane_x + 246, 688, "1× PVC", size=9.4, fill=MUTED, anchor="middle")
    rect(lane_x + 308, 672, 194, 24, fill=WHITE, stroke=LINE, rx=6)
    text(lane_x + 405, 688, "NetworkPolicy", size=9.4, fill=MUTED, anchor="middle")

    text(lane_x + 34, 722, "出网全 deny，仅放行本 pair 的 supervisor:5500",
         size=10.2, fill=GREEN, weight="600")
    text(lane_x + 34, 740, "配额：每沙箱 2 Service + 1 PVC + ≈1.15Gi requests",
         size=9.6, fill=FAINT)


# ----------------------------------------------------------------------------
# 4) telemetry / security data plane
# ----------------------------------------------------------------------------
rect(48, 824, 1824, 194, fill="#F8FAFD", stroke="#E4EAF4", rx=16, dash="6 4")
text(68, 848, "④ 安全与遥测数据底座", size=13, fill=TEAL, weight="700", ls=0.8)
text(1600, 848, "统一信号：trace · OCSF · 内核 · audit · 身份",
     size=10.5, fill=FAINT, anchor="end")

# tetragon
rect(68, 862, 340, 138, fill=WHITE, stroke=AMBER, sw=1.2, rx=10)
text(84, 886, "Tetragon · eBPF", size=15, fill=INK, weight="700")
badge(300, 870, "观测实测 · 强制部分", AMBER, AMBER_L, w=100)
lines(84, 910, ["exec / exit / connect / parent", "pod · ns · uid · 五元组",
                "宿主 LSM 需含 bpf（本环境无）"], size=10.6, fill=MUTED, lh=16)
text(84, 958, "覆盖 supervisor + workload", size=10.2, fill=TEAL, weight="600")
text(84, 980, "不依赖 Agent 自报", size=10.2, fill=AMBER, weight="600")

# collector
rect(448, 862, 390, 138, fill=WHITE, stroke=LINE, rx=10)
text(464, 886, "OTel Collector", size=15, fill=INK, weight="700")
lines(464, 908, ["receivers：otlp · file_log(Tetragon)", "processors：batch · k8s_attributes",
                 "traces → Jaeger / Tempo", "logs → OCSF + 内核事件"], size=10.2,
      fill=MUTED, lh=15.5)
badge(700, 870, "统一接入点", TEAL, TEAL_L, w=84, border=TEAL_M)

# backends
rect(868, 862, 410, 138, fill=WHITE, stroke=LINE, rx=10)
text(884, 886, "观测后端与下游", size=15, fill=INK, weight="700")
lines(884, 910, ["Jaeger 1.69 · 脚本断言 /api/traces", "Tempo + Grafana · 演示与时间线",
                 "SIEM · OCSF 原生字段可直接映射"], size=10.4, fill=MUTED, lh=17)
text(884, 976, "Jaeger 为内存存储 → 生产需持久化", size=9.6, fill=AMBER)

# AI agent
rect(1308, 862, 542, 138, fill=INK, stroke=INK, rx=10)
text(1326, 888, "安全 AI Agent Runtime", size=15, fill=WHITE, weight="700")
text(1326, 910, "检测 → 调查 → 处置", size=10.8, fill=TEAL_M, weight="600")
badge(1326, 922, "L0 已交付", GREEN, "#173326", w=78, border=GREEN)
badge(1410, 922, "L1 部分", TEAL, "#12333A", w=74, border=TEAL_M)
badge(1490, 922, "L2 可构建", AMBER, "#3A2A12", w=80, border=AMBER)
badge(1576, 922, "L3 未实现", MUTED, "#2A3444", w=82, border=MUTED)
text(1326, 970, "关联主键 sandbox.id · 输出：一条可回溯的时间线", size=9.8, fill="#A9B7CB")

# arrows in telemetry
arrow([(408, 930), (448, 930)], color=FAINT, sw=1.8)
text(414, 922, "filelog", size=9, fill=FAINT)

arrow([(838, 930), (868, 930)], color=FAINT, sw=1.8)
arrow([(1278, 930), (1308, 930)], color=TEAL_M, sw=1.8, head="arrow-teal")

# runtime -> collector (traces + OCSF)
arrow([(980, 790), (700, 862)], color=TEAL_M, sw=1.6, head="arrow-teal")
arrow([(1540, 790), (780, 862)], color=TEAL_M, sw=1.6, head="arrow-teal")
text(760, 812, "OTLP traces + OCSF", size=9.6, fill=TEAL)

# L3 action (dashed, not implemented)
arrow([(1820, 862), (1820, 792)], color=AMBER, sw=1.5, dash="5 4", head="arrow-amber")
text(1808, 814, "L3 处置（未实现）", size=9.4, fill=AMBER, anchor="end")

# ----------------------------------------------------------------------------
# footer
# ----------------------------------------------------------------------------
text(60, 1044,
     "* webhook 与 OIDC 共存未在本 POC 实测；POC3 只验证 OIDC 路径。",
     size=10.5, fill=FAINT)
text(60, 1064,
     "† 每租户 Gateway + OIDC 待合并验证：POC2 验独立 Gateway + mTLS；POC3 验单 Gateway + 双 Workspace。",
     size=10.5, fill=FAINT)
text(1860, 1064,
     "实线 = 已实测   ·   虚线 = 设计 / 待验证   ·   绿 = 通过   ·   琥珀 = 部分",
     size=10.5, fill=FAINT, anchor="end")

add("</svg>")

svg = "\n".join(out)
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "architecture.svg"), "w", encoding="utf-8") as f:
    f.write(svg)
with open(os.path.join(here, "architecture.html"), "w", encoding="utf-8") as f:
    f.write("<!doctype html><html><head><meta charset='utf-8'>"
            "<style>html,body{margin:0;padding:0;background:#fff}"
            "svg{display:block}</style></head><body>" + svg + "</body></html>")
print("saved architecture.svg", len(svg), "bytes")
