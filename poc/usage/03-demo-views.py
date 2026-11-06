#!/usr/bin/env python3
"""Render one agent run from both views: the OTLP trace and the kernel's log.

Used by 03-agent-otel-demo.sh. Kept separate so the shell script stays readable
and so the same output can be produced by hand while recording.
"""
import json
import subprocess
import sys

CTX = sys.argv[1] if len(sys.argv) > 1 else "kind-inske-plane-a"
SANDBOX = sys.argv[2] if len(sys.argv) > 2 else "otel-agent"
NS = SANDBOX_TENANT = (sys.argv[4] if len(sys.argv) > 4 else "acme")
MODE = sys.argv[3] if len(sys.argv) > 3 else "trace"
AGENT_UID = "10001"     # OpenShell 的 sandbox 身份；见 docs


def norm(s):
    return " ".join(str(s).split()).strip()


def jaeger(path):
    try:
        out = subprocess.run(["curl", "-s", "-m", "10", f"http://localhost:16686{path}"],
                             capture_output=True, text=True).stdout
        return json.loads(out or "{}")
    except Exception:
        return {}


def trace_id_for(sandbox):
    d = jaeger("/api/traces?service=aisanbox-agent&limit=10")
    for tr in d.get("data", []):
        for s in tr["spans"]:
            if s["operationName"] != "agent.run":
                continue
            tags = {t["key"]: t["value"] for t in s["tags"]}
            if str(tags.get("aisanbox.sandbox")) == sandbox:
                return tr["traceID"]
    return (d.get("data") or [{}])[0].get("traceID", "")


def show_trace(tid):
    d = jaeger(f"/api/traces/{tid}")
    data = d.get("data") or []
    if not data:
        print("   (no trace in Jaeger — is OTEL_EXPORTER_OTLP_ENDPOINT reachable "
              "from the sandbox, and is the jaeger port-forward up?)")
        return
    print(f"   trace {tid}")
    for s in sorted(data[0]["spans"], key=lambda x: x["startTime"]):
        t = {x["key"]: x["value"] for x in s["tags"]}
        bits = []
        for key, lab in (("gen_ai.usage.input_tokens", "in"), ("gen_ai.usage.output_tokens", "out"),
                         ("aisanbox.exit_code", "exit")):
            if key in t:
                bits.append(f"{lab}={t[key]}")
        args = t.get("gen_ai.tool.call.arguments", "")
        print(f"   {s['operationName']:<28} {int(s['duration'])/1000:>6.0f}ms  "
              f"{' '.join(bits):<18} {args[:64]}")
    print(f"   ui: http://localhost:16686/trace/{tid}")


def kernel_events():
    """Pull this sandbox's PROCESS_EXEC records straight off the node.

    One JSON object per line in Tetragon's export, so filter by pod first and
    parse line by line —— a byte-truncated stream silently breaks a whole
    JSON decoder at its first bad line, which is how "0 events" got mistaken
    for "the policy did not fire".
    """
    cmd = ["kubectl", "--context", CTX, "-n", "kube-system", "exec", "ds/tetragon",
           "-c", "tetragon", "--", "sh", "-c",
           f'grep -h "\\"name\\":\\"{SANDBOX}\\"" /var/log/tetragon/tetragon*.log 2>/dev/null | tail -n 4000']
    raw = subprocess.run(cmd, capture_output=True, text=True).stdout
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        p = (o.get("process_exec") or {}).get("process") or {}
        if p.get("pod", {}).get("name") != SANDBOX:
            continue
        a = p.get("arguments", "")
        if a and "agent.py" not in a:
            out.append((p.get("binary", ""), a, p.get("uid")))
    return out


def tool_calls(tid):
    d = jaeger(f"/api/traces/{tid}")
    out = []
    for tr in d.get("data") or []:
        for s in tr["spans"]:
            if s["operationName"].startswith("tool."):
                t = {x["key"]: x["value"] for x in s["tags"]}
                out.append((s["operationName"], t.get("gen_ai.tool.call.arguments", "")))
    return out


def quota():
    """Print the tenant's own budget. Part of the demo: the quota the agent
    runs inside is visible and attributable before anything starts."""
    out = subprocess.run(["kubectl", "--context", CTX, "-n", NS, "get", "resourcequota",
                          "-o", "json"], capture_output=True, text=True).stdout
    try:
        items = json.loads(out).get("items") or []
    except Exception:
        items = []
    if not items:
        print("   (这个 namespace 没有 ResourceQuota —— 说明租户合同没接上)")
        return
    q = items[0]
    used, hard = q["status"]["used"], q["spec"]["hard"]
    print(f"   租户配额 {q['metadata']['name']}  used / hard:")
    for k in sorted(hard):
        if k.startswith(("limits.", "requests.", "count/")):
            print(f"     {k:<20} {used.get(k, '0')} / {hard[k]}")
    print("   注意: 一个 OpenShell 沙箱 = agent 容器 + 它的 supervisor 容器，两者都计入租户配额。")


def main():
    if MODE == "quota":
        quota()
        return 0
    if MODE == "trace":
        show_trace(trace_id_for(SANDBOX))
        return 0
    if MODE == "join":
        tid = trace_id_for(SANDBOX)
        ks, ts = kernel_events(), tool_calls(tid)
        # Only the agent's own uid: the sandbox runs as uid 10001, so node- and
        # container-init noise (uid 0) is filtered out rather than shown as "work".
        mine = [k for k in ks if str(k[2]) == AGENT_UID]
        print(f"   trace 里 {len(ts)} 次 tool call；内核记录了 {len(mine)} 次该 agent uid({AGENT_UID}) 的 exec")
        for name, args in ts:
            print(f"   [trace] {name:<14} {args[:74]}")
        for b, a, _ in mine:
            matched = any(norm(a) in norm(t) or norm(t) in norm(a) for _, t in ts)
            print(f"   [内核 ] {b.split('/')[-1]:<14} {a[:58].replace(chr(10), ' ')\
}{'   <- 对上' if matched else ''}")
        return 0
    print(f"unknown mode {MODE}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
