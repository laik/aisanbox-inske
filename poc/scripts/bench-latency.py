#!/usr/bin/env python3
"""测量 agent-sandbox 冷启动 vs 预热池认领的延迟差 —— 这是"可持续/稳定"的量化依据。"""
import subprocess, time, json, sys, shutil

NS = "acme"
COLD = "/tmp/aisanbox-cold.yaml"
COLD_TMPL = """apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata: {name: "%s", namespace: "%s"}
spec:
  podTemplate:
    spec:
      containers:
        - name: agent
          image: python:3.12-alpine
          command: ["python3","-u","-c"]
          args: ["import time\\nwhile True: time.sleep(30)"]
          resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}
"""
POOL_TMPL = """apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: "%s", namespace: "%s"}
spec: {warmPoolRef: {name: "agent-pool"}}
"""

def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw)

def wait_ready(kind, name, timeout=180):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = sh("kubectl", "-n", NS, "get", kind, name, "-o", "json")
        try:
            d = json.loads(r.stdout)
            if any(c["type"] == "Ready" and c["status"] == "True"
                   for c in d.get("status", {}).get("conditions", [])):
                return time.time() - t0
        except Exception:
            pass
        time.sleep(0.15)
    return None

def main():
    # A) 冷启动: 直接创建 Sandbox
    open(COLD, "w").write(COLD_TMPL % ("bench-cold", NS))
    sh("kubectl", "delete", "sandbox", "bench-cold", "-n", NS, "--ignore-not-found")
    time.sleep(5)
    sh("kubectl", "apply", "-f", COLD)
    cold = wait_ready("sandbox", "bench-cold")
    print(f"cold-start Ready: {cold:.2f}s" if cold else "cold-start: TIMEOUT")
    sh("kubectl", "delete", "sandbox", "bench-cold", "-n", NS, "--ignore-not-found")

    # B) 预热池认领
    time.sleep(10)
    claim = "bench-claim"
    open("/tmp/aisanbox-claim.yaml", "w").write(POOL_TMPL % (claim, NS))
    sh("kubectl", "delete", "sandboxclaim", claim, "-n", NS, "--ignore-not-found")
    time.sleep(3)
    t0 = time.time()
    sh("kubectl", "apply", "-f", "/tmp/aisanbox-claim.yaml")
    warm = wait_ready("sandboxclaim", claim)
    print(f"warm-claim Ready: {warm:.2f}s" if warm else "warm-claim: TIMEOUT")
    if cold and warm:
        print(f"speedup: {cold/warm:.1f}x")

if __name__ == "__main__":
    main()
