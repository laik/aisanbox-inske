#!/usr/bin/env python3
"""Build the POC summary deck (16:9, zh-CN).

Run:  python3 deliverables/build_deck.py
Out:  deliverables/aisanbox-security-ai-runtime-poc.pptx

Design: flat "security console" look.  White content slides, dark cover/end.
All colours / type sizes live in this file so the deck can be regenerated.
"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR, MSO_AUTO_SIZE
from pptx.enum.shapes import MSO_SHAPE, MSO_CONNECTOR
from pptx.enum.dml import MSO_LINE_DASH_STYLE
from pptx.oxml.ns import qn
from lxml import etree
import os

# ----------------------------------------------------------------------------
# palette / type
# ----------------------------------------------------------------------------
INK      = RGBColor(0x0B, 0x12, 0x20)
INK2     = RGBColor(0x1E, 0x29, 0x3B)
MUTED    = RGBColor(0x5B, 0x6B, 0x82)
FAINT    = RGBColor(0x8A, 0x99, 0xAE)
LINE     = RGBColor(0xDC, 0xE3, 0xEE)
SOFT     = RGBColor(0xF4, 0xF7, 0xFB)
WHITE    = RGBColor(0xFF, 0xFF, 0xFF)

TEAL     = RGBColor(0x0F, 0x76, 0x6E)
TEAL_M   = RGBColor(0x14, 0xB8, 0xA6)
TEAL_L   = RGBColor(0xE7, 0xF5, 0xF2)
BLUE     = RGBColor(0x1D, 0x4E, 0xD8)
BLUE_L   = RGBColor(0xE8, 0xEF, 0xFD)
AMBER    = RGBColor(0xB4, 0x53, 0x09)
AMBER_L  = RGBColor(0xFE, 0xF3, 0xC7)
RED      = RGBColor(0xB9, 0x1C, 0x1C)
RED_L    = RGBColor(0xFE, 0xE2, 0xE2)
GREEN    = RGBColor(0x15, 0x80, 0x3D)
GREEN_L  = RGBColor(0xDC, 0xFC, 0xE7)

DARK_BG  = RGBColor(0x0A, 0x11, 0x1F)
DARK_PNL = RGBColor(0x12, 0x1D, 0x30)
DARK_TX  = RGBColor(0xE6, 0xED, 0xF6)
DARK_MUT = RGBColor(0x94, 0xA3, 0xB8)

EA    = "Hiragino Sans GB"
LATIN = "Arial"
MONO  = "Menlo"

W, H = 13.333, 7.5
M    = 0.72
CW   = W - 2 * M

prs = Presentation()
prs.slide_width  = Inches(W)
prs.slide_height = Inches(H)
BLANK = prs.slide_layouts[6]


# ----------------------------------------------------------------------------
# primitives
# ----------------------------------------------------------------------------
def set_run(run, size, color, bold=False, italic=False,
            latin=LATIN, ea=EA):
    f = run.font
    f.size = Pt(size)
    f.bold = bold
    f.italic = italic
    f.name = latin
    f.color.rgb = color
    rPr = run._r.get_or_add_rPr()
    for tag in ("a:ea", "a:cs"):
        for el in rPr.findall(qn(tag)):
            rPr.remove(el)
    eael = etree.SubElement(rPr, qn("a:ea"))
    eael.set("typeface", ea)
    csel = etree.SubElement(rPr, qn("a:cs"))
    csel.set("typeface", ea)


def _runs(p, content, size, color, bold, italic=False, latin=LATIN, ea=EA):
    if isinstance(content, str):
        runs = [(content, {})]
    else:
        runs = content
    for txt, ov in runs:
        r = p.add_run()
        r.text = txt
        set_run(r, ov.get("size", size), ov.get("color", color),
                ov.get("bold", bold), ov.get("italic", italic),
                ov.get("latin", latin), ov.get("ea", ea))


def text(slide, x, y, w, h, content, size=14, color=INK2, bold=False,
         align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, line=1.22,
         space_after=0, space_before=0, margins=(0, 0, 0, 0),
         italic=False, latin=LATIN, ea=EA):
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.auto_size = MSO_AUTO_SIZE.NONE
    tf.margin_left, tf.margin_right, tf.margin_top, tf.margin_bottom = [
        Inches(v) for v in margins]
    tf.vertical_anchor = anchor
    items = content if isinstance(content, list) else [content]
    for i, item in enumerate(items):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.line_spacing = line
        p.space_after = Pt(space_after)
        p.space_before = Pt(space_before)
        _runs(p, item, size, color, bold, italic, latin, ea)
    return tb


def _bullet(p, char, color, indent=0.19):
    pPr = p._p.get_or_add_pPr()
    pPr.set("marL", str(int(Inches(indent))))
    pPr.set("indent", str(-int(Inches(indent))))
    buClr = etree.SubElement(pPr, qn("a:buClr"))
    c = etree.SubElement(buClr, qn("a:srgbClr"))
    c.set("val", "%02X%02X%02X" % (color[0], color[1], color[2]))
    buFont = etree.SubElement(pPr, qn("a:buFont"))
    buFont.set("typeface", "Arial")
    buChar = etree.SubElement(pPr, qn("a:buChar"))
    buChar.set("char", char)


def bullet_list(slide, x, y, w, h, items, size=13.5, color=INK2,
                gap=8, line=1.28, marker="▸", mcolor=TEAL, indent=0.19):
    tb = text(slide, x, y, w, h, "", size=size, color=color, line=line)
    tf = tb.text_frame
    for i, item in enumerate(items):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.line_spacing = line
        p.space_after = Pt(gap)
        _runs(p, item, size, color, False)
        _bullet(p, marker, mcolor, indent)
    return tb


def rect(slide, x, y, w, h, fill=None, line=None, lw=1.0, radius=None,
         dash=None):
    shp_type = MSO_SHAPE.ROUNDED_RECTANGLE if radius is not None else MSO_SHAPE.RECTANGLE
    shp = slide.shapes.add_shape(shp_type, Inches(x), Inches(y), Inches(w), Inches(h))
    if radius is not None:
        try:
            shp.adjustments[0] = radius
        except Exception:
            pass
    if fill is None:
        shp.fill.background()
    else:
        shp.fill.solid()
        shp.fill.fore_color.rgb = fill
    if line is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line
        shp.line.width = Pt(lw)
        if dash:
            shp.line.dash_style = dash
    shp.shadow.inherit = False
    if shp.has_text_frame:
        shp.text_frame.text = ""
    return shp


def circle(slide, x, y, d, fill, line=None, lw=1.0):
    shp = slide.shapes.add_shape(MSO_SHAPE.OVAL, Inches(x), Inches(y), Inches(d), Inches(d))
    shp.fill.solid()
    shp.fill.fore_color.rgb = fill
    if line is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line
        shp.line.width = Pt(lw)
    shp.shadow.inherit = False
    return shp


def arrow(slide, x1, y1, x2, y2, color=FAINT, lw=1.5, dash=None, head="tail"):
    conn = slide.shapes.add_connector(MSO_CONNECTOR.STRAIGHT,
                                      Inches(x1), Inches(y1), Inches(x2), Inches(y2))
    conn.line.color.rgb = color
    conn.line.width = Pt(lw)
    if dash:
        conn.line.dash_style = dash
    ln = conn.line._get_or_add_ln()
    end = etree.SubElement(ln, qn("a:%sEnd" % head))
    end.set("type", "triangle")
    end.set("w", "med")
    end.set("len", "med")
    return conn


def chip(slide, x, y, w, h, label, fill, color, size=10, bold=True,
         line=None):
    rect(slide, x, y, w, h, fill=fill, line=line, lw=0.75, radius=0.5)
    text(slide, x, y, w, h, label, size=size, color=color, bold=bold,
         align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    return


def add_notes(slide, body):
    slide.notes_slide.notes_text_frame.text = body


def new_slide(bg=WHITE):
    s = prs.slides.add_slide(BLANK)
    fill = s.background.fill
    fill.solid()
    fill.fore_color.rgb = bg
    return s


def header(slide, kicker, title, num=None, dark=False):
    kc = TEAL_M if dark else TEAL
    text(slide, M, 0.46, CW - 1.0, 0.26, kicker, size=10, color=kc, bold=True,
         latin="Arial")
    text(slide, M, 0.78, CW, 0.72, title, size=26, color=(DARK_TX if dark else INK),
         bold=True, line=1.05)
    rect(slide, M, 1.66, 0.86, 0.045, fill=kc)
    rect(slide, M + 0.86, 1.66, CW - 0.86, 0.045, fill=(DARK_PNL if dark else LINE))


def footer(slide, num, dark=False):
    c = DARK_MUT if dark else FAINT
    rect(slide, M, 7.02, CW, 0.012, fill=(DARK_PNL if dark else LINE))
    text(slide, M, 7.08, 8.0, 0.24,
         "aisanbox-inske  ·  多租户安全 AI Agent Runtime  ·  POC 总结", size=8.5, color=c)
    text(slide, W - M - 1.2, 7.08, 1.2, 0.24, "%02d" % num, size=8.5, color=c,
         align=PP_ALIGN.RIGHT)


# ----------------------------------------------------------------------------
# table helper
# ----------------------------------------------------------------------------
def table(slide, x, y, w, col_widths, rows, row_heights=None, size=10.5,
          head_size=10, head_fill=INK, head_color=WHITE, zebra=SOFT,
          first_col_color=INK, align=None, pad=0.09):
    nrows, ncols = len(rows), len(rows[0])
    total_h = sum(row_heights) if row_heights else 0.4 * nrows
    gf = slide.shapes.add_table(nrows, ncols, Inches(x), Inches(y),
                                Inches(w), Inches(total_h))
    tbl = gf.table
    tbl.first_row = True
    tbl.horz_banding = False
    tbl.vert_banding = False
    for i, cw in enumerate(col_widths):
        tbl.columns[i].width = Inches(cw)
    if row_heights:
        for i, rh in enumerate(row_heights):
            tbl.rows[i].height = Inches(rh)
    for r in range(nrows):
        for c in range(ncols):
            cell = tbl.cell(r, c)
            cell.margin_left = Inches(pad)
            cell.margin_right = Inches(pad)
            cell.margin_top = Inches(0.045)
            cell.margin_bottom = Inches(0.045)
            cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            cell.fill.solid()
            if r == 0:
                cell.fill.fore_color.rgb = head_fill
            else:
                cell.fill.fore_color.rgb = WHITE if r % 2 else zebra
            tf = cell.text_frame
            tf.word_wrap = True
            p = tf.paragraphs[0]
            p.alignment = (align[c] if align else (PP_ALIGN.LEFT if c == 0 else PP_ALIGN.LEFT))
            p.line_spacing = 1.05
            val = rows[r][c]
            if isinstance(val, str):
                runs = [(val, {})]
            else:
                runs = val
            for txt, ov in runs:
                run = p.add_run()
                run.text = txt
                if r == 0:
                    set_run(run, ov.get("size", head_size), head_color, True)
                else:
                    set_run(run, ov.get("size", size),
                            ov.get("color", first_col_color if c == 0 else INK2),
                            ov.get("bold", c == 0))
    return gf


# ============================================================================
# 01 — cover
# ============================================================================
def s_cover():
    s = new_slide(DARK_BG)
    # faint grid
    for gx in [i * 0.9 for i in range(1, 15)]:
        rect(s, gx, 0, 0.006, H, fill=RGBColor(0x14, 0x20, 0x33))
    for gy in [i * 0.9 for i in range(1, 9)]:
        rect(s, 0, gy, W, 0.006, fill=RGBColor(0x14, 0x20, 0x33))
    # accent block
    rect(s, 0, 0, 0.10, H, fill=TEAL_M)
    rect(s, M, 1.02, 0.34, 0.05, fill=TEAL_M)

    text(s, M, 1.14, 8.0, 0.3, "AISANBOX-INSKE  /  三轮 POC 实证  /  2026-11",
         size=10.5, color=TEAL_M, bold=True)
    text(s, M, 1.95, 11.6, 1.35, "多租户安全 AI Agent Runtime",
         size=46, color=WHITE, bold=True, line=1.02)
    text(s, M, 3.28, 10.4, 0.95,
         "在既有容器平台之上，叠加 OpenShell 执行面、Tetragon 内核监测与 OTel 统一遥测",
         size=17.5, color=DARK_MUT, line=1.35)

    stats = [("3", "轮 POC / 11 能力项 / 14 安全用例"),
             ("49/49", "身份与隔离矩阵 PASS"),
             ("1", "条 sandbox.id 关联三条证据流")]
    x = M
    for big, small in stats:
        text(s, x, 4.72, 3.5, 0.55, big, size=25, color=TEAL_M, bold=True)
        text(s, x, 5.26, 3.5, 0.3, small, size=9.5, color=DARK_MUT)
        x += 3.65

    rect(s, M, 6.24, CW, 0.012, fill=RGBColor(0x26, 0x33, 0x49))
    text(s, M, 6.4, 7.2, 0.3,
         "Kubernetes v1.37  ·  OpenShell 0.1.7  ·  Tetragon 1.8  ·  Keycloak 26.4",
         size=9.5, color=DARK_MUT)
    text(s, W - M - 2.6, 6.4, 2.6, 0.3, "结论可复验 · 边界可解释", size=9.5,
         color=TEAL_M, align=PP_ALIGN.RIGHT)
    add_notes(s, "开场：这不是组件拼装，而是在既有容器平台之上补一层 AI Agent 执行面。"
                 "三个数字先立住：三轮 POC、49/49 身份矩阵、以及一个 sandbox.id 能把三类证据串起来。"
                 "后面每一页都对应仓库里可复验的命令或原始输出。")


# ============================================================================
# 02 — executive summary
# ============================================================================
def s_summary():
    s = new_slide()
    header(s, "01 / 执行摘要", "底座不换，给 Agent 加一层“可管、可证、可追”的执行面", "02")
    cards = [
        ("身份一条链", ["LDAP 是唯一事实源，Keycloak 只做中继；", "同一个 JWT 被 apiserver 与每租户 Gateway 消费。"], "POC3 · 49/49", TEAL, TEAL_L),
        ("隔离四层", ["Capsule 租户与配额 / Antrea 网络 / Gatekeeper 准入 /", "OpenShell 文件·出口·凭据。每层都能指出“是谁拒的”。"], "POC-02/05/06 · SEC", BLUE, BLUE_L),
        ("证据一条线", ["sandbox.id 串起 trace、OCSF 与 Tetragon 内核事件；", "同一次 curl 可以在同一秒对齐。"], "POC-11 · 三条流", AMBER, AMBER_L),
    ]
    x = M
    for title, body, ev, c, cl in cards:
        rect(s, x, 1.96, 3.82, 2.62, fill=WHITE, line=LINE, lw=1.0, radius=0.06)
        rect(s, x, 1.96, 3.82, 0.06, fill=c)
        text(s, x + 0.24, 2.18, 3.35, 0.32, title, size=16, color=INK, bold=True)
        text(s, x + 0.24, 2.62, 3.36, 1.22, body, size=11.2, color=MUTED, line=1.4)
        chip(s, x + 0.24, 3.98, 1.62, 0.3, ev, cl, c, size=8.8)
        x += 4.04

    rect(s, M, 4.86, CW, 1.52, fill=SOFT, line=None, radius=0.05)
    rect(s, M, 4.86, 0.06, 1.52, fill=AMBER)
    text(s, M + 0.26, 5.0, 5.2, 0.28, "必须先解决的两个生产缺口", size=11, color=AMBER, bold=True)
    bullet_list(s, M + 0.26, 5.33, 5.35, 1.35, [
        "目录变更不会自动进 token：Keycloak 26.4 没有可用的 sync 端点",
        "Workspace 成员不随目录组走：需“目录组 → 成员”同步控制器",
    ], size=10.8, color=INK2, gap=5, line=1.3, mcolor=AMBER, indent=0.17)
    text(s, M + 5.95, 5.0, 5.6, 0.28, "必须写进交付前提的一条", size=11, color=RED, bold=True)
    bullet_list(s, M + 5.95, 5.33, 5.55, 1.35, [
        "Tetragon 强制依赖宿主 LSM 含 bpf；本环境没有，只能观测",
        "观测后端仍是内存存储：结论可复验，长期取证要换后端",
    ], size=10.8, color=INK2, gap=5, line=1.3, mcolor=RED, indent=0.17)
    text(s, M, 6.52, CW, 0.3,
         "结论：组合可以承载多租户 Agent；生产化取决于两个同步器与一个可留存的后端。",
         size=10.5, color=INK, bold=True)
    footer(s, 2)
    add_notes(s, "三个结论对应三组证据：身份（POC3 的 49 条用例）、隔离（POC2 的 11 项能力 + 14 条安全用例）、"
                 "关联（POC-11）。下面一行的两个缺口和一条前提，是这份材料里最重要的“但是”。"
                 "不要在对外汇报时把它们藏起来——它们决定了生产化的先后顺序。")


# ============================================================================
# 03 — starting point
# ============================================================================
def s_start():
    s = new_slide()
    header(s, "02 / 起点", "已有平台解决“谁能在集群里做什么”，没解决“Agent 能做什么”", "03")

    text(s, M, 1.9, 5.7, 0.28, "既有能力（平台侧已验证）", size=11, color=TEAL, bold=True)
    rows = [
        ("kube-apiserver", "认证 webhook → 自研 LDAP", "租户身份与 RBAC 的入口"),
        ("Antrea", "NetworkPolicy 9/9", "进 Antrea 控制面与 OVS 流表"),
        ("Capsule", "Tenant / 多 namespace", "归属、配额、租户网络策略下发"),
        ("Gatekeeper", "准入约束", "privileged、hostNetwork、hostPID、hostPath 全拒"),
    ]
    y = 2.28
    for name, what, why in rows:
        rect(s, M, y, 5.72, 0.78, fill=SOFT, line=None, radius=0.05)
        text(s, M + 0.2, y + 0.12, 1.62, 0.26, name, size=10.5, color=INK, bold=True)
        text(s, M + 1.86, y + 0.1, 3.7, 0.26, what, size=10.2, color=INK2)
        text(s, M + 1.86, y + 0.39, 3.72, 0.26, why, size=8.8, color=MUTED)
        y += 0.9

    rect(s, M + 6.12, 1.9, 5.76, 4.42, fill=INK, line=None, radius=0.05)
    text(s, M + 6.38, 2.1, 5.2, 0.3, "Agent 引入的新问题", size=13, color=TEAL_M, bold=True)
    bullet_list(s, M + 6.38, 2.56, 5.2, 3.5, [
        [("任意代码", {"bold": True, "color": WHITE}), ("：文件系统写哪里、读哪里？", {"color": DARK_MUT})],
        [("任意出口", {"bold": True, "color": WHITE}), ("：能连哪些域名、谁批准？", {"color": DARK_MUT})],
        [("凭据", {"bold": True, "color": WHITE}), ("：怎么让 Agent 用得上、又读不到？", {"color": DARK_MUT})],
        [("多租户", {"bold": True, "color": WHITE}), ("：一个租户一套边界，还是共享？", {"color": DARK_MUT})],
        [("取证", {"bold": True, "color": WHITE}), ("：谁在何时 exec 了什么、连了哪里？", {"color": DARK_MUT})],
    ], size=12, color=DARK_MUT, gap=14, line=1.3, mcolor=TEAL_M, indent=0.22)
    rect(s, M + 6.38, 5.82, 5.2, 0.012, fill=RGBColor(0x2A, 0x38, 0x50))
    text(s, M + 6.38, 5.94, 5.2, 0.3,
         "平台不替 Agent 做决定，只负责让每个决定可被约束、可被记录。",
         size=8.8, color=TEAL_M)

    text(s, M, 6.52, CW, 0.3,
         "* webhook 认证链路由既有平台提供，本仓库不重复实现；本 POC 新增并验证的是 LDAP → Keycloak → OIDC 路径。",
         size=8.6, color=FAINT)
    footer(s, 3)
    add_notes(s, "先把起点说清楚：apiserver + webhook + LDAP 解决的是“人/服务在集群里的权限”，"
                 "Antrea/Capsule/Gatekeeper 是平台既有的三层控制。Agent 的问题不在这三层里——它要跑任意代码、"
                 "要出网、要用凭据、还要能被事后追责。右下五个问句就是后面每一页要回答的对象。")


# ============================================================================
# 04 — target architecture
# ============================================================================
def s_arch():
    s = new_slide()
    header(s, "03 / 目标架构", "一条身份链、两套控制面、三类遥测", "04")

    # identity band
    text(s, M, 1.82, 3.0, 0.24, "身份面", size=9, color=FAINT, bold=True)
    band_y = 2.06
    rect(s, M, band_y, 2.42, 1.08, fill=SOFT, line=LINE, radius=0.06)
    text(s, M + 0.16, band_y + 0.14, 2.1, 0.26, "自研 LDAP", size=11.5, color=INK, bold=True)
    text(s, M + 0.16, band_y + 0.46, 2.12, 0.5, "tenant / groups / entryUUID", size=8.6, color=MUTED, line=1.25)

    arrow(s, M + 2.42, band_y + 0.54, M + 2.86, band_y + 0.54)

    rect(s, M + 2.86, band_y, 2.62, 1.08, fill=TEAL_L, line=TEAL_M, radius=0.06)
    text(s, M + 3.0, band_y + 0.14, 2.35, 0.26, "Keycloak · OIDC 中继", size=11.5, color=TEAL, bold=True)
    text(s, M + 3.0, band_y + 0.46, 2.36, 0.5, "User Federation · 唯一 issuer", size=8.6, color=TEAL, line=1.25)

    arrow(s, M + 5.48, band_y + 0.54, M + 5.92, band_y + 0.54)

    rect(s, M + 5.92, band_y, 3.5, 1.08, fill=WHITE, line=INK, lw=1.0, radius=0.06)
    text(s, M + 6.06, band_y + 0.13, 3.25, 0.26, "同一个 JWT", size=11.5, color=INK, bold=True)
    text(s, M + 6.06, band_y + 0.44, 3.26, 0.52,
         "sub=entryUUID · tenant · groups（扁平） · aud", size=8.6, color=MUTED, line=1.25)

    text(s, M + 9.62, band_y + 0.12, 2.25, 0.9,
         ["两套控制面", "消费同一份声明"], size=10, color=FAINT, line=1.35)

    # consumers
    ky = 3.46
    text(s, M, ky - 0.24, 4.0, 0.22, "控制面", size=9, color=FAINT, bold=True)
    rect(s, M, ky, 5.86, 1.86, fill=WHITE, line=LINE, radius=0.05)
    rect(s, M, ky, 0.05, 1.86, fill=BLUE)
    text(s, M + 0.22, ky + 0.13, 5.5, 0.26, "Kubernetes 控制面", size=12, color=INK, bold=True)
    text(s, M + 0.22, ky + 0.47, 5.45, 0.26, "apiserver：OIDC 认证 + RBAC 按租户 ns 授权", size=9.2, color=MUTED)
    for i, (t, c) in enumerate([("Capsule", BLUE_L), ("Gatekeeper", BLUE_L), ("Antrea", BLUE_L)]):
        chip(s, M + 0.22 + i * 1.18, ky + 0.92, 1.06, 0.32, t, c, BLUE, size=8.8)
    text(s, M + 0.22, ky + 1.38, 5.4, 0.28, "配额 / 准入 / 网络策略", size=8.6, color=FAINT)

    rect(s, M + 6.07, ky, 5.82, 1.86, fill=WHITE, line=LINE, radius=0.05)
    rect(s, M + 6.07, ky, 0.05, 1.86, fill=TEAL)
    text(s, M + 6.29, ky + 0.13, 5.4, 0.26, "OpenShell 执行面", size=12, color=INK, bold=True)
    text(s, M + 6.29, ky + 0.47, 5.3, 0.26, "每租户 Gateway（OIDC）→ Workspace → Sandbox", size=9.2, color=MUTED)
    for i, t in enumerate(["supervisor", "workload", "PVC"]):
        chip(s, M + 6.29 + i * 1.2, ky + 0.92, 1.08, 0.32, t, TEAL_L, TEAL, size=8.8)
    text(s, M + 6.29, ky + 1.38, 5.3, 0.28, "文件 / 出口 / 凭据 三层边界", size=8.6, color=FAINT)

    # telemetry
    ty = 5.66
    text(s, M, ty - 0.24, 4.0, 0.22, "证据面", size=9, color=FAINT, bold=True)
    rect(s, M, ty, 2.72, 1.1, fill=AMBER_L, line=None, radius=0.05)
    text(s, M + 0.18, ty + 0.14, 2.4, 0.26, "Tetragon", size=11, color=AMBER, bold=True)
    text(s, M + 0.18, ty + 0.44, 2.38, 0.5, ["exec / connect / parent", "内核侧真相"], size=8.4, color=AMBER, line=1.2)

    rect(s, M + 3.02, ty, 3.1, 1.1, fill=SOFT, line=LINE, radius=0.05)
    text(s, M + 3.2, ty + 0.14, 2.8, 0.26, "OTel Collector", size=11, color=INK, bold=True)
    text(s, M + 3.2, ty + 0.44, 2.78, 0.5, ["traces + OCSF + kernel logs", "k8sattributes 补齐租户身份"], size=8.4, color=MUTED, line=1.2)

    rect(s, M + 6.42, ty, 2.55, 1.1, fill=SOFT, line=LINE, radius=0.05)
    text(s, M + 6.6, ty + 0.14, 2.3, 0.26, "Jaeger / Tempo", size=11, color=INK, bold=True)
    text(s, M + 6.6, ty + 0.44, 2.28, 0.5, ["断言用 Jaeger", "演示用 Tempo + Grafana"], size=8.4, color=MUTED, line=1.2)

    rect(s, M + 9.27, ty, 2.62, 1.1, fill=INK, line=None, radius=0.05)
    text(s, M + 9.45, ty + 0.14, 2.3, 0.26, "安全 AI Agent", size=11, color=TEAL_M, bold=True)
    text(s, M + 9.45, ty + 0.44, 2.28, 0.5, ["检测 · 调查 · 处置", "信号齐、可关联"], size=8.4, color=DARK_MUT, line=1.2)

    arrow(s, M + 3.74, ty + 0.55, M + 4.02, ty + 0.55, color=FAINT, lw=1.2)
    arrow(s, M + 6.12, ty + 0.55, M + 6.42, ty + 0.55, color=FAINT, lw=1.2)
    arrow(s, M + 8.97, ty + 0.55, M + 9.27, ty + 0.55, color=FAINT, lw=1.2)

    footer(s, 4)
    add_notes(s, "这页是整份材料的骨架。上面一条身份链：LDAP → Keycloak → 一个 JWT。中间两套控制面分别消费："
                 "K8s 用 OIDC+RBAC 管命名空间；OpenShell 用 OIDC+Workspace 管沙箱。下面三条证据流："
                 "Tetragon 给内核真相，Collector 做汇合，最后才是安全 AI Agent。注意：Agent 这一格是本轮交付的"
                 "数据底座，不是已经实现的 Agent。")


# ============================================================================
# 05 — identity
# ============================================================================
def s_identity():
    s = new_slide()
    header(s, "04 / 身份与授权", "一条 JWT，两侧消费：LDAP 是事实源，Keycloak 只是中继", "05")

    rows = [
        ["层", "关键配置", "实测值", "为什么是这个值"],
        ["LDAP 事实源", "departmentNumber / groupOfNames", "tenant-a / tenant-a-users, os-user",
         "租户与角色只存在于目录，两侧都没有手工副本"],
        ["Keycloak 联邦", "uuidLDAPAttribute", "entryUUID",
         "sub 稳定；否则每次重导入授权全断"],
        ["Claim 形状", "顶层扁平数组", "sub / tenant / groups / aud",
         "apiserver 只能读顶层；嵌套时 Groups 静默只剩 system:authenticated"],
        ["kube-apiserver", "OIDC + required-claim", "aud=openshell-cli",
         "v1.37 没有 --oidc-audience，用 required-claim 等效"],
        ["Gateway", "rolesClaim / adminRole", "groups / os-admin",
         "与 RBAC 同一套词表，避免“一致性靠巧合”"],
    ]
    table(s, M, 1.94, CW, [1.72, 3.02, 3.55, 3.6], rows,
          row_heights=[0.40, 0.66, 0.66, 0.78, 0.66, 0.66], size=9.6, head_size=9.2,
          first_col_color=TEAL)

    # bottom callout
    rect(s, M, 5.96, 7.4, 0.86, fill=AMBER_L, line=None, radius=0.05)
    rect(s, M, 5.96, 0.05, 0.86, fill=AMBER)
    text(s, M + 0.2, 6.06, 7.1, 0.26, "与既有 webhook 认证的关系", size=9.8, color=AMBER, bold=True)
    text(s, M + 0.2, 6.33, 7.05, 0.44,
         "可以并存，但 username 必须同源（entryUUID），否则同一人两条身份、RBAC 与 Workspace 对不上。POC3 只验了 OIDC 路径。",
         size=8.8, color=INK2, line=1.28)

    text(s, M + 7.62, 5.99, 4.26, 0.26, "三个“静默失败”陷阱", size=9.8, color=RED, bold=True)
    bullet_list(s, M + 7.62, 6.25, 4.25, 0.62, [
        "sub 用 Keycloak 本地 id → 重导入即变",
        "嵌套 claim → Groups 只剩 system:authenticated",
        "缺 required-claim → 同 issuer 其他 client 也放行",
    ], size=8.2, color=MUTED, gap=1.5, line=1.2, mcolor=RED, indent=0.14)

    footer(s, 5)
    add_notes(s, "这一页是配置决策，不是概念图。五个值里最容易被忽略的是 uuidLDAPAttribute=entryUUID："
                 "默认 sub 是 Keycloak 本地 id，删了重导入就变，RBAC 主体名会跟着断。"
                 "第二个是 groups 必须扁平：apiserver 的 --oidc-groups-claim 只读顶层，配成嵌套不报错，"
                 "只是 Groups 悄悄变成 system:authenticated。第三个是 aud：v1.37 没有 --oidc-audience，"
                 "必须用 required-claim。底部这条 webhook 共存是设计建议，本轮没有实测。")


# ============================================================================
# 06 — runtime model
# ============================================================================
def s_runtime():
    s = new_slide()
    header(s, "05 / 多租户运行时", "1 个租户 = 1 台 Gateway = 2 个 namespace = N 个 Sandbox", "06")

    # left: composition
    bx, by = M, 1.98
    rect(s, bx, by, 7.55, 4.72, fill=SOFT, line=None, radius=0.04)

    rect(s, bx + 0.24, by + 0.24, 2.0, 0.72, fill=INK, line=None, radius=0.06)
    text(s, bx + 0.36, by + 0.36, 1.8, 0.24, "Capsule Tenant", size=10.5, color=WHITE, bold=True)
    text(s, bx + 0.36, by + 0.62, 1.8, 0.22, "tenant-a", size=8.4, color=DARK_MUT)

    arrow(s, bx + 2.24, by + 0.6, bx + 2.56, by + 0.6)

    rect(s, bx + 2.56, by + 0.24, 2.1, 0.72, fill=WHITE, line=LINE, radius=0.06)
    text(s, bx + 2.68, by + 0.34, 1.9, 0.22, "tenant-a-gateway", size=9.6, color=INK, bold=True)
    text(s, bx + 2.68, by + 0.58, 1.9, 0.22, "Gateway · StatefulSet", size=8.2, color=MUTED)

    rect(s, bx + 4.9, by + 0.24, 2.4, 0.72, fill=WHITE, line=LINE, radius=0.06)
    text(s, bx + 5.02, by + 0.34, 2.2, 0.22, "tenant-a-runtime", size=9.6, color=INK, bold=True)
    text(s, bx + 5.02, by + 0.58, 2.2, 0.22, "Workspace · Sandbox", size=8.2, color=MUTED)
    arrow(s, bx + 4.66, by + 0.6, bx + 4.9, by + 0.6)

    # gateway detail
    rect(s, bx + 0.24, by + 1.22, 3.4, 1.1, fill=WHITE, line=LINE, radius=0.05)
    text(s, bx + 0.38, by + 1.32, 3.0, 0.24, "每租户独立", size=8.8, color=TEAL, bold=True)
    text(s, bx + 0.38, by + 1.56, 3.1, 0.72,
         ["gateway_id · SQLite PVC", "client-TLS（POC2） / OIDC（POC3）", "证书轮转要持续同步到 runtime ns"],
         size=8.4, color=MUTED, line=1.3)

    # workspace detail
    rect(s, bx + 3.86, by + 1.22, 3.44, 1.1, fill=TEAL_L, line=None, radius=0.05)
    text(s, bx + 4.0, by + 1.32, 3.1, 0.24, "Workspace = 资源隔离边界", size=8.8, color=TEAL, bold=True)
    text(s, bx + 4.0, by + 1.58, 3.15, 0.7,
         ["成员按 subject 显式绑定", "角色：os-admin / os-user", "跨 Workspace 不可见"], size=8.6, color=TEAL, line=1.3)

    # sandbox composition
    text(s, bx + 0.24, by + 2.58, 3.0, 0.24, "一个 Sandbox 的真实开销", size=8.8, color=AMBER, bold=True)
    parts = [("supervisor Pod", "128Mi"), ("workload Pod", "1Gi"), ("Service", "2 个"), ("PVC", "1 个")]
    for i, (nm, val) in enumerate(parts):
        px = bx + 0.24 + i * 1.78
        rect(s, px, by + 2.9, 1.64, 0.9, fill=WHITE, line=LINE, radius=0.05)
        text(s, px + 0.12, by + 3.0, 1.4, 0.22, nm, size=8.2, color=MUTED)
        text(s, px + 0.12, by + 3.26, 1.4, 0.3, val, size=13, color=INK, bold=True)

    text(s, bx + 0.24, by + 4.02, 7.0, 0.5,
         "名字是 {workspace}--{name}，不是 {name}；Completed 的沙箱仍占 2 Service + 1 PVC。",
         size=8.8, color=MUTED, line=1.3)

    # right stats
    rx = M + 7.85
    text(s, rx, 1.96, 3.9, 0.26, "实测数字", size=11, color=TEAL, bold=True)
    stats = [("3", "个 Sandbox 同一 Gateway 并发 Ready"),
             ("≈1.15Gi", "每个沙箱的 requests（1Gi + 128Mi）"),
             ("2 + 1", "每个沙箱 2 个 Service + 1 个 PVC"),
             ("49/49", "POC3 身份与隔离矩阵")]
    y = 2.3
    for big, small in stats:
        text(s, rx, y, 3.9, 0.4, big, size=21, color=INK, bold=True)
        text(s, rx, y + 0.4, 3.85, 0.36, small, size=8.8, color=MUTED, line=1.25)
        y += 0.98

    rect(s, rx, 6.18, 3.95, 0.66, fill=AMBER_L, line=None, radius=0.05)
    text(s, rx + 0.12, 6.24, 3.72, 0.56,
         "注意：POC2 验证“独立 Gateway + mTLS”，POC3 验证“OIDC + 两 Workspace”；合并形态还差一次验证。",
         size=7.8, color=AMBER, line=1.25)

    footer(s, 6)
    add_notes(s, "租户模型是 shared 模式：一个租户一个 Capsule Tenant，两个命名空间，一台 Gateway。"
                 "左边把一个沙箱拆开：它不只是 agent 容器，还有自己的 supervisor、两个 Service 和一个 PVC。"
                 "右边四个数字是配额设计的依据。右下角是诚实声明：POC2 验证了独立 Gateway+mTLS，"
                 "POC3 验证了 OIDC+多 Workspace，但“每租户 Gateway 走 OIDC”这个组合还没有合并跑过。")


# ============================================================================
# 07 — four layers
# ============================================================================
def s_layers():
    s = new_slide()
    header(s, "06 / 隔离", "四层各管一段：拒绝必须能落到具体那一层", "07")

    layers = [
        ("L4", "准入", "Gatekeeper", "不安全的 Pod 在入库前被拒；同一 ns 内按身份区分，无 ns 级豁免。",
         "POC-06 · X-01", BLUE, BLUE_L),
        ("L3", "租户", "Capsule", "命名空间归属、配额上限、租户网络策略下发；ForceTenantPrefix 拦跨租户命名。",
         "POC-02 · N-01..05", TEAL, TEAL_L),
        ("L2", "网络", "Antrea", "跨租户普通 Pod BLOCKED；沙箱只能到自己的 supervisor:5500。",
         "POC-05 · SEC-13", GREEN, GREEN_L),
        ("L1", "执行", "OpenShell", "文件系统、L7 出口、凭据代理；凭据只在边界注入，沙箱只见占位符。",
         "SEC-01..07 · 11", AMBER, AMBER_L),
    ]
    y = 1.94
    for tag, name, comp, body, ev, c, cl in layers:
        rect(s, M, y, CW, 0.96, fill=WHITE, line=LINE, radius=0.05)
        rect(s, M, y, 0.06, 0.96, fill=c)
        text(s, M + 0.22, y + 0.17, 0.5, 0.3, tag, size=11, color=c, bold=True)
        text(s, M + 0.78, y + 0.15, 0.9, 0.28, name, size=12.5, color=INK, bold=True)
        text(s, M + 0.78, y + 0.47, 1.5, 0.24, comp, size=8.4, color=MUTED)
        text(s, M + 2.42, y + 0.2, 6.55, 0.6, body, size=9.8, color=INK2, line=1.28)
        chip(s, M + CW - 2.2, y + 0.3, 2.2, 0.34, ev, cl, c, size=8.2)
        y += 1.14

    rect(s, M, 6.52, CW, 0.42, fill=AMBER_L, line=None, radius=0.03)
    text(s, M + 0.16, 6.58, CW - 0.3, 0.3,
         "注意：NetworkPolicy 语义是并集：租户自建一条就能把边界放宽（N-04 实测 BLOCKED → REACHED）。要“画了不能改”，用 Capsule enforce 或 Antrea ClusterNetworkPolicy。",
         size=8.4, color=AMBER)
    footer(s, 7)
    add_notes(s, "这四层不是重复，而是四个不同的失败面。回答“为什么被拒”时必须能指到某一层："
                 "Gatekeeper 拒的是对象形状，Capsule 拒的是归属与配额，Antrea 拒的是包，OpenShell 拒的是系统调用/HTTP。"
                 "POC 里每一条都有独立的测试，也踩过“归因错层”的坑（SEC-04 最初把 OpenShell 的阻断写成了平台隔离）。"
                 "底部这条可加性必须写进租户协议。")


# ============================================================================
# 08 — sandbox boundary
# ============================================================================
def s_boundary():
    s = new_slide()
    header(s, "07 / 沙箱边界", "文件、网络、凭据：三个边界都有反证，不是设计声明", "08")

    cards = [
        ("文件", "策略基线只管 /bin /usr /lib /proc /etc /var/log；不含 /opt、/data。",
         ["Reviewer 只读是两条独立链", "挂载 rw + 策略 ro → EACCES", "挂载 ro + 策略 rw → EROFS", "基线之外的路径必须显式进策略"],
         "SEC-06 / 07 · POC-04", TEAL, TEAL_L),
        ("网络", "workload 出网全 deny，只放行同一 pair 的 supervisor:5500。",
         ["node 直接开原始 socket 也出不去", "正对照：连自己的 supervisor = CONNECTED", "其余：API TIMEOUT / DNS EAI_AGAIN", "加任何出口都要改 NetworkPolicy"],
         "SEC-13 · POC-05", GREEN, GREEN_L),
        ("凭据", "沙箱里只有 openshell:resolve:env:… 占位符，真实 key 只在边界注入。",
         ["请求能成功，即证明边界注入生效", "改 provider profile 不追认到已建沙箱", "有效策略在 create 时快照", "占位符只在 supervisor 侧解析"],
         "SEC-11 · 5.3", AMBER, AMBER_L),
    ]
    x = M
    for title, lead, items, ev, c, cl in cards:
        rect(s, x, 1.94, 3.82, 3.5, fill=WHITE, line=LINE, radius=0.05)
        rect(s, x, 1.94, 3.82, 0.05, fill=c)
        text(s, x + 0.22, 2.12, 3.3, 0.32, title, size=15, color=INK, bold=True)
        text(s, x + 0.22, 2.52, 3.36, 0.82, lead, size=9.6, color=MUTED, line=1.38)
        y = 3.32
        for it in items:
            text(s, x + 0.22, y, 3.4, 0.28, "· " + it, size=8.8, color=INK2)
            y += 0.355
        text(s, x + 0.22, 4.98, 3.3, 0.26, ev, size=8, color=c, bold=True)
        x += 4.04

    rect(s, M, 5.72, CW, 0.82, fill=SOFT, line=None, radius=0.04)
    text(s, M + 0.2, 5.72, 2.0, 0.82, "生命周期", size=9.2, color=INK, bold=True, anchor=MSO_ANCHOR.MIDDLE)
    text(s, M + 1.55, 5.72, 10.1, 0.82,
         "沙箱存活期 = 传给它的命令存活期；Completed 之后 exec 报 “not ready”，但仍占 2 Service + 1 PVC，必须真的 delete。",
         size=9.4, color=MUTED, line=1.3, anchor=MSO_ANCHOR.MIDDLE)

    footer(s, 8)
    add_notes(s, "三张卡都是“反证”：不是平台说它拦，而是我们真的试了写、试了连、试了读 key。"
                 "文件那张最重要的是 errno 不同——EACCES 来自 OpenShell 策略层，EROFS 来自 Kubernetes 挂载层，"
                 "说明这是两条链，生产上两条都要留。网络那张必须带正对照，否则分不清“被拦”和“地址没拿到”。"
                 "凭据那张的结论是：沙箱里没有真 key，只有占位符。")


# ============================================================================
# 09 — Tetragon
# ============================================================================
def s_tetragon():
    s = new_slide()
    header(s, "08 / 内核监测", "Tetragon 补上 Supervisor 看不到的那一半", "09")

    text(s, M, 1.9, 6.2, 0.28, "它能给出什么", size=11, color=AMBER, bold=True)
    bullet_list(s, M, 2.24, 6.25, 2.1, [
        [("exec / exit", {"bold": True, "color": INK}), ("：binary、argv、uid、parent 链", {})],
        [("connect", {"bold": True, "color": INK}), ("：五元组，含被拒绝的目的地", {})],
        [("身份", {"bold": True, "color": INK}), ("：namespace / pod / container / image", {})],
        [("不依赖自报", {"bold": True, "color": INK}), ("：换进程、绕过工具层也逃不掉", {})],
        [("策略即代码", {"bold": True, "color": INK}), ("：TracingPolicy 与租户一起下发", {})],
    ], size=10.6, color=MUTED, gap=8, line=1.3, mcolor=AMBER)

    text(s, M, 4.62, 6.2, 0.28, "Supervisor 的 OCSF 看不到什么", size=11, color=TEAL, bold=True)
    text(s, M, 4.96, 6.2, 0.86,
         "OCSF 只记录它自己代理的 L7 流量；子进程、原始 socket、被内核直接拒绝的连接，需要 eBPF 侧的第二双眼睛。",
         size=9.4, color=MUTED, line=1.4)

    # code block
    cx, cy, cw = M + 6.55, 1.9, 5.3
    rect(s, cx, cy, cw, 3.62, fill=INK, line=None, radius=0.04)
    text(s, cx + 0.22, cy + 0.14, 4.9, 0.24, "同一沙箱的真实事件（节选）", size=9, color=TEAL_M, bold=True)

    def code_line(x, y, w, runs, size=8.4):
        tb = s.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(0.3))
        tf = tb.text_frame
        tf.word_wrap = False
        tf.auto_size = MSO_AUTO_SIZE.NONE
        p = tf.paragraphs[0]
        p.line_spacing = 1.25
        _runs(p, runs, size, DARK_TX, False, latin=MONO, ea=EA)

    code_line(cx + 0.22, cy + 0.46, cw - 0.4, [
        ("PROCESS_EXEC ", {"color": RGBColor(0x7D, 0xD3, 0xFC)}),
        ("binary=/usr/bin/curl", {"color": DARK_TX})])
    code_line(cx + 0.22, cy + 0.72, cw - 0.4, [("argv=[curl -s -m 6 https://api.openai.com/]", {"color": DARK_MUT})])
    code_line(cx + 0.22, cy + 0.98, cw - 0.4, [("uid=10001  pod=poc-shared--pi-review-2", {"color": DARK_TX})])

    code_line(cx + 0.22, cy + 1.36, cw - 0.4, [
        ("PROCESS_EXIT ", {"color": RGBColor(0x7D, 0xD3, 0xFC)}),
        ("status=7", {"color": DARK_TX})])

    code_line(cx + 0.22, cy + 1.74, cw - 0.4, [
        ("INET ", {"color": RGBColor(0x7D, 0xD3, 0xFC)}),
        ("api.openai.com:443 ", {"color": DARK_TX}),
        ("DENIED", {"color": RGBColor(0xFC, 0xA5, 0xA5), "bold": True})])

    code_line(cx + 0.22, cy + 2.12, cw - 0.4, [
        ("OCSF ", {"color": RGBColor(0xF0, 0xAB, 0xFC)}),
        ("NET:OPEN [MED] DENIED /usr/bin/curl", {"color": DARK_TX})])
    code_line(cx + 0.22, cy + 2.38, cw - 0.4, [
        ("reason:transparent_tcp_policy_denied", {"color": DARK_MUT})])

    rect(s, cx + 0.22, cy + 2.74, cw - 0.44, 0.012, fill=RGBColor(0x2A, 0x38, 0x50))
    text(s, cx + 0.22, cy + 2.84, cw - 0.4, 0.22, "策略集（TracingPolicy）", size=7.4, color=TEAL_M, bold=True)
    text(s, cx + 0.22, cy + 3.08, cw - 0.4, 0.42,
         ["00 egress-who · 10 dangerous-fs · 20 supply-chain",
          "30 exec-and-proc · 40 enforce-network · 50 enforce-exec"],
         size=6.9, color=DARK_MUT, line=1.35)

    text(s, cx + 0.22, cy + 3.68, 5.0, 0.24, "同一秒：内核说谁在做，Supervisor 说准不准", size=7.8, color=FAINT)

    rect(s, M, 5.96, CW, 0.92, fill=AMBER_L, line=None, radius=0.04)
    text(s, M + 0.2, 6.04, 3.4, 0.24, "强制能力：前提与边界", size=9.4, color=AMBER, bold=True)
    text(s, M + 0.2, 6.3, 11.4, 0.52,
         "宿主 LSM 必须含 bpf（本环境 lsm=lockdown,capability,landlock,yama,apparmor → lsm-hook 策略 load_error）；kprobe 与 security_socket_connect override 正常。1.8.0 还需 --disable-kprobe-multi。",
         size=8.4, color=AMBER, line=1.3)
    footer(s, 9)
    add_notes(s, "这一页回答“为什么都有 OCSF 了还要 Tetragon”。OCSF 是 Supervisor 自己产生的事件，只覆盖它代理的流量；"
                 "Tetragon 在内核侧，任何进程、任何 socket 都看得见。右边是同一次 curl 的原始行："
                 "内核给出 binary/argv/uid/pod，Supervisor 给出 L7 的 ALLOWED/DENIED 与 reason。"
                 "底部是必须写进交付检查的前提：宿主 LSM 没有 bpf，强制类策略加载失败——这是环境前提，不是策略写错。")


# ============================================================================
# 10 — OTel
# ============================================================================
def s_otel():
    s = new_slide()
    header(s, "09 / 统一遥测", "三条流、一个接入点，两个后端 + 一个下游", "10")

    sources = [
        ("Agent · pi-otel", ["OTLP/HTTP → supervisor relay", "自动注入 endpoint 与 CA"], TEAL, TEAL_L),
        ("Gateway / driver / supervisor", ["OTLP traces", "OCSF 走 logs pipeline"], BLUE, BLUE_L),
        ("Tetragon", ["/var/log/tetragon/*.log", "filelog + json_parser"], AMBER, AMBER_L),
    ]
    ys = [2.02, 2.98, 3.94]
    for (nm, sub, c, cl), y in zip(sources, ys):
        rect(s, M, y, 3.22, 0.78, fill=cl, line=None, radius=0.05)
        text(s, M + 0.16, y + 0.1, 2.95, 0.24, nm, size=9.6, color=c, bold=True)
        text(s, M + 0.16, y + 0.35, 2.95, 0.38, sub, size=7.6, color=MUTED, line=1.2)
        arrow(s, M + 3.22, y + 0.39, M + 3.46, y + 0.39, color=FAINT, lw=1.1)

    # bus
    rect(s, M + 3.46, 2.39, 0.012, 2.02, fill=LINE)
    arrow(s, M + 3.46, 4.4, M + 3.72, 4.4, color=FAINT, lw=1.2)

    # collector
    rx, ry = M + 3.72, 2.02
    rect(s, rx, ry, 3.2, 3.4, fill=INK, line=None, radius=0.04)
    text(s, rx + 0.2, ry + 0.16, 2.8, 0.26, "OTel Collector", size=11.5, color=WHITE, bold=True)
    parts = [("receivers", "otlp · file_log"), ("processors", "memory_limiter · batch · k8s_attributes"),
             ("pipelines", ["traces ← otlp", "logs ← otlp + file_log"]), ("exporters", "jaeger · tempo · debug")]
    py = ry + 0.56
    for k, v in parts:
        text(s, rx + 0.2, py, 2.8, 0.2, k, size=7.4, color=TEAL_M, bold=True)
        text(s, rx + 0.2, py + 0.19, 2.82, 0.42, v, size=7.4, color=DARK_MUT, line=1.2)
        py += 0.7

    # backends
    bx = rx + 3.5
    backs = [
        ("Jaeger", ["脚本断言用 /api/traces 可查", "1.69.0 保留查询 API"], SOFT, INK),
        ("Tempo + Grafana", ["演示出口：宿主 :4317 / :3200", "看完整时间线"], SOFT, INK),
        ("SIEM / 安全 Agent", ["OCSF 原生字段可直接映射", "检测与调查的输入"], INK, WHITE),
    ]
    bys = [2.02, 3.12, 4.22]
    for (nm, lines, bg, fg), yy in zip(backs, bys):
        rect(s, bx, yy, 3.95, 0.98, fill=bg, line=(None if bg == INK else LINE), radius=0.05)
        text(s, bx + 0.18, yy + 0.11, 3.6, 0.24, nm, size=9.6,
             color=(TEAL_M if bg == INK else INK), bold=True)
        text(s, bx + 0.18, yy + 0.38, 3.62, 0.52, lines, size=7.6,
             color=(DARK_MUT if bg == INK else MUTED), line=1.25)
        arrow(s, rx + 3.2, yy + 0.49, bx, yy + 0.49, color=FAINT, lw=1.2)

    # facts
    facts = [
        ("Agent 不需要知道 Collector 地址", "OpenShell 注入本沙箱的 relay endpoint 与 CA；发 JSON 会 415，必须 protobuf。"),
        ("OCSF 走 logs，不是 traces", "Collector 的 logs pipeline 同时收 otlp 与 filelog；ocsf_log(JSONL) 是并行的离线证据。"),
        ("service.name 必须显式钉住", "默认是 pi；settings 只从 ~/.pi/agent 或 cwd/.pi 读，写错位置会被静默忽略。"),
    ]
    fx = M
    for t, b in facts:
        text(s, fx, 5.66, 3.86, 0.26, t, size=9, color=TEAL, bold=True)
        text(s, fx, 5.94, 3.84, 0.72, b, size=7.9, color=MUTED, line=1.3)
        fx += 4.04

    footer(s, 10)
    add_notes(s, "三条流：Agent 自己发的 trace（走 supervisor relay，不需要 Collector 地址和凭据）；"
                 "Gateway/driver/supervisor 的 trace 与 OCSF；Tetragon 落盘的 JSON 通过 filelog 进来。"
                 "一个 Collector 收，两个出口：Jaeger 给脚本断言，Tempo 给演示。"
                 "三个坑：OCSF 在 logs pipeline；service.name 默认 pi；k8sattributes 没有 RBAC 会静默降级。")


# ============================================================================
# 11 — correlation
# ============================================================================
def s_correlate():
    s = new_slide()
    header(s, "10 / 关联", "一个 sandbox.id，串起三条证据流", "11")

    chain = [
        ("trace", "sandbox.id", TEAL),
        ("pod label", "boundary-pair", BLUE),
        ("pod name", "poc-shared--pi-*", INK),
        ("Tetragon", "pod.name", AMBER),
        ("OCSF line", "supervisor 日志", GREEN),
    ]
    bw, gap = 2.02, 0.46
    x = M
    for i, (top, bot, c) in enumerate(chain):
        rect(s, x, 1.98, bw, 0.9, fill=WHITE, line=c, lw=1.2, radius=0.06)
        text(s, x + 0.12, 2.15, bw - 0.24, 0.22, top, size=8, color=MUTED, bold=True)
        text(s, x + 0.12, 2.37, bw - 0.24, 0.4, bot, size=9.4, color=c, bold=True, line=1.1)
        if i < 4:
            arrow(s, x + bw, 2.43, x + bw + gap, 2.43, color=FAINT, lw=1.4)
        x += bw + gap

    # evidence panel
    rect(s, M, 3.24, CW, 2.52, fill=SOFT, line=None, radius=0.04)
    text(s, M + 0.24, 3.38, 6.0, 0.26, "同一次 curl，同一秒", size=10.5, color=INK, bold=True)

    rect(s, M + 0.24, 3.72, 5.65, 1.86, fill=WHITE, line=LINE, radius=0.04)
    text(s, M + 0.4, 3.82, 5.3, 0.22, "Tetragon · 内核侧", size=8, color=AMBER, bold=True)
    tb = s.shapes.add_textbox(Inches(M + 0.4), Inches(4.06), Inches(5.35), Inches(1.45))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = MSO_ANCHOR.TOP
    lines = [
        [("binary=/usr/bin/curl", {"color": INK2})],
        [("argv=[curl -s -m 6 https://api.openai.com/]", {"color": MUTED})],
        [("uid=10001   pod=poc-shared--pi-review-2", {"color": INK2})],
        [("pod.uid / container / image 均在同一事件", {"color": MUTED})],
    ]
    for i, ln in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.line_spacing = 1.4
        _runs(p, ln, 8.2, INK2, False, latin=MONO, ea=EA)

    rect(s, M + 6.06, 3.72, 5.58, 1.86, fill=INK, line=None, radius=0.04)
    text(s, M + 6.22, 3.82, 5.2, 0.22, "Supervisor · OCSF", size=8, color=TEAL_M, bold=True)
    tb = s.shapes.add_textbox(Inches(M + 6.22), Inches(4.06), Inches(5.28), Inches(1.45))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = MSO_ANCHOR.TOP
    lines = [
        [("NET:OPEN [MED] ", {"color": DARK_TX}),
         ("DENIED", {"color": RGBColor(0xFC, 0xA5, 0xA5), "bold": True})],
        [("/usr/bin/curl(0) -> api.openai.com:443", {"color": DARK_TX})],
        [("reason:transparent_tcp_policy_denied", {"color": DARK_MUT})],
        [("同一秒的 supervisor 行，可按 pod 名 join", {"color": DARK_MUT})],
    ]
    for i, ln in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.line_spacing = 1.4
        _runs(p, ln, 8.2, DARK_TX, False, latin=MONO, ea=EA)

    text(s, M + 0.4, 5.16, 5.3, 0.26, "→ 谁在跑、以什么身份、连了哪里", size=8, color=AMBER, bold=True)
    text(s, M + 6.22, 5.16, 5.3, 0.26, "→ 准不准、被哪条策略拦、为什么", size=8, color=TEAL_M, bold=True)
    text(s, M, 5.98, CW, 0.44,
         "三条流不是三份日志，而是一条可回溯的时间线 —— 这是安全 AI Agent 能自动复盘的输入。",
         size=11.5, color=INK, bold=True)
    text(s, M, 6.48, CW, 0.3,
         "join 路径：trace(sandbox.id) == pod label(boundary-pair) == pod name == Tetragon pod.name == supervisor 的 OCSF 行",
         size=8.4, color=FAINT)

    footer(s, 11)
    add_notes(s, "这一页是整套方案里最有复用价值的一条：关联键不是自造的，而是 OpenShell 已经写在三处的 sandbox.id。"
                 "trace 的 resource 里有（relay 补的），Pod 标签上有（boundary-pair），Tetragon 事件里有 pod 名。"
                 "右下这段 OCSF 和左下这段内核事件是实测的同一次 curl。有了这条链，安全 Agent 才能把"
                 "“谁在什么时候、用什么进程、连了哪里、被哪条策略拒了”拼成一条时间线。")


# ============================================================================
# 12 — AI runtime foundation
# ============================================================================
def s_airuntime():
    s = new_slide()
    header(s, "11 / 安全 AI Agent Runtime", "从“能观测”到“能处置”：这一轮交付到第 2 级", "12")

    levels = [
        ("L0", "信号齐全", "本轮 已交付", "traces · OCSF · kernel · audit · k8s state · identity",
         GREEN, GREEN_L),
        ("L1", "统一语义", "本轮 部分交付", "OTel + OCSF + k8sattributes；sandbox.id 作主键",
         TEAL, TEAL_L),
        ("L2", "检测与调查", "可构建", "异常 exec、未批准出口、策略漂移、跨租户探测",
         AMBER, AMBER_L),
        ("L3", "闭环处置", "未实现", "吊销 Workspace 成员、隔离沙箱、回滚策略",
         MUTED, SOFT),
    ]
    y = 1.96
    for tag, name, state, body, c, cl in levels:
        rect(s, M, y, 7.7, 0.94, fill=WHITE, line=LINE, radius=0.04)
        rect(s, M, y, 0.06, 0.94, fill=c)
        text(s, M + 0.2, y + 0.28, 0.5, 0.3, tag, size=11, color=c, bold=True)
        text(s, M + 0.76, y + 0.14, 1.5, 0.26, name, size=11.5, color=INK, bold=True)
        text(s, M + 0.76, y + 0.43, 1.5, 0.24, state, size=8, color=c)
        text(s, M + 2.38, y + 0.2, 5.15, 0.58, body, size=9, color=MUTED, line=1.3)
        y += 1.06

    # right panel signals
    rx = M + 8.0
    text(s, rx, 1.94, 3.9, 0.26, "六类信号（已验证可得）", size=10.5, color=TEAL, bold=True)
    sigs = ["Agent trace / span", "Supervisor OCSF", "Tetragon 内核事件",
            "K8s 审计与准入拒绝", "K8s 对象状态", "身份 sub / groups"]
    for i, sg in enumerate(sigs):
        yy = 2.28 + i * 0.4
        circle(s, rx, yy + 0.08, 0.08, TEAL_M)
        text(s, rx + 0.2, yy, 3.6, 0.24, sg, size=8.8, color=INK2)

    rect(s, rx, 4.76, 3.95, 1.62, fill=SOFT, line=None, radius=0.04)
    text(s, rx + 0.16, 4.86, 3.6, 0.24, "还缺什么（不是这一轮的目标）", size=8.6, color=AMBER, bold=True)
    bullet_list(s, rx + 0.16, 5.12, 3.64, 1.18, [
        "持久化与流式管道（Kafka / 数据湖）",
        "策略与处置 API、审批模型",
        "Agent 自身身份与最小权限",
        "评测、误报与成本控制",
        "告警分级、去重与抑制",
    ], size=7.6, color=MUTED, gap=2, line=1.2, mcolor=AMBER, indent=0.14)

    text(s, M, 6.4, CW, 0.3,
         "结论：这一轮交付的是“安全 Agent 的基础 infra” —— 信号齐、能关联、能归因；不是 Agent 本身。",
         size=9.6, color=INK, bold=True)
    footer(s, 12)
    add_notes(s, "把目标拆成四级，避免把“有日志”说成“有 Agent”。L0 信号齐了，L1 语义统一了（同一套 OTel/OCSF + sandbox.id），"
                 "L2 的检测规则今天就能写（异常 exec、未批准出口、策略漂移），L3 的处置还没有 API 和审批模型。"
                 "右侧六类信号是已经实测能拿到的；下面列的是缺口，写清楚才不会被当成已交付。")


# ============================================================================
# 13 — results
# ============================================================================
def s_results():
    s = new_slide()
    header(s, "12 / 验证结果", "49/49 全绿；能力项与安全用例各留一条“有条件”", "13")

    stats = [("49", "POC3 用例 PASS", TEAL), ("0", "FAIL", TEAL),
             ("11", "能力项（10 通过 / 1 部分）", INK), ("14", "安全用例（全部通过）", INK),
             ("9/9", "Antrea 网络断言", GREEN)]
    x = M
    for big, small, c in stats:
        text(s, x, 1.9, 2.3, 0.52, big, size=24, color=c, bold=True)
        text(s, x, 2.42, 2.28, 0.24, small, size=8.2, color=MUTED)
        x += 2.4

    rows = [
        ["验收面", "结论", "关键证据"],
        ["身份链路", [("● 通过", {"color": GREEN, "bold": True})], "三个用户 sub == 目录 entryUUID；groups 全部来自目录组"],
        ["Kubernetes 隔离", [("● 通过", {"color": GREEN, "bold": True})], "双向 can-i + 真实创建；跨租户写被 RBAC 拒"],
        ["OpenShell 隔离", [("● 通过", {"color": GREEN, "bold": True})], "not a member of workspace；成员移动有正对照"],
        ["跨系统一致性", [("▲ 有条件", {"color": AMBER, "bold": True})], "同 claim / 同 subject；目录变更需删本地副本"],
        ["失败可观测", [("● 通过", {"color": GREEN, "bold": True})], "每次拒绝可 grep：missing_role / not_workspace_member"],
        ["租户网络隔离", [("● 通过", {"color": GREEN, "bold": True})], "跨租户 BLOCKED + 同租户正对照 REACHED"],
        ["Tetragon 强制", [("▲ 部分", {"color": AMBER, "bold": True})], "观测全部通过；lsm-hook 策略因宿主无 bpf 加载失败，kprobe 正常"],
    ]
    table(s, M, 2.8, CW, [2.0, 1.9, 8.0], rows,
          row_heights=[0.32, 0.44, 0.44, 0.44, 0.44, 0.44, 0.44, 0.44], size=9.2, head_size=9,
          first_col_color=INK)

    text(s, M, 6.48, CW, 0.3,
         "唯一未验证：观测后端的持久化与保留期（Jaeger 为内存存储）。Tetragon 强制能力受宿主 LSM 限制，属于交付前提。",
         size=8.6, color=FAINT)
    footer(s, 13)
    add_notes(s, "结果页只放验收面，不堆用例编号。49/49 是 POC3 的脚本输出；11 项能力里 10 项通过、1 项部分（Tetragon 强制）；"
                 "14 条安全用例全部通过，但 SEC-12 必须分成控制面/数据面来表述，不能笼统写 fail-closed。"
                 "这些数字都能用 phases/14 与 phases/13 重跑。")


# ============================================================================
# 14 — methodology
# ============================================================================
def s_method():
    s = new_slide()
    header(s, "13 / 复盘", "五个“差点写错”的结论：测法比功能更容易出错", "14")

    rows = [
        ["原判", "真实原因"],
        [[("POC-08 查不到 Pi 的 trace", {"bold": True})],
         "按错了 service.name：pi-otel 只从 ~/.pi/agent 或 cwd/.pi 读配置，写错位置被静默忽略，名字退回默认 pi。修好后 span 变成 invoke_agent pi / chat <model>。"],
        [[("POC-09 OCSF 不能走 OTLP", {"bold": True})],
         "把“chart 没暴露这个键”当成“产品不支持”。二进制里有 otlp.ocsf 与 openshell_ocsf_otlp_exported_total；OCSF 走 Collector 的 logs pipeline。"],
        [[("POC-04 共享 Workspace 不成立", {"bold": True})],
         "reviewer 策略文件与 developer 版一字不差：只有注释写了“只读”，YAML 里仍是 read_write。修好后写入被拒，dev 的文件仍可见。"],
        [[("SEC-04 跨租户被拒（归因错）", {"bold": True})],
         "阻断来自 OpenShell 自己生成的 NetworkPolicy；当时平台层 spec.networkPolicies 是空的。POC3 才补上平台级租户策略。"],
        [[("SEC-12 数据面 http=200 不复现", {"bold": True})],
         "测法错了两次：用 NetworkPolicy 当“断链”（掐的是 supervisor 出网）；用 sandbox exec 探数据面（它自己走 Gateway，一断必然 transport error）。"],
    ]
    table(s, M, 1.94, CW, [4.3, 7.6], rows,
          row_heights=[0.34, 0.58, 0.58, 0.58, 0.58, 0.62], size=9.2, head_size=9,
          first_col_color=RED)

    rect(s, M, 5.88, CW, 0.6, fill=TEAL_L, line=None, radius=0.03)
    text(s, M + 0.18, 6.0, CW - 0.36, 0.36,
         "所以本文每个“通过”都配一条可粘贴的复验命令（README §7 / §12.7）；测不出来时，先怀疑测法。",
         size=9.4, color=TEAL, bold=True)
    footer(s, 14)
    add_notes(s, "这页不是自我批评，是给评审的方法论：五条里没有一条是产品缺陷，全是测法或文档错误。"
                 "最典型的是 SEC-12——我们先后用 NetworkPolicy 和 sandbox exec 去测“Gateway 断链”，两次都测错了。"
                 "换成缩容 StatefulSet + 沙箱内自循环读日志，结论才立住。这也是为什么每个结论都配一条复验命令。")


# ============================================================================
# 15 — production gaps
# ============================================================================
def s_gaps():
    s = new_slide()
    header(s, "14 / 生产化差距", "离生产还差 6 件事，按阻断程度排序", "15")

    items = [
        ("P0", "同步控制器", "目录 → token、目录组 → Workspace 成员。Keycloak 26.4 无可用的 sync 端点，现在靠删本地副本。",
         "影响：权限变更永远慢一拍", RED, RED_L),
        ("P0", "观测后端持久化", "Jaeger all-in-one 是内存存储，两轮各丢过一次证据；生产要换存储与保留期。",
         "影响：无法对外承诺取证与保留期", RED, RED_L),
        ("P1", "Gateway HA", "单副本 + SQLite；需要外部 PostgreSQL，以及证书轮转持续同步到 runtime ns。",
         "影响：Gateway 重启即控制面中断", AMBER, AMBER_L),
        ("P1", "网络策略收紧", "NetworkPolicy 可加；用 Capsule enforce 或 Antrea ANP 把边界变成“画了不能改”。",
         "影响：租户可自行放宽边界", AMBER, AMBER_L),
        ("P1", "Tetragon 强制", "宿主 LSM 必须含 bpf；把这条写进开通检查，否则 lsm-hook 策略全部 load_error。",
         "影响：只能观测、不能阻断", AMBER, AMBER_L),
        ("P2", "OCSF chart 暴露", "v0.1.7 chart 未暴露 otlp.ocsf，靠直接写 TOML；升级时断言 exported_total。",
         "影响：升级可能静默丢 OCSF", MUTED, SOFT),
    ]
    for i, (p, title, body, impact, c, cl) in enumerate(items):
        col = i % 2
        row = i // 2
        x = M + col * 6.0
        y = 1.94 + row * 1.5
        rect(s, x, y, 5.82, 1.32, fill=WHITE, line=LINE, radius=0.05)
        chip(s, x + 0.18, y + 0.16, 0.56, 0.3, p, cl, c, size=8.2)
        text(s, x + 0.86, y + 0.14, 4.7, 0.28, title, size=11.5, color=INK, bold=True)
        text(s, x + 0.18, y + 0.52, 5.42, 0.5, body, size=8.6, color=MUTED, line=1.3)
        text(s, x + 0.18, y + 1.03, 5.4, 0.22, impact, size=7.6, color=c, bold=True)

    text(s, M, 6.56, CW, 0.3,
         "判断标准：P0 不解决就无法对外承诺“权限变更即时生效”与“证据可留存”；P1 影响可用性与边界强度；P2 是升级风险。",
         size=8.4, color=FAINT)
    footer(s, 15)
    add_notes(s, "生产化差距按“会不会让承诺失效”排序，而不是按工作量。前两条是 P0：一条是权限变更的时效，"
                 "一条是证据留存。这两条不解决，POC 的结论就只能停在演示。"
                 "P1 的 Gateway HA 与网络收紧是下一阶段；Tetragon 强制是环境前提，要在开通检查里查 LSM。")


# ============================================================================
# 16 — recommendation
# ============================================================================
def s_reco():
    s = new_slide()
    header(s, "15 / 建议", "先在一个租户上生产化，再复制", "16")

    cols = [
        ("采纳", ["身份中继（LDAP → Keycloak → 同一 JWT）", "每租户独立 Gateway + Workspace",
                 "四层隔离的分层归因", "sandbox.id 作为关联主键"], TEAL, TEAL_L),
        ("补齐", ["目录/组成员同步控制器", "持久化观测后端 + 保留期", "Gateway 多副本 + 外部 PostgreSQL"], BLUE, BLUE_L),
        ("待决策", ["网络策略可加性：接受还是收紧", "证据保留期与合规边界", "Agent 自主处置的权限边界"], AMBER, AMBER_L),
    ]
    x = M
    for title, items, c, cl in cols:
        rect(s, x, 1.94, 3.82, 2.98, fill=WHITE, line=LINE, radius=0.05)
        rect(s, x, 1.94, 3.82, 0.05, fill=c)
        text(s, x + 0.22, 2.1, 3.3, 0.3, title, size=13, color=c, bold=True)
        bullet_list(s, x + 0.22, 2.5, 3.4, 1.7, items, size=9.8, color=INK2, gap=9, line=1.32,
                    mcolor=c, indent=0.17)
        rect(s, x + 0.22, 4.28, 3.36, 0.012, fill=LINE)
        basis = {"采纳": "依据：POC2 / POC3 的实测结论",
                 "补齐": "依据：POC3 C-04 与 §10 缺口清单",
                 "待决策": "需要业务与合规共同拍板"}[title]
        text(s, x + 0.22, 4.42, 3.4, 0.3, basis, size=8, color=MUTED)
        x += 4.04

    text(s, M, 5.16, 4.0, 0.26, "建议节奏", size=10, color=TEAL, bold=True)
    phases = [("30 天", "合并验证 Gateway + OIDC；接 SIEM", TEAL),
              ("90 天", "同步控制器 + 持久化；一个真实租户上线", BLUE),
              ("180 天", "Gateway HA、策略收紧、处置闭环试点", AMBER)]
    x = M
    for label, body, c in phases:
        rect(s, x, 5.46, 3.82, 0.94, fill=SOFT, line=None, radius=0.04)
        rect(s, x, 5.46, 0.05, 0.94, fill=c)
        text(s, x + 0.2, 5.46, 1.1, 0.94, label, size=11, color=c, bold=True, anchor=MSO_ANCHOR.MIDDLE)
        text(s, x + 1.3, 5.46, 2.45, 0.94, body, size=8.8, color=INK2, line=1.3, anchor=MSO_ANCHOR.MIDDLE)
        x += 4.04
    footer(s, 16)
    add_notes(s, "最后是决策页：左边是已经被证据支持的采纳项；中间是必须补的工程件；右边是只有业务能拍的三件事。"
                 "节奏建议 30/90/180 天：先把“每租户 Gateway + OIDC”这个组合补跑一次，同时接 SIEM；"
                 "再上同步控制器与持久化；最后才是 HA 与处置闭环。")


# ============================================================================
# 17 — appendix
# ============================================================================
def s_appendix():
    s = new_slide()
    header(s, "附录 / 证据索引", "复现入口：一条命令一张矩阵", "17")

    rows = [
        ["脚本", "覆盖", "成功标志"],
        ["01 · 02 · 03", "集群 / Antrea / 网络矩阵", "PASS=9 FAIL=0"],
        ["04 · 05 · 06", "Capsule / Gatekeeper / Sandbox", "逐条确认被拒"],
        ["07 · 10 · 08", "RWX / 观测栈 / Gateway", "gateway_id 不同"],
        ["09 · 11 · 12", "准入 / Pi 场景 / Tetragon", "DEV_WRITE_OK"],
        ["13", "安全矩阵 SEC-04..14", "正对照成立"],
        ["14", "POC3 身份与隔离", "PASS=49 FAIL=0"],
    ]
    table(s, M, 1.94, 5.95, [1.3, 2.65, 1.9], rows,
          row_heights=[0.34, 0.46, 0.46, 0.46, 0.46, 0.46, 0.46], size=8.4, head_size=8.4,
          first_col_color=TEAL)

    rx = M + 6.35
    text(s, rx, 1.9, 5.4, 0.26, "组件版本", size=10, color=TEAL, bold=True)
    vers = [("Kubernetes / kind", "v1.37.0 / v0.33.0"), ("Antrea / Capsule", "2.7.0 / 0.15.2"),
            ("Gatekeeper / OpenShell", "3.23.1 / 0.1.7"), ("Tetragon / Keycloak", "1.8.0 / 26.4"),
            ("OTel Collector / Jaeger", "0.155.0 / 1.69.0"), ("agent-sandbox / Pi", "v1.0.10 / 1.5.0")]
    y = 2.24
    for k, v in vers:
        text(s, rx, y, 2.7, 0.22, k, size=8.4, color=MUTED)
        text(s, rx + 2.7, y, 2.6, 0.22, v, size=8.4, color=INK2, bold=True)
        y += 0.34

    rect(s, rx, 4.4, 5.35, 1.9, fill=SOFT, line=None, radius=0.04)
    text(s, rx + 0.18, 4.52, 5.0, 0.22, "文档与原始输出", size=8.8, color=INK, bold=True)
    docs = [("README.md", "结论唯一出处"), ("POC2.md / POC3.md", "两轮设计原文"),
            ("poc/docs/POC2-CONCLUSIONS.md", "逐条原始输出"), ("poc/usage/02-agent-visibility.md", "查询手册")]
    yy = 4.84
    for k, v in docs:
        text(s, rx + 0.18, yy, 3.1, 0.22, k, size=7.8, color=TEAL, bold=True)
        text(s, rx + 3.3, yy, 1.95, 0.22, v, size=7.6, color=MUTED)
        yy += 0.34

    text(s, M, 5.34, 5.95, 0.9,
         "顺序：01 → fix-apiserver-sans → 02 → 03 → 04 → 05 → 06 → 07 → 10 → 08 → 09 → 11 → 12 → 13 → 14；10 必须在 08 之前。",
         size=8.4, color=MUTED, line=1.4)
    text(s, M, 6.08, 5.95, 0.44,
         "注意：同一时间只跑一个 phases 脚本 —— 它们共用同一个 Gateway 与同一份租户配额。",
         size=8.2, color=AMBER, line=1.35)
    footer(s, 17)
    add_notes(s, "附录只做索引：脚本顺序、版本、文档位置。10 必须在 08 之前，否则 Gateway 第一屏全是 OTLP 失败，"
                 "会被误读成 OpenShell 没配好。14 是 POC3 的整张矩阵，末尾应打印 PASS=49 FAIL=0。")


# ============================================================================
# 18 — end
# ============================================================================
def s_end():
    s = new_slide(DARK_BG)
    for gx in [i * 0.9 for i in range(1, 15)]:
        rect(s, gx, 0, 0.006, H, fill=RGBColor(0x14, 0x20, 0x33))
    rect(s, 0, 0, 0.10, H, fill=TEAL_M)

    text(s, M, 2.0, 10.0, 0.3, "结论可复验  ·  边界可解释", size=10.5, color=TEAL_M, bold=True)
    text(s, M, 2.42, 11.0, 0.9, "证据在仓库里，判断在数字里。", size=34, color=WHITE, bold=True)
    text(s, M, 3.5, 10.4, 0.6,
         "下一步：把“每租户 Gateway + OIDC”合并验证一次，然后在一个真实租户上跑通 30 天。",
         size=13, color=DARK_MUT, line=1.4)

    links = [("README.md", "结论唯一出处"), ("poc/phases/14-identity-federation.sh", "49 条身份矩阵"),
             ("poc/phases/13-security-matrix.sh", "安全矩阵")]
    x = M
    for k, v in links:
        text(s, x, 5.3, 3.9, 0.24, k, size=8.6, color=TEAL_M, bold=True)
        text(s, x, 5.56, 3.9, 0.24, v, size=8, color=DARK_MUT)
        x += 4.0

    rect(s, M, 6.3, CW, 0.012, fill=RGBColor(0x26, 0x33, 0x49))
    text(s, M, 6.46, 6.0, 0.3, "谢谢 · Q&A", size=11, color=DARK_TX, bold=True)
    text(s, W - M - 3.4, 6.46, 3.4, 0.3, "2026-11  ·  aisanbox-inske", size=9, color=DARK_MUT,
         align=PP_ALIGN.RIGHT)
    add_notes(s, "收尾：所有结论都可以在仓库里用脚本复现；数字和边界都写在 README 里。"
                 "下一步只需要一次合并验证，就能把“每租户 Gateway + OIDC”从目标形态变成实测结论。")


# ----------------------------------------------------------------------------
def build():
    s_cover()
    s_summary()
    s_start()
    s_arch()
    s_identity()
    s_runtime()
    s_layers()
    s_boundary()
    s_tetragon()
    s_otel()
    s_correlate()
    s_airuntime()
    s_results()
    s_method()
    s_gaps()
    s_reco()
    s_appendix()
    s_end()

    cp = prs.core_properties
    cp.title = "多租户安全 AI Agent Runtime — POC 总结"
    cp.subject = "在既有容器平台之上叠加 OpenShell / Tetragon / OTel"
    cp.author = "aisanbox-inske"
    cp.keywords = "OpenShell, Tetragon, OTel, OCSF, Keycloak, Capsule, Antrea, Gatekeeper"
    cp.comments = "基于三轮 POC 的可复验结论；配套 README.md"

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "aisanbox-security-ai-runtime-poc.pptx")
    prs.save(out)
    print("saved", out, "slides:", len(prs.slides))


if __name__ == "__main__":
    build()
