#!/usr/bin/env python3
"""rm-guard responder —— Tetragon 事件 → openshell CLI 拒绝 + 暂停。

POC 形态：跑在宿主（边界外），kubectl exec 进 tetragon pod 拉事件流，
持 openshell CLI 凭据执行强制。沙箱内进程拿不到这条链的任何凭据。
生产形态：集群内 Deployment + 专用 SA + tetragon gRPC（见 DESIGN.md §7）。

用法：
  python3 responder.py --once          # demo：触发一次强制后退出
  python3 responder.py --loop          # 持续值守（每个 sandbox 触发一次）
时间线落 --timeline（jsonl），每行带 UTC 时间戳，供逐帧回放。
"""
import argparse
import datetime
import json
import os
import queue
import select
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


class Responder:
    def __init__(self, a):
        self.a = a
        self.pod = f"{a.workspace}--{a.sandbox}"
        self.done = set()          # 已强制过的 sandbox（去重）
        self.tl = open(a.timeline, "a", buffering=1)
        self.cli = [a.cli, "-g", a.gateway, "--workspace", a.workspace]
        self.k = ["kubectl", "--context", a.context]
        self.lock = threading.Lock()   # log 被读线程与主线程并发调用

    def log(self, kind, **kw):
        rec = {"t": now(), "kind": kind, **kw}
        brief = {k: v for k, v in kw.items() if k not in ("event", "output")}
        with self.lock:
            self.tl.write(json.dumps(rec, ensure_ascii=False) + "\n")
            print(f"[{rec['t']}] {kind} {json.dumps(brief, ensure_ascii=False)}", flush=True)
            if "output" in kw:
                for line in str(kw["output"]).strip().splitlines()[:6]:
                    print(f"    | {line}", flush=True)

    def run(self, cmd, timeout=90):
        t0 = time.monotonic()
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {
            "cmd": " ".join(cmd),
            "rc": p.returncode,
            "output": (p.stdout + p.stderr).strip(),
            "elapsed_s": round(time.monotonic() - t0, 3),
        }

    def find_tetragon_pod(self):
        node = subprocess.run(
            self.k + ["-n", self.a.namespace, "get", "pod", self.pod,
                      "-o", "jsonpath={.spec.nodeName}"],
            capture_output=True, text=True, check=True).stdout.strip()
        out = subprocess.run(
            self.k + ["-n", "kube-system", "get", "pods",
                      "-l", "app.kubernetes.io/name=tetragon",
                      "--field-selector", f"spec.nodeName={node}",
                      "-o", "jsonpath={.items[0].metadata.name}"],
            capture_output=True, text=True, check=True).stdout.strip()
        self.log("topology", workload_pod=self.pod, node=node, tetragon_pod=out)
        return out

    def enforce(self, ev):
        """0.1.7 实测强制链：先暂停（立即 containment）后拒绝（全局锁）。

        - suspend 优先（保留内存态）；kubernetes compute driver 不支持时
          回退 stop（保 workspace PVC）。
        - "拒绝"不能用 sandbox 级 policy set（0.1.7 只增不减，移除 RW 路径
          被拒）；用 gateway 全局锁 policy set --global：肇事 sandbox 下次
          start 即只读。运行中的其它 sandbox 不受影响（landlock 实例级）。
        """
        sb = self.a.sandbox
        t_detect = now()
        self.log("detect", sandbox=sb, t_detect=t_detect, event=ev)

        r = self.run(self.cli + ["sandbox", "suspend", sb])
        if r["rc"] != 0:
            self.log("suspend-failed", **r)
            r = self.run(self.cli + ["sandbox", "stop", sb])
            self.log("pause", action="sandbox stop (suspend 回退)", **r)
        else:
            self.log("pause", action="sandbox suspend", **r)
        pause_ok = r["rc"] == 0

        r = self.run(self.cli + ["policy", "set", "--global", "--policy",
                                 os.path.join(HERE, "policy-lockdown.yaml"),
                                 "--yes"])
        self.log("deny", action="policy set --global lockdown", **r)
        deny_ok = r["rc"] == 0

        r = self.run(self.cli + ["sandbox", "get", sb])
        self.log("state", **r)
        self.done.add(sb)
        self.log("enforced", sandbox=sb, deny_ok=deny_ok, pause_ok=pause_ok,
                 t_detect=t_detect, t_done=now())
        return deny_ok and pause_ok

    PROBE = "/sandbox/.rmguard-probe"

    def is_probe(self, kp):
        return any(self.PROBE in (a.get("string_arg") or "")
                   for a in kp.get("args", []))

    def is_trigger(self, kp):
        if self.is_probe(kp):
            return False
        msg = kp.get("message", "")
        proc = kp.get("process", {})
        if msg == "rmguard:file-delete":
            return True
        if msg == "rmguard:rm-exec":
            argv = proc.get("arguments", "")
            # 精确判定：rm 带递归/强制旗标且目标是 canary（argv 来自进程缓存）
            flags = ("-rf" in argv or "-fr" in argv
                     or ("-r" in argv.split() and "-f" in argv.split())
                     or "--recursive" in argv)
            return flags and "/sandbox/canary" in argv
        return False

    def stream(self):
        tp = self.find_tetragon_pod()
        cmd = self.k + ["-n", "kube-system", "exec", tp, "-c", "tetragon", "--",
                        "tetra", "getevents", "-o", "json",
                        "--policy-names", "rm-guard,rm-guard-files"]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        attached = threading.Event()
        triggers = queue.Queue()
        stop = threading.Event()

        # 读线程持续排空管道：enforce() 会阻塞主线程数秒（stop+全局锁），
        # 期间删除事件仍在涌来；若不并发排空，64KB 管道缓冲会溢出丢事件
        # （实测：主线程串行读时 200 条 file-delete 全丢）。读线程只记录+
        # 投递触发候选，强制动作仍在主线程串行执行。
        def reader():
            fd = p.stdout.fileno()
            buf = b""
            while not stop.is_set():
                r, _, _ = select.select([fd], [], [], 0.5)
                if not r:
                    continue
                chunk = os.read(fd, 65536)
                if not chunk:
                    self.log("stream-eof")
                    attached.set()  # 唤醒主线程退出
                    return
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    line = raw.decode(errors="replace").strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    kp = ev.get("process_kprobe")
                    if not kp or kp.get("policy_name") not in ("rm-guard", "rm-guard-files"):
                        continue
                    pod = (kp.get("process", {}).get("pod") or {}).get("name", "")
                    if pod != self.pod:
                        continue
                    if self.is_probe(kp):
                        if not attached.is_set():
                            self.log("probe-ok", event_time=ev.get("time"))
                            self.log("listening", cmd=" ".join(cmd))
                            attached.set()
                        continue
                    if not attached.is_set():
                        continue
                    self.log("event", message=kp.get("message"),
                             binary=kp.get("process", {}).get("binary"),
                             arguments=kp.get("process", {}).get("arguments"),
                             args=kp.get("args"), event_time=ev.get("time"))
                    if self.a.sandbox not in self.done and self.is_trigger(kp):
                        triggers.put(ev)

        th = threading.Thread(target=reader, daemon=True)
        th.start()
        try:
            # 正对照：kubectl exec 的 gRPC 流要 1~2s 才真正挂上，"进程起了"
            # 不等于"在听"。周期性发无害探针删除，亲眼看到一条才算就绪。
            def send_probe():
                pr = self.run(self.cli + ["sandbox", "exec", self.a.sandbox, "--",
                                          "sh", "-c",
                                          f"echo p > {self.PROBE} && rm -f {self.PROBE}"])
                self.log("probe-sent", rc=pr["rc"])

            send_probe()
            t0 = time.monotonic()
            last_probe = t0
            while not attached.is_set():
                if time.monotonic() - t0 > 45:
                    self.log("probe-timeout",
                             hint="事件通道 45s 未见探针事件，拒绝宣布就绪")
                    return 1
                if time.monotonic() - last_probe > 3:
                    send_probe()
                    last_probe = time.monotonic()
                attached.wait(1.0)
            if stop.is_set():
                return 1
            # 等攻击触发（demo 里攻击随后就到；给足交互录屏时间）
            try:
                ev = triggers.get(timeout=900)
            except queue.Empty:
                self.log("no-trigger", hint="900s 无危险动作")
                return 0
            ok = self.enforce(ev)
            time.sleep(2)  # 让读线程把缓冲里剩余的删除事件落盘（取证完整）
            if self.a.once:
                return 0 if ok else 1
            # loop 模式：继续等下一个触发
            while not stop.is_set():
                try:
                    ev = triggers.get(timeout=1.0)
                except queue.Empty:
                    continue
                self.enforce(ev)
            return 0
        finally:
            stop.set()
            p.terminate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sandbox", default="rm-guard")
    ap.add_argument("--workspace", default="poc-shared")
    ap.add_argument("--gateway", default="poc2-a")
    ap.add_argument("--namespace", default="tenant-a-runtime")
    ap.add_argument("--context", default="kind-agent-runtime-poc")
    ap.add_argument("--cli", default="/root/poc2/vendor/openshell-cli-0.1.7/openshell")
    ap.add_argument("--timeline", default=os.path.join(HERE, "timeline.jsonl"))
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--loop", action="store_true")
    a = ap.parse_args()
    r = Responder(a)
    if a.loop:
        while True:
            try:
                r.stream()
            except Exception as e:  # 断流重连
                r.log("stream-error", error=str(e))
                time.sleep(3)
    else:
        sys.exit(r.stream())


if __name__ == "__main__":
    main()