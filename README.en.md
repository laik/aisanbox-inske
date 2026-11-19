# aisanbox-inske · Multi-Tenant AI Agent Sandbox POC

> **Give every tenant an AI agent sandbox that is both controllable and observable.**
> Provision a tenant → the tenant's own OpenShell Gateway → a Pi sandbox with policy and credential boundaries →
> model calls proxied through the Supervisor → process and network records at the kernel layer.

This file is the **single source of conclusions**: verdicts for POC-01..11 and SEC-01..14, structural conclusions,
recommended revisions to the POC2 design document, what production still needs, and a
**manual verification checklist** (§7, commands you can paste). The Chinese version is [`README.md`](README.md).
The design itself is [`POC2.md`](POC2.md) (round 2) and [`POC3.md`](POC3.md) (round 3, unified permissions, verdicts in **§12**); the **verbatim evidence** (error texts, log lines) for every row is in
[`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md).

> **How to read this file:** there are only three verdicts — `✅ verified`, `⚠️ partial / conditional`,
> `❌ not verified`. A design expectation is never written as a measured result (POC2 §14.3 requires this).
> Every ✅ has a paste-able re-check command in §7.

---

## 1. Conclusion in one paragraph

This combination (Capsule + agent-sandbox + OpenShell + Antrea + Gatekeeper + Tetragon + OTel) ran its **main chain end
to end** in the kind cluster at `root@192.168.5.190` (3 nodes / K8s v1.37 / Ubuntu 24.04 host) in **POC2 shared mode**
(one Gateway serves exactly one tenant), and on **2026-11-09 the claims that had been left unverified were completed**:

- three Sandboxes on one Workspace with different permissions (Developer writable / two Reviewers read-only) — POC-04
- one Agent changing code while two others review it read-only in parallel — POC-10
- Trace / OCSF / kernel events correlated to the same sandbox through `openshell.sandbox.id` — POC-11
- cross-tenant networking, the two enforcement layers behind read/write separation, and where Supervisor-disconnect
  fail-closed actually applies — SEC-04/06/07/08/12

**One item remains unverified: Tetragon's enforcement capability** — blocked by the host kernel's LSM list (no `bpf`),
which is an environment precondition, not a missing feature.

The most valuable finding of this round is about **how things were measured**, not about what is missing. Of the verdicts
recorded wrongly at first (the last one was wrong during this round's own re-measurement, and is recorded here for that reason):

| Original verdict | Real cause |
|---|---|
| POC-08 ❌ "Pi traces are not there" | traces were queried by the **wrong `service.name`** (`pi-agent` vs the default `pi`) — `pi-otel` reads config only from `~/.pi/agent/settings.json` or `<cwd>/.pi/settings.json`, and we wrote it at the agent-dir root, so the config was **silently ignored** |
| POC-09 ⚠️ "OCSF cannot go over OTLP" | **a key the chart does not expose was treated as a product gap** — the binary contains `otlp.ocsf` and the `openshell_ocsf_otlp_*` metrics |
| POC-04 / SEC-06 ❌ "shared Workspace does not hold" | **the policy file had no enforcing content** — `policies/pi-reviewer.yaml` was byte-identical to the developer's YAML, while its comments already claimed read-only |
| SEC-04/08 ✅ "cross-tenant denied" (wrong attribution) | the denial comes from **NetworkPolicies OpenShell generates itself**, not from Capsule/Antrea tenant isolation; at the platform layer there were **no** tenant network policies at all |
| SEC-12 "data plane `http=200`" ❌ the number does not reproduce | **the method was wrong twice**: (1) a NetworkPolicy cut was treated as "the Gateway is disconnected" — it cuts the supervisor's egress instead; (2) the data plane was probed with `openshell sandbox exec`, a channel that **goes through the Gateway itself** and returns `transport error` the moment the Gateway is down. Only after scaling the StatefulSet to 0 and running the call as a loop inside the sandbox does the conclusion hold (§5.6) |

All four were measurement or documentation errors; the features work once measured correctly. The §7 checklist exists so
that "how it was measured" stops depending on memory.

---

## 2. Status summary

| Verdict | What |
|---|---|
| ✅ Works | Tenant provisioning → per-tenant Gateway (own mTLS / own `gateway_id` / own SQLite PVC) → Capsule quota really governs sandboxes → credentials injected through the Provider proxy (the sandbox only holds a placeholder) → model calls recorded by the Supervisor at L7 (OCSF; OCSF over OTLP proven) |
| ✅ Works | **Three Sandboxes share one Workspace with different permissions**, including across nodes; one Agent edits code while two review read-only in parallel; neither Reviewer wrote a single byte |
| ✅ Works | Antrea as sole CNI: traffic passes with no policy, deny-all blocks it, the allow-list admits only the selected Pod — 9/9, verified in the Antrea control plane and OVS flow tables, cross-node included; Gatekeeper rejects privileged, hostNetwork, hostPID, hostPath and borrowed platform SAs with identity-level precision |
| ✅ Works | Tetragon **observation**: exec / exit / connect (5-tuple) / parent / Pod identity; traces, OCSF and kernel events correlate to one sandbox via `openshell.sandbox.id` |
| ⚠️ Partial | Tetragon **enforcement**: lsm-hook policies fail to load on this host (no `bpf` in the LSM list); kprobe-based work and the `security_socket_connect` override work fine |
| ✅ Works (POC3, round 3) | **One permission system governs both K8s and OpenShell**: LDAP → Keycloak → one OIDC JWT → apiserver (OIDC + RBAC, per tenant namespace) and one OIDC Gateway (two Workspaces). Identity is the directory `entryUUID`; both sides read the same `groups` claim (§12) |
| ✅ Works (POC3) | **Platform-level multi-tenant network isolation**: Capsule `networkPolicies` now populated in all 4 tenant namespaces; cross-tenant ordinary Pod `BLOCKED`, same-tenant positive control `REACHED` (§5.4 corrected). ⚠️ NetworkPolicy stays additive (a tenant can widen it, §12.2 N-04) |
| ✅ Works (POC4, round 4) | **Gateway as a Deployment on external PostgreSQL**: two independent Helm releases (p4a/p4b) share one PostgreSQL and its control-plane state; two replicas of one release are HA; sandbox visibility comes from the shared runtime namespace, not PostgreSQL (§13) |
| ❌ Not verified | Observability backend persistence and retention (Jaeger is in-memory); automatic propagation of directory changes into tokens (Keycloak 26.4 has no working LDAP sync endpoint, §12.4/§12.6-h); **concurrent writes** and the **KEK decrypt-failure path** when several gateways share one database (§13.3) |

**Note:** round 1's conclusions document (operator mode, a Mac with two kind clusters) was deleted and survives only in
git history. Its conclusions **do not transfer** to shared mode. Round 1's raw evidence remains in
[`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md).

---

## 3. Item-by-item verdicts (POC2 IDs)

### 3.1 Capability items POC-01..11

| ID | Verdict | Evidence |
|---|---|---|
| POC-01 Per-tenant independent Gateway | ✅ | Each Gateway authenticates over its own mTLS, has its own `gateway_id` and its own SQLite PVC; both create a workspace named `poc-shared` yet neither sees the other; `auth can-i` shows A's SA as `no` in B's runtime ns |
| POC-02 Capsule tenant isolation | ✅ (stronger than expected) | Ownership is injected by the webhook only at creation time (no retroactive adoption); `ForceTenantPrefix` blocks cross-tenant naming; the quota really did govern sandboxes created by OpenShell: `exceeded quota: capsule-tenant-a-0, requested: limits.memory=1Gi, used: 2Gi, limited: 2560Mi` |
| POC-03 One Gateway manages multiple Sandboxes | ✅ (3 concurrent) | `pi-dev` + `pi-review-1` + `pi-review-2` Ready at the same time. **Two separate quota dimensions had blocked the third**, neither an OpenShell defect: (1) `count/services` — every sandbox creates **two Services** (`os-boundary-<pair>` + `os-supervisor-<pair>`); (2) `requests.memory` — a Pi sandbox's requests are 1Gi (agent) + 128mi (its own supervisor) ≈ **1.15Gi**, while the CLI only says `timed out waiting for gated workload Pod`. Arithmetic is in `poc/capsule2/tenants.yaml` |
| POC-04 Multiple Sandboxes share a Workspace | ✅ (incl. cross-node) | `pi-dev` mounts `shared-workspace` RW, clones the project, runs `go test`, and has Pi write a **new test that actually passes** (`poc_extra_test.go`); both Reviewers mount the same PVC read-only, **both see that file** (visible in `git status`, `wc -l` non-empty), and their writes are denied. Cross-node holds too: dev ran on `worker2` while a sandbox forced by `node_selector` onto `worker` read the same file and was likewise denied. The direct reason for the earlier ❌ was that the reviewer policy's YAML was byte-identical to the developer's |
| POC-05 Antrea network isolation | ✅ | 9/9: traffic passes with no policy, deny-all blocks it, the allow-list admits only the selected Pod; verified in the Antrea control plane and OVS flow tables (123→135→123) across nodes |
| POC-06 Gatekeeper admission | ✅ (with precise scope) | privileged / hostNetwork / hostPID / hostPath / borrowing a platform SA are all rejected by `[poc-tenant-pod-boundary]`; **within the same ns** the platform SA identity passes while the tenant identity is rejected — no namespace-level exemption |
| POC-07 Tetragon behavior observability | ✅ observation / ⚠️ enforcement | exec, exit, connect (5-tuple), parent, pod/namespace/container/image identity all appear in events. But this host's kernel LSM list is `lockdown,capability,landlock,yama,apparmor` (**no `bpf`**), so lsm-hook policies fail to load |
| POC-08 Pi OTel traces | ✅ | `GET /api/traces?service=pi-agent` returns a full trace: `invoke_agent pi` / `chat qwen3.8-flash-next` / `pi.turn`, with `openshell.sandbox.id`, `openshell.telemetry.source=agent`, `host.name=poc-shared--pi-*` and `process.*` in the resource. After the config path was fixed, span names take the shape POC2 §6.3 expects — which is itself proof the settings were read |
| POC-09 OpenShell telemetry | ✅ (OCSF over OTLP proven) | Gateway/driver/supervisor traces reach both backends and OCSF decisions are complete in the Supervisor logs. `[openshell.gateway.otlp.ocsf] enabled = true` **works**: the Gateway's startup log shows `ocsf_endpoint=…`, its own metrics show `openshell_ocsf_otlp_exported_total 3` (no errors), and the Collector receives records with scope `openshell.ocsf` carrying structured attributes such as `ocsf.class_uid: Int(3002)`. Two caveats: OCSF flows through the Collector's **logs** pipeline, not traces; `ocsf_log` (JSONL) is a **parallel** second channel, worth keeping as offline evidence |
| POC-10 Multi-Agent collaboration | ✅ platform side / ⚠ model side not deterministic | dev changes code (one new passing test) → `pi-review-1` and `pi-review-2` read the same workspace **in parallel**; afterwards `git status` still shows only dev's one untracked file — **neither Reviewer wrote a single byte**. The platform side (shared visibility + read-only enforcement + parallelism without mutual exclusion) is **certain**. ⚠ But "each Agent produces its own review" is **not deterministic**: the local model sometimes **returns nothing** (on the 2026-11-09 re-run `/tmp/rev-1.out` was 0 bytes while `rev-2.out` had content, and `pi` still exited 0). That is model capability, not a platform defect — do not present an empty answer as a platform problem, and do not count it as a platform capability either |
| POC-11 Security event correlation | ✅ | The correlation key is `openshell.sandbox.id`, and **all three streams carry it**: (1) traces — supervisor spans carry `sandbox.id`/`sandbox.name`, Pi span resources carry `openshell.sandbox.id` (added by the relay, source `otlp_relay/enrichment.rs`); (2) Kubernetes — the same UUID is the `openshell.ai/boundary-pair` label on both the workload and the supervisor Pod; (3) kernel/OCSF — matched by Pod name, shown for one and the same curl: Tetragon gives `binary=/usr/bin/curl`, argv, `uid=10001`, `pod.name=poc-shared--pi-review-2`, `pod.uid`, container and image, and **in the same second** the Supervisor gives `OCSF NET:OPEN [MED] DENIED /usr/bin/curl(0) -> api.openai.com:443 [reason:transparent_tcp_policy_denied]`. Join path: `trace(sandbox.id)` == `pod label boundary-pair` == `pod name` == Tetragon's `pod.name` == that supervisor's OCSF lines |

### 3.2 Security cases SEC-01..14

| Case | Result | Observed |
|---|---|---|
| SEC-01 Pi curls an unauthorized domain directly | ✅ | `api.openai.com` / `example.com` fails within **4–6 ms** (`Couldn't connect`, not a timeout) |
| SEC-02 Approved endpoint through the Supervisor | ✅ | the model endpoint is recorded as `OCSF HTTP:POST ALLOWED … engine:l7` |
| SEC-03 Unapproved domain | ✅ | Same as SEC-01; the policy name is visible in the event (`_provider_poc_model`) |
| SEC-04 / SEC-08 Cross-tenant networking | ✅ platform capability (POC3) | See §5.4: since 2026-11-10 Capsule's `spec.networkPolicies` is non-empty and `capsule-tenant-<t>-0` exists in all 4 tenant namespaces; a cross-tenant ordinary Pod is **`BLOCKED`** while the same-tenant positive control is **`REACHED`** (cases N-01..N-05). The sandbox side is still blocked by the two policies OpenShell generates (L4) |
| SEC-05 Agent accesses the Kubernetes API | ✅ | `kubernetes.default.svc:443` is denied |
| SEC-06 Reviewer read-only | ✅ (two layers proven separately) | See §5.5: with mount ro + policy ro the write is denied; with **only the policy** enforcing (mount rw) it is also denied, errno `EACCES`; with **only the mount** enforcing, errno is `EROFS`. Two independent enforcement chains |
| SEC-07 Developer writable | ✅ | `DEV_WRITE_OK`, and `mountinfo` shows `rw,relatime` |
| SEC-09 Unsafe Pod | ✅ | See POC-06 |
| SEC-10 Tenant creates a Sandbox CR directly | ✅ | Tested as two layers: RBAC denies first; **after deliberately granting the tenant the permission**, `[poc-managed-cr-only-platform]` still denies |
| SEC-11 Agent cannot read the Provider token | ✅ | Inside the sandbox `OPENAI_API_KEY=openshell:resolve:env:v7305…_OPENAI_API_KEY`, a **proxy placeholder**; the real key is injected only at the boundary (a successful request proves it) |
| SEC-12 Supervisor fail-closed on lost connection | ✅ measured; verdict split by control/data plane | See §5.6. The disconnect is `scale statefulset/os-a-openshell 0`. **Data plane does not fail closed**: during the outage the sandbox keeps receiving model replies (the `DATA_PLANE_OK` count keeps growing — 3→9 and 3→8 in two runs), and the supervisor `OCSF HTTP:POST` count rises in the same window. **Control plane fails closed**: `sandbox create` produces not even a Sandbox CR (0). The supervisor's own log shows `OCSF NET:FAIL … os-a-openshell…:8080` (it notices, and still proxies). POC2 §11's bare "Fail Closed" is too coarse |
| SEC-13 Another process reaching the network without tool calls | ✅ holds, stronger than the design expects | The process under test is `node` from the image, opening a **raw socket** (not through Pi, not through any tool call). Measured: its **own supervisor:5500** = `CONNECTED` (that is the positive control — without it the whole run is unusable), everything else denied: `10.96.0.1:443` TIMEOUT, `1.1.1.1:443` (literal IP, DNS skipped) TIMEOUT, DNS resolution `EAI_AGAIN`. What blocks it is not the L7 policy but the two NetworkPolicies from §5.4 (**L4**) — so "step around the Agent tool layer" is not a path that exists. Re-check: the SEC-13 section of `phases/13-security-matrix.sh` |
| SEC-14 Using an unapproved PVC | ✅ | No label / mismatched label value → `external resource not admitted by required labels`; matching label value → allowed |

### 3.3 Sandbox lifetime (measured; it affects evidence retention)

A sandbox lives exactly as long as the command passed to it. After `-- sleep 1800` expires the phase becomes `Completed`,
and every later `sandbox exec` returns `Error: sandbox 'x' is not ready (phase: Completed)`. It is not a timeout and it
was not reclaimed. **A `Completed` sandbox still occupies its two Services and its PVC quota** — you must really run
`sandbox delete`. For the "run a task, then inspect observability" workflow this means either a long enough keepalive,
or `--restart-policy` with a genuinely long-lived process. Consequence: the data stays in the observability backend, but
the workload that produced it can no longer be queried.

---

## 4. Why this stack

Each component owns one segment; the interfaces are native Kubernetes objects, with no glue code in between.

| Layer | Component | Owns exactly this |
|---|---|---|
| Tenant contract | Capsule | Namespace ownership, quota ceilings, cross-tenant naming rejection |
| Workload orchestration | agent-sandbox (SIG Apps) | `Sandbox` CR: stable identity, lifecycle, persistent storage |
| Execution boundary | OpenShell | Filesystem, network egress, credential brokerage, and a per-tenant Gateway |
| Network isolation | Antrea | Real NetworkPolicy enforcement and micro-segmentation |
| Admission control | OPA Gatekeeper | Unsafe Pods and resources rejected before persistence |
| Kernel observability | Tetragon | Ground truth for processes and connections, independent of agent self-report |
| Unified telemetry | OpenTelemetry | Pi / Gateway / Supervisor / Tetragon on one observability plane |

**Pattern verdict: shared mode composes with Capsule more simply and is easier to reason about** — one tenant = one
Capsule Tenant = one Gateway = two namespaces (gateway / runtime). Round 1's operator mode adds a layer of
"label discovery", one more invisible hand during troubleshooting. The price is that shared mode **requires the platform
to do two things itself**: place the client-TLS bundle in the runtime ns, and govern the authorization labels of external
PVCs.

| | Round 1 (operator) | This round (shared) |
|---|---|---|
| Who owns the namespace | The platform creates it, labels it `openshell.ai/workspace=true`, the Gateway claims it by label | The platform creates one dedicated runtime ns and the Gateway hard-codes `namespace =` |
| Sandbox name | Bare name (the namespace provides isolation) | `{workspace}--{name}` (the namespace provides no isolation) ← source `driver-kubernetes/config.rs` |
| How client-TLS reaches the Supervisor | The driver injects it into each generated bootstrap Secret | **The platform must copy the Secret into the tenant runtime ns** |
| What one Gateway covers | Multiple namespaces | One namespace |
| Integration with Capsule | Label contract | **Namespace ownership contract** (more direct) |

---

## 5. Structural conclusions (about this combination, not a bug in one component)

### 5.1 The coverage of platform defaults decides how many policies you must write

Given no filesystem policy, the OpenShell baseline is `/bin /usr /lib /proc /dev/urandom /etc /var/log` read-only and
`/tmp /dev/null` read-write. **It includes neither `/opt` nor `/data`.** So the same class of error appears in two places:

- Pi's agent directory lives under `/opt` → `Permission denied` inside the sandbox, while `ls -ld` shows mode `0755 root`
  (uid 10001 ought to be able to read it) — **the error points at Unix permissions but is really the policy boundary**;
- the shared PVC is mounted at `/data/workspace` → the same `Permission denied`, while **the same PVC mounted into an
  ordinary Pod** is read-write for uid 10001.

**Conclusion: "which paths the policy baseline covers" is part of the platform contract.** Any path outside the baseline
(agent directory, workspace, cache) must be added to the policy explicitly and generated by the provisioning flow — not
papered over by adjusting the image. POC2 §5.3 already says "each Sandbox uses its own OpenShell policy" but not **why it
must**; the two cases above are why.

### 5.2 Sandboxes run as uid 10001, overriding the image's `USER`

The Dockerfile in POC2 §6.1 uses `USER node`; the actual sandbox runs as `uid=10001`. Therefore directories `chown`ed to
`node` in the image are not writable, and the image's `ENV PI_CODING_AGENT_DIR` is **not** passed into the sandbox. The
correct approach for the Pi image is: prepare the agent directory (including extensions) at build time and make it
**readable by every uid**, then copy it to a writable location at runtime (`poc/pi/setup-agent-home.sh`). The same trap
appeared once with `/opt` after `USER node` (`unable to find user node` at build time).

### 5.3 Credentials and network are one control point, not two layers

A Provider profile declares **the endpoint, which binaries may reach it, and where the credential lives** at once. Observed:

- OpenShell **ships no provider profile in the distribution** (the source comment says so verbatim).
  `provider create --type openai` necessarily returns `provider profile 'openai' not found` — **the platform must declare
  which hosts are allowed itself.** This is not a defect; it is a premise of the pattern.
- The comment in the official `providers/openai.yaml` explicitly requires: **an OpenAI-compatible service on another host
  needs its own profile naming that host**; do not edit the official one. This round followed that
  (`poc/providers/poc-model.yaml`).
- The storage key for a credential is the **`env_vars` name declared in the profile** (`OPENAI_API_KEY`), not the logical
  name (`api_key`). `--credential api_key=…` returns `provider credentials are not declared by profile 'poc-model': api_key`.
- **Pure egress with no credential can also be expressed** (`credentials: []` + `--provider poc-git`), which turns "the
  sandbox may reach GitHub" into an **explicit declaration** instead of a default allowance.
- ⚠️ `access: read-only` filters by **HTTP method**, not by business action. `git clone` always needs POST (smart-HTTP
  fetch negotiation), so it is denied at L7:
  `OCSF HTTP:POST [MED] DENIED POST …/git-upload-pack [policy:_provider_poc_git engine:l7]`.
  git-over-HTTPS needs `access: read-write`. And **changing a profile is not retroactive for existing Sandboxes** — the
  effective policy is snapshotted at create time.

### 5.4 Tenant network isolation: platform policies (added in POC3) plus the OpenShell boundary

**POC3 (2026-11-10) closed the platform gap and reverses this section's original title.** Measured now (cases N-01..N-05):

| Case | Measured | Meaning |
|---|---|---|
| N-01 | `capsule-tenant-<t>-0` in all 4 tenant namespaces | Capsule `spec.networkPolicies` is non-empty; the platform really provisions it |
| N-02 | tenant-a ordinary Pod → tenant-b server Pod: **`BLOCKED`** | cross-tenant traffic blocked by the platform policy (round 2 measured `REACHED`) |
| N-03 | tenant-b → tenant-b (positive control): **`REACHED`** | it is not "the network was broken anyway" |
| N-04 | after the tenant adds one permissive Ingress policy: **`REACHED`** | ⚠️ NetworkPolicy is additive; a tenant can widen the boundary |
| N-05 | after removing that policy: **`BLOCKED`** | the boundary comes back |

So the statement is now: **tenant-to-tenant network isolation is a platform capability**, and it is **additive** — to make
it "drawn once, not changeable" you need Capsule `spec.rules.enforce.policies` or an Antrea ClusterNetworkPolicy owned by
the platform. ⚠️ In Capsule 0.15.2 `spec.networkPolicies` is already deprecated; rewrite with TenantReplications before upgrading.

**On the OpenShell sandbox side the mechanism is still the two policies OpenShell itself creates**
(the two layers add up; they are independent of the platform policy):

   ```
   openshell-sandbox-workloads:  policyTypes=[Ingress,Egress], but only ingress rules are defined
                                 ⇒ Egress is declared with zero rules = all workload egress is DENIED
   os-control-<boundary-pair>:   the single allowed egress = supervisor:5500 of the same boundary-pair
   ```

   So "a sandbox can only reach its own supervisor" is not an allowlist inside one policy: it is deny-all (implied by the
   empty egress) plus one pair-local allowance. ⚠️ When collecting this evidence, do **not** print only
   `openshell-sandbox-workloads`'s `.spec.egress` — it is legitimately empty, so that column carries no evidence; also read
   `os-control-<pair>`'s `.spec.egress[0].to` (the script now reads both).

**The two claims must be stated separately** (POC2 §9 / §11 conflate them):

- **"An Agent cannot bypass the Supervisor to reach the network" holds** — enforced by the two L4 NetworkPolicies on the
  sandbox workload.
- **"Isolation between tenants" is a platform capability** (an ordinary Pod of tenant A cannot enter tenant B's
  namespace), but it is additive, so the platform must decide whether to tighten it so tenants cannot change it.

⚠️ History: in round 2 `spec.networkPolicies` was **empty** and two ordinary Pods across tenants were `REACHED`, so the
conclusion then was "isolation is only a side effect of the OpenShell boundary". That conclusion is **retracted** and
survives only in git history.

⚠️ When testing this, **the target Pod must really listen on the probed port**, otherwise `nc -z` always fails and the
`NOT_REACHED` you get means "nobody is listening", not "a policy blocked it". This round hit a second variant of the same
trap: **busybox `nc -l` serves one connection and exits**, so a "prove the listener is alive" step consumes the listener
and guarantees the next test fails. Use `while true; do nc -l -p <port> </dev/null; done`, probe the listener only on
127.0.0.1, and confirm the Pod is still Running *after* the cross-tenant probe. Two rounds produced opposite conclusions
here; the only difference was whether a listener existed.

One more measurement on the same mechanism (SEC-13): **there is no "use another process to step around the Agent tool
layer" path.** Using `node` from the image to open a raw socket directly (no Pi, no tool call), it reaches **its own
supervisor:5500** = `CONNECTED` (the positive control), and everything else is denied: the Kubernetes API `TIMEOUT`, a
hard-coded `1.1.1.1:443` (DNS skipped) `TIMEOUT`, `dns.lookup` = `EAI_AGAIN`. What blocks it is plainly the two
NetworkPolicies above (**L4**), not OpenShell's L7 policy — so giving a sandbox any extra egress (a self-built proxy, a
different agent runtime) means editing the NetworkPolicy; changing the L7 policy is not enough.
⚠️ This test **requires a positive control**: measured once with an empty Service clusterIP, `CONNECTED` turned into
`ECONNREFUSED`, which reads as "blocked by the boundary" when there was in fact no address at all.

### 5.5 Read/write separation is **two independent enforcement chains**; testing one breaks when the other drifts

| Configuration | mountinfo | Result of a write | Enforced by |
|---|---|---|---|
| mount rw + policy read-only | `rw,relatime` | `touch: … Permission denied` (EACCES) | the OpenShell policy layer (syscall level, in the agent process) |
| mount ro + policy writable | `ro,relatime` | `Read-only file system` (EROFS) | the Kubernetes mount layer |
| both closed (the Reviewers' real config) | `ro,relatime` | EROFS | both layers |

The different errno values prove these are two chains, not one policy written two ways. **Keep both in production.**
POC2 §10.5 requires "actually execute inside the Reviewer container; do not just read the PVC's readOnly field" — that
requirement is right: the direct cause of this round's ❌ was that the policy file's YAML was byte-identical to the
developer's and only the comments differed.

⚠️ Do not read the mount flags by fixed field number. In `/proc/self/mountinfo` field 4 is the mount root, 5 is the mount
point, and 6 is the mount options — with optional fields such as `shared:`/`master:` possibly in between. With
`awk '{print $4}'` both dev and reviewer printed `/`, identical in both cases, so that column of evidence was effectively
untested (hit this round). The correct form is "find the field equal to the mount point, print the field after it".

### 5.6 Supervisor disconnect: the data plane does not fail closed, the control plane does (measured) (measured)

The sandbox Pod's **only** egress path is its own supervisor (`os-control-<pair>` egress goes only to it), while the
supervisor's egress is **fully open**:

```
kubectl --context $CTX -n $NS get netpol openshell-sandbox-supervisors \
  -o jsonpath='{.spec.policyTypes} {.spec.egress}'
#   ["Egress"] [{}]   <== Egress is managed, but there is no `to` at all — egress is unrestricted
```

The disconnect must be done with **`kubectl scale statefulset/os-a-openshell --replicas=0`** (the Gateway is a
StatefulSet; `scale deployment/...` returns `Error from server (NotFound)`). Measured on 2026-11-09, reproducible as a
block in the SEC-12 section of `phases/13-security-matrix.sh`:

- **The data plane does not fail closed**: a loop inside the sandbox calling the model every 20 s keeps **getting answers**
  through the outage. The absolute counts vary per run (measured twice: `3 → 5 → 9` and `3 → 4 → 8`, every timestamp inside
  the outage window), but the **direction is certain: it keeps growing during the break**. That supervisor's
  `OCSF HTTP:POST` count rises over the same window (6 → 14 in one run).
- **The control plane does fail closed**: `sandbox create` fails, and there is **not even an object** in
  `sandboxes.agents.x-k8s.io` (0).
- The supervisor **notices** the break: its own log shows `OCSF NET:FAIL [LOW] os-a-openshell.tenant-a-gateway.svc.cluster.local:8080`,
  which returns to `NET:OPEN` once the Gateway is back — it notices, and still keeps proxying **approved** L7 traffic.

⚠️ On this case the **method** is more likely to be wrong than the conclusion: both exec channels lie.
`openshell sandbox exec` goes through the Gateway itself (during the outage it always returns
`Error: × connect error: transport error`, which looks like the data plane is down too); `kubectl exec` has an
**incomplete** environment (no injected `OPENAI_API_KEY` placeholder, no supervisor CA), so running pi gives
`providers.poc-model.apiKey: must not have fewer than 1 characters` + `No models available` — that is "no model", not
"no network". So measure the data plane either by letting the call **loop inside the sandbox** and, during the outage, only
**reading its log file** with `kubectl exec` (reading a file needs no model and no Gateway), or by exporting the
placeholder **before** running `setup-agent-home.sh` (`models.json` is generated by it; reversed order leaves the key empty).

⚠️ This section used to claim "with a NetworkPolicy cut, the data plane gives `http=200`": **that number does not
reproduce, and the method was wrong too** — the `sec12-cut` NetworkPolicy cuts the supervisor's egress, which is not the
same as "supervisor ↔ Gateway disconnected". The above is the re-measurement with the Gateway scaled down.

### 5.7 Agent-side OTLP is "free", but understand where it connects

After a sandbox is created, OpenShell injects:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://192.0.0.8:4318   # this sandbox's own supervisor relay
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
NODE_EXTRA_CA_CERTS=/run/openshell-supervisor-ca/material/ca.crt
```

pi-otel reads exactly these two variables, so **the agent needs neither the Collector address nor any Collector
credential** — the effect POC2 §8.2 wants is already available (the relay is off by default; `otlp.agent.enabled=true`
turns it on). The relay speaks OTLP/HTTP protobuf (JSON gets a 415 that explicitly says
`send application/x-protobuf`).

POC-11 has now proven the relay **does** add `openshell.sandbox.id` to spans (source `otlp_relay/enrichment.rs`). That
was exactly the link deciding whether this pattern produces audit value; the answer is yes.

⚠️ But pin `service.name` explicitly: pi-otel resolves it as
`process.env.OTEL_SERVICE_NAME ?? settings.serviceName ?? "pi"`, and it locates settings via **`homedir()`, not
`PI_CODING_AGENT_DIR`**. Before invoking pi you must set `HOME` and `PI_CODING_AGENT_DIR` to the **same value**, and
**also** set `OTEL_SERVICE_NAME` (the environment variable needs no path resolution, so it is the deterministic one).

### 5.8 Failure paths are long and cross product boundaries

| Symptom | Where the error appears | Where the real cause is |
|---|---|---|
| The third sandbox would not start | CLI: `timed out waiting for gated workload Pod` | agent-sandbox controller logs: the Capsule **quota** was full (first `count/services`, then `requests.memory`) |
| Supervisor stuck in ContainerCreating | kubelet: `secret "openshell-client-tls" not found` | in shared mode **the platform must copy the Secret into the runtime ns** (the driver only injects it in multi-ns mode) |
| `ls /data/workspace` is denied | `Permission denied` inside the sandbox | the OpenShell **policy baseline** excludes `/data` |

**Conclusion: in this pattern, observability is not a nice-to-have but a precondition for usability.** The correlation
design in POC2 §12 should cover "quota denial", "policy baseline" and "missing Secret" first, because the first time an
operator hits them, what they see is another product's error.

### 5.9 Size quotas by the real cost of one sandbox

A sandbox is more than its agent container: it also brings its own supervisor Pod, **two Services**, and a workspace PVC.
Measured, one sandbox (with a PVC) raised tenant usage to `limits.memory=1536Mi / count/pods=2`. `scope: Tenant` makes
the quota aggregate across **all** of that tenant's namespaces — the gateway Pod counts too. Three measured facts:

1. **Each sandbox creates two Services** (`os-boundary-<pair>` + `os-supervisor-<pair>`); `count/services` is what you hit
   first, and this one **does** surface in the CLI:
   `services "os-boundary-…" is forbidden: exceeded quota: … limited: count/services=8`;
2. **What you actually hit first is `requests.memory`, not `limits.memory`**: one Pi sandbox's requests are agent 1Gi
   (the `--memory` value doubles as requests) + supervisor 128mi (LimitRange default) ≈ **1.15Gi**;
3. Capsule **splits** tenant-level quotas per namespace (Tenant says 10 → runtime 8 / gateway 2). When verifying, read the
   **effective** `ResourceQuota`, not the number in the Tenant CR.

`poc/capsule2/tenants.yaml` has been recalculated from these measurements, with the errors above kept in comments.

---

## 6. Recommended revisions to the POC2 document (checked against measurements)

| POC2 location | Current text | Should become |
|---|---|---|
| §4.3 | Only says the workspace chart owns SA/Role/RoleBinding/NetworkPolicy | **Add a step**: shared mode must also copy `openshell-client-tls` into the tenant runtime ns (otherwise the supervisor never starts) |
| §4.2/§4.3 order | Gateway first, then the workspace chart | **Must be reversed**, otherwise the Gateway CrashLoops: `sandboxes.agents.x-k8s.io is forbidden … in the namespace "tenant-a-runtime"` |
| §4.4 | `required_labels` with `openshell.ai/sandbox-attachable-workspace: "${workspace}"` | The syntax works (`${workspace}` is whole-value substitution, no concatenation), but there **must also be a fixed label without `${workspace}`**, otherwise startup validation rejects it: `must include a shared approval label` |
| §5.2 | "Kind's default storageClass will not do" | Confirmed: install NFS + Subdir Provisioner. And **the same RWX claim on local-path is accepted by the API but stays Pending** — §5.2's warning is correct; add "this is what it looks like" |
| §6.1 | `ARG` before `FROM` in the Dockerfile | **The version is not pinned at all**: `${PI_VERSION}` expands empty in the stage and `latest` is installed, silently. `ARG` must come after `FROM` |
| §6.1 | `USER node` + `ENV PI_CODING_AGENT_DIR` | The sandbox runs as uid 10001 and image ENV is not injected → a writable agent home must be created at runtime |
| §6.2 | `pi install npm:pi-otel` at runtime | Must install **at build time** (no network at runtime); copying the extension by hand misses dependencies (`Cannot find module '@opentelemetry/api'`) — use Pi's own installer |
| §6.2 | config location is interchangeable | Must be `~/.pi/agent/settings.json` or `<cwd>/.pi/settings.json`, otherwise **silently ignored**; and set `OTEL_SERVICE_NAME` explicitly |
| §7.3 | "Tetragon provides eBPF observability" | Add the precondition: **the host kernel's LSM list must include `bpf`** (`lsm=bpf`), otherwise every lsm-hook policy fails to load; also 1.8.0's `kprobe_multi` default rejects duplicate symbols/Overrides, requiring `--disable-kprobe-multi` |
| §8.3 | `[openshell.gateway.otlp.ocsf] enabled = true` | The v0.1.7 chart exposes only `ocsf_log` (JSONL), but **the product does support OCSF over OTLP** (the chart just does not expose values). Mark it "verified, requires writing TOML directly", and note it flows through the Collector's **logs** pipeline |
| §9 / §11 | "tenant network isolation" listed alongside "the Agent cannot bypass the Supervisor" | **Split into two claims** (§5.4): the latter is enforced by OpenShell's L4 policies; the former is now a **platform capability** added in POC3 (Capsule `networkPolicies`, N-01..N-05) — but additive, so a tenant can widen it |
| POC3 constraint 1 | "a tenant-a user may only operate namespace `tenant-a`" | That namespace **does not exist** (`forceTenantPrefix` ⇒ `tenant-a-gateway` / `tenant-a-runtime` …). Use one RoleBinding per prefixed namespace; a ClusterRoleBinding over-grants |
| POC3 §I (`sub`) | implicitly "a federated user's `sub` can be used as identity" | The default `sub` is Keycloak's local id and **changes on re-import**. Set `uuidLDAPAttribute=entryUUID` and map `sub` from `LDAP_ID` |
| POC3 §I (claim shape) | each side configures its own claim | kube-apiserver v1.37 reads **top-level claims only** (a nested config leaves Groups at `system:authenticated`, silently), while OpenShell's `rolesClaim` accepts dotted paths ⇒ agree on one flat `groups` |
| POC3 §I (audience) | `--oidc-client-id` is enough to check `aud` | v1.37 has **no** `--oidc-audience`; tokens from another client on the same issuer are accepted. Use `--oidc-required-claim=aud=openshell-cli` (K-05 proves it with a second client) |
| POC3 §IV | implicitly "a directory change takes effect on the next request" | Keycloak 26.4 caches the imported federated user and has **no working sync endpoint**; drop the local copy (or run a syncer / a custom SPI) |
| POC3 §III | implicitly "Workspace membership follows directory groups" | It does not. Membership is a per-resource table keyed by subject (C-04); a directory-group → Workspace-member controller is needed |
| §11 SEC-13 | "Must not bypass the Supervisor" | The conclusion holds, but **say which layer enforces it**: measured, a non-Pi process (`node`, raw socket) reaches nothing except its own supervisor, and even DNS fails — what blocks it is the workload's **L4 NetworkPolicy** (deny-all egress plus one allow for the same pair's supervisor:5500), not the Supervisor's L7 policy. Consequence: any additional egress requires changing the NetworkPolicy |
| §11 SEC-12 | "Fail Closed" | Write control plane and data plane separately (§5.6). Measured: after the break the data plane **still works** (the sandbox keeps getting model replies), the control plane **does not** (not even a Sandbox CR). The disconnect is `scale statefulset/os-a-openshell 0`, not a NetworkPolicy |
| §3.5 | "Runtime workloads must have resource requests/limits" | State that **this rule never fires in a namespace with LimitRange defaults**: Capsule's mutating webhook fills the values in before Gatekeeper sees them. This is ordering, not a wrong rule |

---

## 7. Manual verification checklist

**Environment:** `ssh root@192.168.5.190`, working tree `/root/poc2` (kept in sync with local `poc/`), cluster context
`kind-agent-runtime-poc`, CLI `vendor/openshell-cli-0.1.7/openshell`, Gateway aliases `poc2-a` / `poc2-b`, workspace
`poc-shared`, tenant namespaces `tenant-a-{gateway,runtime}` / `tenant-b-{gateway,runtime}`.

**POC3 (identity chain) has its own entry points**: gateway profiles `p3-alice` / `p3-bob` / `p3-tadmin`,
Gateway `https://172.22.0.3:31444` (NodePort, **never port-forward**), Keycloak `https://172.22.0.3:31443`,
Workspaces `ws-tenant-a` / `ws-tenant-b`, users `alice` / `bob` / `tadmin` (password `poc3pass`),
script `phases/14-identity-federation.sh`.

Start the mTLS tunnel the CLI needs first (scripts 11/13 start it themselves; start it by hand for manual checks):

```bash
kubectl --context kind-agent-runtime-poc -n tenant-a-gateway \
  port-forward svc/os-a-openshell 18441:8080 &
```

**Order:** `01 → fix-apiserver-sans → 02 → 03 → 04 → 05 → 06 → 07 → 10 → 08 → 09 → 11 → 12 → 13`.
10 (observability stack) must come **before** 08 (Gateway): otherwise every OTLP export fails during Gateway startup and
gets misread as "OpenShell is not configured". 13 depends on the Developer sandbox and the shared PVC left behind by 11.

⚠️ **Run only one phase script at a time.** They share one Gateway and one tenant quota, so two scripts running at once
consume that quota twice as fast. Measured this round: an orphan process left behind by a dropped SSH connection ran in
parallel with a new round, and neither the SEC-12 counts nor the quota figures could be trusted. Before running anything
remotely, check `pgrep -af "phases/"` to make sure nothing survived from the previous attempt.

### 7.1 Re-checking by script

| Script | Covers | Success markers to look for |
|---|---|---|
| `phases/01-cluster.sh` + `kind/fix-apiserver-sans.sh` | cluster + external access | `readyz: ok`, `从外部读到 namespace 数=<N>` |
| `phases/02-antrea.sh` | sole CNI | `daemon set "antrea-agent" successfully rolled out`, 3 nodes Ready |
| `phases/03-netpol-verify.sh` | POC-05 | `### 结果: PASS=9 FAIL=0`, plus `deny-all 使 br-int 流表增加(n0 -> n1) 期望=OK` and the flow count falling back |
| `phases/04-capsule.sh` | POC-02 | ownership labels + `Tenant.status.namespaces` + auto-created ResourceQuota; `(b) tenant-b-steal -> 期望被拒`, `(c) 无租户前缀 -> 期望被拒` |
| `phases/05-gatekeeper.sh` | POC-06 / SEC-09 | every `✓ … 被 [poc-tenant-pod-boundary] 拒绝`; the platform-identity rows `✓ … 未被约束拦截` |
| `phases/06-agent-sandbox.sh` | POC-03 precondition / SEC-10 | `两边都是 agents.x-k8s.io/v1beta1（Sandbox）：兼容`; `[poc-managed-cr-only-platform]` appears |
| `phases/07-rwx-storage.sh` | RWX is real | `local-path RWX PVC: phase=Pending` (negative); `总行数=100 a=50 b=50` (positive, cross-node) |
| `phases/10-observability.sh` | ingestion point self-test | net-probe's `OTLP/HTTP via svc -> ` succeeds, collector debug shows `Traces`, `http://<host-ip>:31686` opens |
| `phases/08-gateway.sh` | POC-01 | two different `gateway_id`s, separate `openshell-data` PVCs; `A 的 SA 能否 list tenant-b-runtime 的 sandboxes: no` |
| `phases/09-resource-admission.sh` | SEC-14 | `✓ 无授权标签的 PVC … 被 resource admission 拒绝`, `✓ 匹配当前 workspace 的 PVC 允许` |
| `phases/11-pi-scenario.sh` | POC-04 / POC-10 / SEC-06/07 | `DEV_WRITE_OK`, `?? poc_extra_test.go` visible in both Reviewers, `mount_flags=ro,relatime`, `删掉两个 Reviewer 之后仍在: …/poc_extra_test.go`. ⚠ The script prints the byte size of each Reviewer's output: one of them being 0 bytes is a known behaviour (the model returned nothing — §7.3 item 12), not a sharing failure |
| `phases/12-tetragon.sh` | POC-07 | `PROCESS_EXEC binary=… argv=…`, `PROCESS_EXIT … status=7`, `INET … -> 1.1.1.1:443`, `(e) 身份: ns=… pod=…`; only `20-supply-chain` / `50-exec-enforcement` show `load_error` |
| `phases/14-identity-federation.sh` | **POC3 §I–§V plus the §5.4 correction** | ends with `PASS=49 FAIL=0`; `sub=` equals the directory entryUUID; `alice … tenant-b-runtime -> no` with the positive control `bob … tenant-a-runtime -> yes`; `a -> b: BLOCKED` + `b -> b: REACHED`; G-05/G-11 print `role 'os-admin' required` / `not a member of workspace`; C-02/C-03 PASS. ⚠️ Check the cleanup first: a leftover `Terminating` workspace makes G-03/G-06/G-10 fail spuriously (§12.7 item 1) |
| `phases/13-security-matrix.sh` | SEC-04/06/07/08/12/13 | completion markers: `spec.networkPolicies` empty + ordinary Pods `REACHED` + sandboxes `TIMEOUT`; `mount_flags=rw,relatime` yet the write is denied `Permission denied` (EACCES) against `Read-only file system` (EROFS); and for SEC-12, inside the outage window "agent 自己拿到 DATA_PLANE_OK 次数:" **keeps growing** (the absolute number differs per run; read the direction), the supervisor log shows `OCSF NET:FAIL … os-a-openshell…`, and "含 sec12-gw-down 的 Sandbox CR: 0"; SEC-13 requires "[正对照] 自己的 supervisor:5500: CONNECTED" while every other target gives `TIMEOUT`/`EAI_AGAIN` (if the positive control does not connect, that run measured nothing about the boundary); the cleanup must end with `✓ Deleted sandbox sec12-loop` — if it prints a transport error instead, the port-forward was taken down by the scale-to-0 (§7.3 item 9), and the leaked quota will show up in the next round |

### 7.2 Minimal re-check commands (one per claim), without running the scripts

```bash
CTX=kind-agent-runtime-poc; NS=tenant-a-runtime
cd /root/poc2
CLI=vendor/openshell-cli-0.1.7/openshell
# ⚠ Establish the port-forward first (the CLI speaks mTLS only, and must be 127.0.0.1:18441). Without it every $CLI
#   call returns `Error: × connect error: transport error`; and if stderr goes to /dev/null, `sandbox delete` **fails
#   silently** and quota does not drop at all (measured 2026-11-09).
pkill -f 'svc/os-a-openshell 1844' >/dev/null 2>&1
(setsid kubectl --context $CTX -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 </dev/null >/tmp/pf-a.log 2>&1 &)
sleep 4
$CLI -g poc2-a --workspace poc-shared sandbox list 2>&1 | head -5   # confirm the channel works before re-checking
#   clean up first (each sandbox = 2 Services + 1 PVC, `Completed` ones count too):
#   for s in $(...); do $CLI -g poc2-a --workspace poc-shared sandbox delete "$s"; done   # keep stderr

# POC-01 the two Gateways' state is mutually invisible
kubectl --context $CTX auth can-i list sandboxes.agents.x-k8s.io -n tenant-b-runtime \
  --as=system:serviceaccount:tenant-a-gateway:os-a-openshell                    # expect no
kubectl --context $CTX -n tenant-a-gateway get cm -l app.kubernetes.io/name=openshell \
  -o 'jsonpath={.items[0].data.gateway\.toml}' | grep -E '^ *(gateway_id|db_url|namespace )'

# POC-02 a tenant may not name or use across boundaries
kubectl --context $CTX create ns tenant-b-steal --as=alice --as-group=tenant-a-owners   # expect denied
kubectl --context $CTX -n tenant-b-runtime run x --image=alpine --as=alice \
  --as-group=tenant-a-owners --dry-run=server -o name                                  # expect denied

# POC-06 admission distinguishes by identity only, inside the same ns (--dry-run=server leaves nothing behind)
kubectl --context $CTX -n $NS run gp1 --image=alpine --as=alice --as-group=tenant-a-owners \
  --dry-run=server -o name \
  --overrides='{"spec":{"containers":[{"name":"gp1","image":"alpine","securityContext":{"privileged":true}}]}}'
#   expect [poc-tenant-pod-boundary]; with --as set to the platform SA os-a-openshell it must pass

# POC-03 / quota: read the **effective** quota, not the Tenant CR
kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 \
  -o jsonpath='{.status.used}{"\n"}{.spec.hard}{"\n"}'

# POC-04 / SEC-06 / SEC-07: three separate pieces of evidence
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-dev -- \
  sh -c 'touch /data/workspace/sec07 && echo DEV_WRITE_OK'
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-review-1 -- \
  sh -c 'cd /data/workspace/godotenv && git status --short'     # expect ?? poc_extra_test.go
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-review-1 -- \
  sh -c 'touch /data/workspace/sec06 2>&1'                      # expect Read-only file system
kubectl --context $CTX -n $NS get pvc shared-workspace \
  -o jsonpath='PV={.spec.volumeName} access={.spec.accessModes}{"\n"}'   # all three Pods must share one PV

# POC-08 query traces with the correct service.name
JAEGER=$(kubectl --context $CTX -n observability get svc jaeger -o jsonpath='{.spec.clusterIP}')
kubectl --context $CTX -n observability run q --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s "http://$JAEGER:16686/api/traces?service=pi-agent&limit=2" | head -c 400
#   expect spans invoke_agent pi / chat <model>; querying service=pi also returns rows (that is the default name
#   used when the settings file was not read)

# POC-09 did OCSF really go out over OTLP
kubectl --context $CTX -n tenant-a-gateway exec deploy/os-a-openshell -- \
  sh -c 'wget -qO- localhost:8080/metrics' 2>/dev/null | grep ocsf_otlp
#   expect openshell_ocsf_otlp_exported_total > 0 and no *_errors_total
kubectl --context $CTX -n observability logs deploy/otel-collector --tail=400 | grep -c openshell.ocsf

# POC-07 / POC-11 kernel side
kubectl --context $CTX -n kube-system exec ds/tetragon -c tetragon -- tetra tracingpolicy list
kubectl --context $CTX -n kube-system exec ds/tetragon -c tetragon -- sh -c \
  'timeout 12 tetra getevents -o compact --timestamps --namespace tenant-a-runtime' &
$CLI -g poc2-a --workspace poc-shared sandbox exec pi-review-2 -- \
  sh -c 'timeout 8 curl -s -m 6 https://api.open.ai/ ; true'
#   expect Tetragon to report pod.name=poc-shared--pi-review-2 + argv + uid=10001, and in the same second the
#   supervisor log: OCSF NET:OPEN [MED] DENIED … [reason:transparent_tcp_policy_denied]
# ⚠ getevents streams and never replays: **start the stream first, then create the event**, and `kubectl exec`
#   takes 1–2s to start streaming.

# SEC-04/08 attribution: does the platform provision any tenant network policy (non-empty since POC3)
kubectl --context $CTX get tenant tenant-a -o jsonpath='{.spec.networkPolicies}{"\n"}'   # expect items[0].policyTypes=[Ingress]
kubectl --context $CTX get netpol -A -l capsule.clastix.io/network-policy           # one capsule-tenant-<t>-0 per tenant ns
kubectl --context $CTX -n $NS get netpol | grep -v capsule-tenant                  # the rest are OpenShell's own
# end to end (full N-02..N-05 in the 2b section of phases/14-identity-federation.sh):
#   tenant-a -> tenant-b: BLOCKED; tenant-b -> tenant-b (positive control): REACHED;
#   after the tenant adds a permissive policy: REACHED (additivity); after removing it: BLOCKED
# ⚠ that workloads policy's .spec.egress **is legitimately empty** (Egress declared, zero rules = all egress denied).
#   Printing only it yields a blank column — no evidence. Read the pair policy's egress[0].to as well:
kubectl --context $CTX -n $NS get netpol openshell-sandbox-workloads \
  -o jsonpath='workloads: policyTypes={.spec.policyTypes} egress={.spec.egress}{"\n"}'   # expect Egress managed, egress empty
CN=$(kubectl --context $CTX -n $NS get netpol --no-headers | awk '/^os-control-/{print $1; exit}')
echo "$CN:"
kubectl --context $CTX -n $NS get netpol "$CN" \
  -o 'jsonpath=only egress -> {.spec.egress[0].to[0].podSelector.matchLabels} port={.spec.egress[0].ports[0].port}{"\n"}'
#   ⚠ keep the jsonpath **single-quoted**: inside double quotes the shell eats {"\n"} and jsonpath gets {n}
#   ↑ composed, the two mean: a workload can only reach its own supervisor:5500 (this is how POC-05 is implemented)

# SEC-12 disconnect: data plane vs control plane. The fully reproducible form is the SEC-12 section of
# phases/13-security-matrix.sh (it creates a sandbox named sec12-loop and starts the loop itself); the steps
# below redo it by hand.
# ⚠ Do not measure the data plane with `sandbox exec`: that channel goes through the Gateway, so during the
#   outage it always returns transport error — that is the CLI breaking, not the data plane.
# ⚠ Do not use a NetworkPolicy as "the disconnect": that cuts the supervisor's egress, not supervisor ↔ Gateway.
$CLI -g poc2-a --workspace poc-shared sandbox create --name sec12-loop --from pi-agent:poc \
  --cpu 500m --memory 1Gi --detach --restart-policy never --provider poc-model -- sh -c 'sleep 3600'
$CLI -g poc2-a --workspace poc-shared sandbox exec sec12-loop -- sh -c \
  'sh /usr/local/pi/setup-agent-home.sh >/dev/null 2>&1; . /tmp/pi-home.env; rm -f /tmp/sec12-loop.log
   setsid sh -c "i=0; while [ \$i -lt 60 ]; do i=\$((i+1)); printf \"== %s %s\\n\" \$i \$(date -u +%T) >> /tmp/sec12-loop.log; timeout 90 pi --model poc-model/qwen3.8-flash-next -p \"Reply with exactly the token DATA_PLANE_OK\" </dev/null >> /tmp/sec12-loop.log 2>&1; sleep 20; done" & echo LOOP_STARTED'
sleep 70
POD=poc-shared--sec12-loop
SP=os-supervisor-$(kubectl --context $CTX -n $NS get pod $POD -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair}')
kubectl --context $CTX -n tenant-a-gateway scale statefulset/os-a-openshell --replicas=0   # this is the disconnect
#   data plane: read the loop's own log inside the sandbox (a file read needs no model and no Gateway)
kubectl --context $CTX -n $NS exec $POD -c agent -- \
  sh -c 'grep -c DATA_PLANE_OK /tmp/sec12-loop.log; tail -3 /tmp/sec12-loop.log'   # expect it still growing
kubectl --context $CTX -n $NS logs $SP --tail=200 | grep os-a-openshell            # expect OCSF NET:FAIL
kubectl --context $CTX -n $NS get netpol openshell-sandbox-supervisors \
  -o jsonpath='{.spec.policyTypes} {.spec.egress}{"\n"}'                          # expect ["Egress"] [{}] = open
#   control plane:
timeout 90 $CLI -g poc2-a --workspace poc-shared sandbox create --name sec12-gw-down \
  --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never -- 'sleep 20'   # expect failure
kubectl --context $CTX -n $NS get sandboxes.agents.x-k8s.io --no-headers | grep -c sec12-gw-down  # expect 0
kubectl --context $CTX -n tenant-a-gateway scale statefulset/os-a-openshell --replicas=1
#   ⚠ Scaling the Gateway to 0 also breaks the port-forward tunnelled through it — re-establish it (the line at the top
#     of this §7.2) before cleaning up, or the delete below just returns a transport error and sec12-loop keeps holding
#     2 Service quota units.
#   ⚠ The real Sandbox CR name is <workspace>--<name> (e.g. poc-shared--gw-q), not <name>.

# SEC-13 another process reaching the network with no tool call (reuses an existing sandbox; no quota needed)
SP_IP=$(kubectl --context $CTX -n $NS get svc --no-headers | awk '/^os-supervisor-/{print $1; exit}' | xargs -I{} \
  kubectl --context $CTX -n $NS get svc {} -o jsonpath='{.spec.clusterIP} {.spec.ports[0].port}')
DV=poc-shared--pi-dev   # ⚠ kubectl exec needs the Pod name = <workspace>--<sandbox name> (§7.3 item 10)
cat > /tmp/sec13.js <<'JS'
const net=require("net"), dns=require("dns");
const t=(host,port,label)=>new Promise(r=>{const s=net.connect({host,port,timeout:6000});
 s.on("connect",()=>{console.log(label+": CONNECTED");s.destroy();r()});
 s.on("timeout",()=>{console.log(label+": TIMEOUT");s.destroy();r()});
 s.on("error",e=>{console.log(label+": ERROR "+e.code);r()});});
(async()=>{
 const host=process.argv[2], port=+(process.argv[3]||0);
  if(!host||!port) return console.log("  ! no positive control — this run is unusable");
  await t(host,port,"[POSITIVE CONTROL] own supervisor:"+port); // must be CONNECTED or the run proves nothing
 await t("10.96.0.1",443,"kubernetes API :443");
  await t("1.1.1.1",443,"1.1.1.1:443 (literal IP, DNS skipped)");
 dns.lookup("api.openai.com",e=>console.log("DNS api.openai.com: "+(e?("ERROR "+e.code):"OK")));
})();
JS
kubectl --context $CTX -n $NS exec -i $DV -c agent -- sh -c 'cat > /tmp/sec13.js' < /tmp/sec13.js
# ⚠ pass host and port as two separate arguments; collapsed into one string the positive control finds no address (measured)
kubectl --context $CTX -n $NS exec $DV -c agent -- node /tmp/sec13.js "${SP_IP% *}" "${SP_IP##* }"
#   expect: supervisor CONNECTED, everything else unreachable (TIMEOUT or EAI_AGAIN — the exact errno does **not** have
#   to match: in phase 11 pi's curl gets a "Couldn't connect" after a few milliseconds, another face of the same L4
#   block). What blocks it is L4 (the NetworkPolicy), not L7; only the positive control has to hold reliably.

# POC-05 re-check one NetworkPolicy assertion by hand (including the OVS side)
kubectl --context $CTX -n kube-system exec "<antrea-agent pod on the server node>" -c antrea-agent -- \
  ovs-ofctl dump-flows br-int | grep -c cookie      # must rise with a deny-all and fall back after deleting it
```

### 7.3 The twelve easiest places to misjudge

1. **`pi -p` waits on stdin.** `sandbox exec` keeps stdin open, so pi never exits, prints nothing, and dies at rc=124.
   `</dev/null` is required. This was once misread as "the model is unreachable".
2. **`service.name` defaults to `pi`.** Not finding traces under `pi-agent` does not mean nothing was reported (§5.7).
3. **`Completed` sandboxes still consume quota** — you must `sandbox delete`. Also, `PHASE` is **column 4** in
   `sandbox list` (the `CREATED` value splits into date and time), so filtering on `$2`/`$3` never matches and the script
   looks like its prerequisite never ran. The same table is **space-padded**, so anchoring with `grep "^name$"` never
   matches either (measured: a `wait_ready` loop timed out while the list clearly showed `Ready`). Write
   `grep "^name[[:space:]]"` instead.
4. **`--dry-run=server` admission tests land on the `admission_dryrun="true"` series**; filter metrics by
   `admission_dryrun=false` for production dashboards. Gatekeeper **counts per replica**, so looking at one Pod misses denials.
5. **Tetragon can only be judged from `tetra tracingpolicy list` STATE**: neither the `kubectl apply` exit code nor the
   CRD status works (in 1.8.0 a policy that failed to load still has an empty `{}` status). With 0 events, check the
   selector first. In the JSON the identity is under `process.pod`, the 5-tuple under `args[].sock_arg`, and the
   `security_socket_connect` destination under `args[].sockaddr_arg`.
6. **kind nodes do not mount securityfs** — read `/sys/kernel/security/lsm` on the **host**, not inside the node.
7. **GitHub release assets and raw.githubusercontent.com time out from this host** (503/504). Use
   `poc/scripts/gh-fetch.sh` (it goes through the `api.github.com` asset endpoint); the helm repo and ghcr.io are unaffected.
   ⚠️ From the Mac, Go binaries (kubectl/helm) get `connect: no route to host` against this IP (a local Clash TUN routing
   issue) while `curl`/`nc` work — see `poc/kind/README-external-access.md`; use `poc/kind/ssh-tunnel.sh` when needed.
8. **NodePorts are not published to the host automatically**: they must be mapped explicitly with `extraPortMappings`
   in the kind config (`31686` is configured). The host Tempo runs with `--net=host` and its query port is **3200**
   (not 3100); probing the wrong port reads as "no Tempo".
9. **Both exec channels lie about SEC-12**: `openshell sandbox exec` goes through the Gateway (during the outage it
   always returns `transport error`), and `kubectl exec` has an incomplete environment (no injected credentials/CA, so pi
   says "no models"). Measure the data plane with "loop inside the sandbox + read the log file via `kubectl exec`". §5.6.
   ⚠ One more trap that catches **the script itself**: scaling the Gateway to 0 also takes the `port-forward` running on
   top of it down with it, so the `sandbox delete` the script runs at the end — after the restore — just produces a
   transport error, which is completely invisible if stderr goes to `/dev/null`. Measured: `sec12-loop` was never
   deleted that way, held 2 Service quota units, and the next round's `create` hit the quota. Phase 13 now
   re-establishes the port-forward explicitly before its cleanup (the `PF` function) and prints the delete's stderr.
10. **The real Sandbox CR name is `<workspace>--<name>`** (e.g. `poc-shared--gw-q`). Looking it up as `get sandbox gw-q`
   returns NotFound and turns a **successful** creation into a perceived failure.
11. **Each sandbox takes 2 Services + 1 PVC** (`os-boundary-*` / `os-supervisor-*` / `workspace-<ws>--<name>`), so the
    quotas that fill first are `count/services` and `persistentvolumeclaims`, **not** `count/pods`. The two exhaustions
    **look different** (both measured): hitting `count/services` produces a clear error
    (`services "os-boundary-…" is forbidden: exceeded quota …`, see §5.9); hitting the PVC quota makes `sandbox create`
    give **no reason at all**, and it only surfaces on the next exec as `sandbox not found`.
    Measured: `sandbox delete` **does** remove that sandbox's own PVC (8/9 → 7/9; after a full cleanup
    `services=0/12 pvc=3/9`), so cleanup really is just deleting the sandbox — but a `Completed` sandbox still holds all
    three, so run `sandbox list` and clean up first (`Completed` ones count). ⚠ Do not `kubectl delete pvc` directly
    instead: while its Pod is still terminating the PVC sticks in Terminating. ⚠ **Establish the port-forward before
    cleaning up**: without it every `sandbox list/delete` returns `Error: × connect error: transport error`, and if you send
    stderr to `/dev/null` the deletions **fail silently** and quota does not drop at all (measured: 9 deletes, all silently
    failing, quota still 8/12). Either keep `2>&1`, or run
    `kubectl -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 &` first.
12. **The local model sometimes returns nothing, and the exit code is still 0.** Re-running phase 11 gave a 0-byte
    `/tmp/rev-1.out` and a non-empty `rev-2.out` — same prompt, same model, same sandbox config. So "each Agent produces
    its own review" is **not deterministic** (that is the model side) and must not be written up as a platform capability;
    conversely an empty or weak answer is not a platform defect either. What is certain on the platform side: shared
    visibility, read-only enforcement, parallelism without mutual exclusion.

---

## 8. Reproduction environment

```bash
# host: Ubuntu 24.04 / kernel 6.8.0-147 (has BTF, no bpf in the LSM list) / 48C / 94G
ssh root@192.168.5.190 'cd /root/poc2 && bash phases/NN-*.sh'

# after 01 the apiserver SAN must be added (the kind field is certSANs; extraSANs is **silently ignored**)
ssh root@192.168.5.190 'cd /root/poc2 && SAN=192.168.5.190 bash kind/fix-apiserver-sans.sh'
```

External access needs **two** conditions: the certificate SAN includes the host IP, and NodePorts are published explicitly
with `extraPortMappings`. Full notes: [`poc/kind/README-external-access.md`](poc/kind/README-external-access.md).

⚠️ **`/root/poc2` is a mirror of `poc/` — do not sync it with `--delete`.** The host's `vendor/` directory (the OpenShell
CLI binary, the workspace chart) is **not in git** (`.gitignore` does that on purpose). `rsync --delete` removes it, and
every phase script then fails with `vendor/openshell-cli-0.1.7/openshell: No such file or directory`. To restore it, use
the same fetch the scripts use: the first four lines of `bash phases/08-gateway.sh`, or on its own
`bash scripts/gh-fetch.sh NVIDIA/OpenShell v0.1.7 openshell-x86_64-unknown-linux-musl.tar.gz openshell-cli-0.1.7.tar.gz`
followed by unpacking into `vendor/openshell-cli-0.1.7/`.

⚠️ The reverse case: **an rsync neither interrupts a running script nor gets picked up by it.** rsync writes a new file
and renames it into place, so a bash that is already executing keeps holding the old inode (`/proc/<pid>/fd` shows
`… (deleted)`). An edit takes effect only on a **re-run** — a half-finished run will not read the new code.

### Component versions

| Component | Version |
|---|---|
| kind / Kubernetes | v0.33.0 / v1.37.0 |
| Antrea | 2.7.0 |
| Capsule | 0.15.2 (cert-manager v1.20.2) |
| OPA Gatekeeper | 3.23.1 |
| agent-sandbox | v1.0.10 (Sandbox API `agents.x-k8s.io/v1beta1`) |
| OpenShell | 0.1.7 (chart 0.1.7 / CLI at the same version) |
| Keycloak / OpenLDAP (POC3) | 26.4 / 1.5.0 (`identity` namespace, NodePort `31443`) |
| Tetragon | 1.8.0 |
| NFS Server Provisioner | 1.8.0 |
| OpenTelemetry Collector (contrib) / Jaeger | 0.155.0 / 1.69.0 |
| Pi Coding Agent / pi-otel | 1.5.0 / 0.3.0 |
| Model | local llama.cpp/Strata on the host, OpenAI-compatible on `:8080`, `qwen3.8-flash-next` |

### Demo entry points

- Host Grafana (Tempo data source): `http://<host-ip>:3000`
- In-cluster Jaeger UI (NodePort, requires `extraPortMappings`): `http://<host-ip>:31686`
- OTLP endpoints: collector `observability/otel-collector:4317` (gRPC) / `:4318` (HTTP)
- POC3 Gateway (OIDC): `https://172.22.0.3:31444`; Keycloak: `https://172.22.0.3:31443`
- Query handbook: [`poc/usage/02-agent-visibility.md`](poc/usage/02-agent-visibility.md)
- Manual Workspace demo (mirrors NVIDIA `how-it-works/workspaces`): [`poc/usage/04-workspace-demo.md`](poc/usage/04-workspace-demo.md)

---

## 9. Repository layout

```
README.md          the conclusions (Chinese, the single source)
README.en.md       the same conclusions (English) — the two files correspond line for line; edit both together
POC2.md            the design itself (round 2)
POC3.md            the design itself (round 3: LDAP → Keycloak → unified K8s/OpenShell permissions)
poc/
├── phases/        01→13 (POC2) and 14 (POC3 identity matrix) repeatable verification scripts (10 before 08)
├── kind/          poc2-cluster.yaml · fix-apiserver-sans.sh · README-external-access.md · ssh-tunnel.sh
├── capsule2/      tenants and quotas (recalculated from measurements, with the arithmetic in comments)
├── gatekeeper/    constraint templates and constraint instances
├── openshell2/    Gateway values (shared mode, with the measured correction about otlp.ocsf)
├── openshell3/    POC3 OIDC Gateway (values / NodePort / CLI device-flow login library)
├── openshell4/    POC4 Deployment + external PostgreSQL (two releases share one DB / HA / matrix)
├── identity/      POC3 identity chain: LDAP entries and seed job, Keycloak realm script and claim mappers,
│                  apiserver OIDC patch, per-namespace RBAC, self-signed issuer CA
├── providers/     Provider profiles (model egress, credential-free GitHub egress)
├── policies/      Developer / Reviewer filesystem policies (one line apart, guarded by a diff assertion)
├── pi/            Pi image and runtime agent-home initialization
├── observability2/ Collector config (dual export: in-cluster Jaeger + host Tempo)
├── observability/ OTLP self-test Pod
├── storage/       RWX PVC, probes, workspace PVC (with approval labels)
├── tetragon/      observation and enforcement policies
├── scripts/       gh-fetch.sh (works around release-asset timeouts) · bootstrap.sh
├── usage/         provisioning script · Tetragon query handbook · round-1 demo script · manual Workspace demo (04)
└── docs/          POC2-CONCLUSIONS.md (verbatim evidence) · FINDINGS.md (round-1 evidence appendix)
```

Round-1 assets (`agent/`, `capsule/`, `openshell/`, `agent-sandbox/`, `usage/01,03`) remain in the repository for
comparison and reuse; their conclusions documents were deleted and survive only in git history.

---

## 10. What this pattern still needs before production

Ordered from "must fix" to "should fix":

1. **Tenant network isolation now exists, but it is additive.** Capsule `networkPolicies` makes a cross-tenant ordinary
   Pod `BLOCKED` (§5.4), but a tenant can widen it with one policy (N-04). Production must decide: accept it (and write it
   into the tenant agreement), or tighten with Capsule `spec.rules.enforce.policies` / an Antrea ClusterNetworkPolicy.
   Note the field is deprecated in Capsule 0.15.2.
2. **Observability backend persistence and evidence retention.** Jaeger all-in-one is in-memory and lost evidence once in
   each round; this round switched to dual export (in-cluster Jaeger for scripted assertions, host Tempo/Grafana for the
   demo), but production needs a backend with storage and a retention period.
3. **The Gateway is still a single replica on SQLite.** POC2 §1.3 rightly excludes HA from the PoC, but "must fix before
   production" must include: external PostgreSQL, and how Gateway certificate rotation is **continuously** synced to the
   client-TLS copy in the runtime ns (not a one-off platform step).
4. **Tetragon's enforcement capability depends on host kernel configuration** (the LSM list must include `bpf`); this is a
   delivery precondition and belongs in the provisioning checks.
5. **The chart's OCSF support is incomplete.** The v0.1.7 chart does not expose `otlp.ocsf` as values, so it is written
   into TOML directly today; on upgrade, assert that this key still exists
   (`openshell_ocsf_otlp_exported_total` is the most direct sentinel metric).
6. **The quota model belongs in the provisioning flow.** Compute `count/services`, `requests.*`, `limits.*` and
   `persistentvolumeclaims` per sandbox count (§5.9), and make "quota denied" a first-class observable event — otherwise
   the operator always sees another product's timeout.
7. **Multi-Agent collaboration currently goes only as far as "shared + read-only + parallel".** There is no
   message/lock/merge semantics between Agents. That is a product-layer gap, not a platform gap, but the report must not
   conflate the two.
8. **Directory changes have no reliable downstream channel (POC3's biggest production gap).** Keycloak 26.4 imports
   federated users lazily and caches them; a directory group change does not reach a token, and there is **no working
   sync endpoint** (§12.4). The POC drops the local copy; production must choose a periodic full sync, a custom
   User Storage SPI that reads the directory on every request, or an accepted TTL-level delay.
9. **Workspace membership does not follow directory groups.** A directory-group → Workspace-member controller is needed;
   otherwise every tenant change is a manual `workspace member add` with no audit trail (§12.4 C-04).
10. **The identity chain is itself a single point of failure.** Keycloak and OpenLDAP run single-replica and the issuer
    NodePort is directly exposed. Decide on offline token validation (JWKS caching and TTL) and on Keycloak HA.

---

## 11. History

- **Round 1 (2026-11-03)**: operator mode, macOS + Docker Desktop + two kind clusters. Validated warm pools
  (warm claim 0.25s / cold start 0.92s / cold start with image pull 15.98s), uid 10001, immediate kernel-level denial
  (EPERM), OTLP/kernel event alignment. Evidence is kept in [`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md); its
  conclusions document was deleted and survives only in git history.
- **Round 2 (2026-11-08 → 11-09)**: POC2 **shared mode**, one Gateway per tenant. Verbatim evidence is in
  [`poc/docs/POC2-CONCLUSIONS.md`](poc/docs/POC2-CONCLUSIONS.md). ⚠️ Its §5.4 (network-isolation attribution) has been
  corrected by round 3.
- **Round 3 (2026-11-10, POC3)**: LDAP → Keycloak → one OIDC JWT → kube-apiserver and the OpenShell Gateway. Adds the
  `identity` namespace (OpenLDAP + Keycloak 26.4), apiserver OIDC flags, per-namespace RBAC, a third OIDC Gateway (two
  Workspaces), and Capsule `networkPolicies` on both tenants. Verdicts in **§12**, script
  `phases/14-identity-federation.sh`. **It does not conflict with round 2: POC2's two Gateways are untouched.**
- **Round 4 (2026-11-11, POC4)**: the Gateway moves from StatefulSet + SQLite to Deployment + external
  PostgreSQL; two independent releases (p4a/p4b) share one PostgreSQL, and two replicas of one release are
  HA. Scripts in `openshell4/`, verdicts in **§13**. POC2/POC3 Gateways are untouched.
- **Currently valid conclusions**: round 2's component verdicts plus round 3's identity/permission and
  network-isolation corrections plus **round 4's storage shape (§13)**.

## 12. POC3 (round 3, 2026-11-10): one permission system for Kubernetes and OpenShell

> Design: [`POC3.md`](POC3.md). The whole matrix runs as one script, `poc/phases/14-identity-federation.sh`,
> which ends with `PASS=n FAIL=m`; every verdict below comes from that run (`/tmp/p14f.log` on the host).
> **POC2's two Gateways and §1–§11 are unaffected**: POC3 is a third Gateway (`poc3-gateway/p3-openshell`,
> NodePort `https://172.22.0.3:31444`) with its own identity namespace (`identity`).

### 12.0 Verdicts at a glance

| Acceptance area | Verdict | Evidence |
|---|---|---|
| Identity chain | ✅ verified | all three users' `sub` equals the directory `entryUUID`; `tenant` / `groups` come from LDAP attributes and groups; Keycloak and K8s hold no hand-maintained users or role bindings |
| Kubernetes isolation | ✅ verified | `auth can-i` matrix plus **real creates** in both directions; cross-tenant writes are denied by RBAC |
| OpenShell isolation | ✅ verified | one Gateway, two Workspaces; membership keyed by subject; denials carry `reason:not_workspace_member` |
| Cross-system consistency | ⚠️ conditional | same claim, same subject; but **directory changes do not reach the token** (C-02/C-03 need the local copy dropped) and Workspace membership **does not follow** directory groups (C-04) |
| Failure observability | ✅ verified | every denial appears in Gateway OCSF as `DENIED … reason:missing_role / not_workspace_member` with subject and gRPC method |
| Tenant network isolation (§5.4 correction) | ✅ verified | Capsule `networkPolicies` in all 4 tenant namespaces; cross-tenant `BLOCKED`, same-tenant positive control `REACHED`; additivity recorded |

### 12.1 I. Identity and claim design (configuration)

> ⚠ **The LDAP directory was reseeded on 2026-11-11**: every `entryUUID` changed (alice is now
> `674f092a-71c7-1041-817c-7f0afac63416`). The `3affaeaa-… / 3b008514-…` values in this section belong to the
> **11-10 run** and are that run's verbatim evidence; **on replay, read them from a fresh token rather than
> copying constants** (§12.7). The 11-11 replay also fixed two bugs in `realm-script.sh` (`find_id` and scope
> attachment), so replay now reliably emits `aud/groups/tenant`.

**LDAP is the only source of truth** (`poc/identity/ldif/tenant-users.ldif`): the tenant identifier is
`departmentNumber`; roles are `groupOfNames` memberships under `ou=groups`.

| User | `departmentNumber` → `tenant` | directory groups → `groups` |
|---|---|---|
| `alice` | `tenant-a` | `tenant-a-users`, `os-user` |
| `tadmin` | `tenant-a` | `tenant-a-users`, `os-user`, `os-admin` |
| `bob` | `tenant-b` | `tenant-b-users`, `os-user` |

**Keycloak federation** (`poc/identity/keycloak/30-ldap.json`, provider `ldap-poc3`): `usersDn=ou=people,dc=aisanbox,dc=example`,
`usernameLDAPAttribute=uid`, **`uuidLDAPAttribute=entryUUID`**, `editMode=READ_ONLY`, `importEnabled=true`.

**Claim mappers** (one file each):

| File | Mapper | Source | Claim | Measured example |
|---|---|---|---|---|
| `24-claim-sub-from-ldap.json` | `oidc-usermodel-attribute-mapper` | user attribute `LDAP_ID` | **`sub`** | alice `3affaeaa-70f6-1041-996a-41648389b70a` (11-10 run; changed by the 11-11 reseed) |
| `21-claim-tenant.json` | `oidc-usermodel-attribute-mapper` | user attribute `tenant` ← LDAP `departmentNumber` (mapper `31-ldap-attr-tenant.json`) | **`tenant`** | `tenant-a` |
| `22-claim-roles.json` | `oidc-usermodel-realm-role-mapper` (`multivalued`) | realm roles loaded from `ou=groups` (`32-ldap-roles-from-dir.json`, `LDAP_ONLY`) | **`groups`** (flat array) | `["os-user","tenant-a-owners","tenant-a-users"]` |
| `23-claim-audience.json` | `oidc-audience-mapper` | `included.client.audience=openshell-cli` | `aud` | `openshell-cli` |

Why `groups` is **flat**: OpenShell's `rolesClaim` accepts a dotted path, but kube-apiserver v1.37's
`--oidc-groups-claim` reads **top-level claims only**; a nested config leaves `Groups` at `system:authenticated`
with no error. Both sides therefore read the same flat `groups`.

**Clients**: `openshell-cli` (public; direct grant + device flow; PKCE S256;
`oauth2.device.authorization.grant.enabled=true` — the CLI cannot log in without it) and `poc3-other-aud`
(no default client scopes; supplies K-05's token with the same user and a wrong `aud`).

**Issuer**: `https://172.22.0.3:31443/realms/aisanbox` (Keycloak NodePort `31443`, self-signed CA
`poc/identity/certs/issuer-ca.crt`). Issuer is read from ConfigMap `identity/kc-config` for all three consumers
(Keycloak `KC_HOSTNAME`, apiserver, Gateway).

**kube-apiserver flags actually in effect:**

`--oidc-issuer-url=https://172.22.0.3:31443/realms/aisanbox`, `--oidc-client-id=openshell-cli`,
`--oidc-ca-file=/etc/kubernetes/pki/oidc-issuer-ca.crt`, `--oidc-username-claim=sub`,
`--oidc-username-prefix=-`, `--oidc-groups-claim=groups`, `--oidc-signing-algs=RS256`,
`--oidc-required-claim=aud=openshell-cli`.

**RBAC** (`poc/identity/50-rbac.yaml`): one `ClusterRole poc3-tenant-member` (pods, pods/log, configmaps only;
no nodes/namespaces/secrets), bound **per namespace** — `poc3-tenant-a-users` in `tenant-a-runtime` and
`tenant-a-gateway`, `poc3-tenant-b-users` in `tenant-b-*` — plus a temporary **positive control**
`poc3-negative-control-b-in-a` in `tenant-a-runtime`.

⚠️ Necessary deviation from POC3 constraint 1: `tenant-a` as a namespace does not exist (`forceTenantPrefix`
gives a *set* of prefixed namespaces). A ClusterRoleBinding would over-grant across tenants.

**Capsule** (both tenants): `forceTenantPrefix: true` plus
`networkPolicies.items[0] = {podSelector: {}, policyTypes: [Ingress], ingress.from: namespaceSelector capsule.clastix.io/tenant=<tenant>}`.

**Gateway** (`poc/openshell3/gateway-oidc-values.yaml`): `server.oidc.issuer=<issuer>`,
`audience=openshell-cli`, `rolesClaim=groups`, `adminRole=os-admin`, `userRole=os-user`,
`scopesClaim=""`, `caConfigMapName=oidc-issuer-ca`, `jwksTtl=600`;
`server.auth.allowUnauthenticatedUsers=false`; `server.tls.enableMtls=false`; `workspaceMode=shared`.
The issuer CA reaches the process as `SSL_CERT_FILE` + the `oidc-ca` volume mount (not in `gateway.toml`).
Workspaces: `ws-tenant-a` (tadmin admin, alice user), `ws-tenant-b` (tadmin admin, bob user), members by subject.

### 12.2 II. Kubernetes-side verification

| Case | Actor | Target | Command | Expected | Fails if | Measured |
|---|---|---|---|---|---|---|
| K-01/K-02 | alice/bob | token | decode `sub` | equals directory `entryUUID` (`3affaeaa-…` / `3b008514-…`; values from the 11-10 run — the LDAP reseed on 11-11 changed them, so read `sub` from a fresh token) | local Keycloak id, empty, or different | ✅ |
| K-03 | alice | token | read `groups` | contains `os-user`, `tenant-a-users`, `tenant-a-owners` | missing one; order-sensitive grep | ✅ |
| K-03b | tadmin | token | read `groups` | contains `os-admin` | absent | ✅ |
| K-03c | bob | token | read `groups` | contains **no** `tenant-a-*` group | any | ✅ |
| K-04 | alice | token | read `tenant` | `tenant-a` | missing/empty | ✅ |
| K-05 | alice | apiserver | token from client `poc3-other-aud`, `auth whoami` | rejected (`Unauthorized` / required claim) | accepted | ✅ |
| K-05b | alice | apiserver | positive control: token from `openshell-cli` | accepted, shows the entryUUID | control fails ⇒ K-05 proves nothing | ✅ |
| K-10 | alice/bob | apiserver | `auth can-i list pods -n <ns>` (4) + `list nodes` | own tenant yes, other tenant no, nodes no | any boundary crossed | ✅ |
| K-11 | alice/bob | apiserver | real `kubectl run` in both runtime namespaces | own `created`, other `Forbidden` | `can-i` used instead of a real write | ✅ |
| K-12 | alice/bob | apiserver | `auth can-i list nodes` | `no` | `yes` | ✅ |
| X-01 | alice | Gatekeeper | `kubectl run --overrides='{"spec":{"hostNetwork":true}}'` where RBAC **allows** | denied by `[poc-tenant-pod-boundary]` | denied by RBAC (then it is not Gatekeeper) | ✅ |

Read matrix (measured): alice → `tenant-a-runtime`/`tenant-a-gateway` = yes, `tenant-b-*` = no, nodes = no;
bob symmetric. Positive control: after binding `tenant-b-users` into `tenant-a-runtime`, bob's `tenant-a-runtime`
becomes **yes** while `tenant-a-gateway` stays **no** — the `no`s are real RBAC, not an unread claim.

Real writes:

```
alice create pod tenant-a-runtime -> created
alice create pod tenant-b-runtime -> Forbidden: cannot create resource "pods"
bob   create pod tenant-a-runtime -> created            (positive control)
bob   create pod tenant-b-runtime -> created
```

Three of the four rows are "own tenant allowed, other tenant denied by RBAC"; the fourth is the positive control.
Remember that **RBAC allowing a verb does not guarantee the object is created** — quota and admission can deny first
(an earlier run of this round produced `Forbidden: exceeded quota: capsule-tenant-b`); when judging isolation,
separate the two kinds of denial (same point as X-01).

Network isolation (N-01..N-05) — see §5.4: policies present in 4 namespaces; cross-tenant `BLOCKED`;
same-tenant `REACHED`; tenant-added policy turns it `REACHED` (additivity); removing it restores `BLOCKED`.

### 12.3 III. OpenShell Gateway-side verification

Connection is NodePort `https://172.22.0.3:31444`; **no `kubectl port-forward`** (it is reaped between calls, and the
resulting `connect error: transport error` reads like a denial).

| Case | Actor | Command | Expected | Measured |
|---|---|---|---|---|
| G-01 | alice/bob/tadmin | `whoami -o json` → `subject` | identical to the apiserver Username | ✅ all three |
| G-02 | never-logged-in profile | `workspace list` | `OIDC credentials are missing` | ✅ |
| G-03/G-04 | tadmin | `workspace create --name ws-tenant-a` / `-b` | `Created workspace` | ✅ |
| G-05 | alice | `workspace create --name ws-by-alice` | `role 'os-admin' required` | ✅ |
| G-06/G-07 | tadmin | `workspace member add --workspace ws-… --subject <entryUUID> --role user` | `added` (or `already exists`) | ✅ |
| G-08/G-09 | alice / bob | `workspace list` | only own Workspace | ✅ |
| G-10/G-10b | alice | `--workspace ws-tenant-a sandbox create --name p3-a1` / `sandbox list` | `created` / lists `p3-a1` | ✅ |
| G-11 | alice | same with `--workspace ws-tenant-b` | `not a member of workspace 'ws-tenant-b'` | ✅ |
| G-12/G-12b | alice after member add | `workspace list` / create `p3-a3` in `ws-tenant-b` | sees both / **succeeds** (positive control) | ✅ |
| G-13 | alice after member remove | `workspace list` | only `ws-tenant-a` | ✅ |

CLI output routing matters: the TLS WARN goes to **stdout** (it breaks `-o json`), the `Error: ×` block goes to
**stderr** and does not reliably reach a command-substitution pipe. Assert on a captured file, not `$(…)`.

### 12.4 IV. Cross-system consistency

| Case | Actor | Expected | Measured |
|---|---|---|---|
| C-01 | platform | apiserver `--oidc-groups-claim=groups` and gateway.toml `roles_claim = "groups"` | ✅ same claim name |
| C-02 | platform (directory change) | after adding alice to `tenant-b-users` **and dropping her local federated copy**, a fresh token contains `tenant-b-users` | ✅ |
| C-03 | alice | `auth can-i list pods -n tenant-b-runtime` = `yes` with no RBAC change | ✅ |
| C-04 | alice | Gateway `workspace list` still shows **only** `ws-tenant-a` — membership does not follow directory groups | ✅ (by design, a limitation) |

Why the local copy must be dropped: Keycloak 26.4 lazily imports federated users and caches them; changing directory
groups does not refresh the cached copy, and re-running the realm job does not help. There is **no working sync path**:
`kcadm create user-storage/<id>/sync` → `Missing action`; REST `POST …/sync?action=import|changedUsersSync` → HTTP 400
`Unknown action`; `serverinfo` exposes only `importEnabled` / `syncRegistrations`. The only measured mechanism is
`kcadm delete users/<id>` so the next authentication re-imports from LDAP.

### 12.5 V. Acceptance criteria

| Area | Pass criterion | Verdict |
|---|---|---|
| Identity chain | `sub` == entryUUID for all three users; `groups` derived from directory groups; `tenant` from the directory; no hand-maintained users/roles | ✅ |
| K8s isolation | own tenant: `can-i` yes **and** real create succeeds; other tenant: no **and** real create denied; cluster-scoped no | ✅ |
| OpenShell isolation | own Workspace create/list works; other Workspace denied with `not_workspace_member`; `os-admin` required to create Workspaces | ✅ |
| Consistency | same claim and same subject on both sides; a directory-only change moves K8s authorization | ⚠️ conditional (drop local copy; membership not synced) |
| Failure observability | every denial is greppable and distinguishable from a configuration error | ✅ |
| Tenant network isolation | policies present; cross-tenant blocked; same-tenant positive control reaches; additivity recorded | ✅ |

Script summary: `PASS=49 FAIL=0` (the previous run's `PASS=46 FAIL=3` came entirely from a `ws-tenant-a` stuck in
`Terminating`; see §12.7 item 1).

### 12.6 Holes in the stated architecture constraints, and corrections

| # | Constraint / assumption | Measured hole | Correction |
|---|---|---|---|
| a | A federated user's `sub` is usable as identity | the default `sub` is Keycloak's local id and **changes on every re-import** | set `uuidLDAPAttribute=entryUUID` and map `sub` from `LDAP_ID` (done; keep it in provisioning checks) |
| b | each side configures its own claim | apiserver reads top-level claims only, and fails **silently** with a nested claim | one flat `groups` on both sides (done) |
| c | `--oidc-client-id` validates `aud` | v1.37 has no `--oidc-audience`; other clients' tokens are accepted | `--oidc-required-claim=aud=openshell-cli` (done; change three places together when rotating audience) |
| d | "namespace `tenant-a`" exists | it does not; a tenant owns a set of prefixed namespaces | per-namespace RoleBindings generated by the provisioning flow (done here manually) |
| e | Workspace membership follows directory groups | it does not — membership is a resource table keyed by subject | a directory-group → Workspace-member sync controller (production) |
| f | a NetworkPolicy boundary stays fixed | NetworkPolicy is additive; a tenant can widen it (N-04 `BLOCKED → REACHED`) | accept + document, or enforce via Capsule `spec.rules.enforce.policies` / Antrea ClusterNetworkPolicy |
| g | OIDC device flow is just CLI plumbing | without `oauth2.device.authorization.grant.enabled=true` + PKCE S256 the CLI cannot log in, so no case can run | keep both attributes in the client template (done) |
| h | a directory change takes effect on the next request | Keycloak caches the federated user and 26.4 has no working sync API | POC drops the local copy; production needs a syncer, a per-request User Storage SPI, or an accepted TTL |

### 12.7 Manual re-check

```bash
ssh root@192.168.5.190 && cd /root/poc2
bash phases/14-identity-federation.sh 2>&1 | tee /tmp/p14f.log      # must end PASS=49 FAIL=0
CLI=vendor/openshell-cli-0.1.7/openshell
OPENSHELL_GATEWAY_INSECURE=true $CLI -g p3-alice whoami -o json
OPENSHELL_GATEWAY_INSECURE=true $CLI -g p3-alice workspace list     # only ws-tenant-a
kubectl --context kind-agent-runtime-poc --kubeconfig=/tmp/p3/kc-alice.yaml auth can-i list pods -n tenant-b-runtime
```

Five ways to misjudge this run: (1) a workspace delete is asynchronous and blocks at `Terminating` while it still
holds sandboxes — delete `sandbox --all` first and wait for the name to disappear; (2) reusing the default kubeconfig
lets the client certificate override the token — build a token-only kubeconfig; (3) reusing a stale token gives
`Unauthorized`, which is expiry, not a directory change that failed to apply — always mint a fresh token; (4)
`kubectl exec` without `-i` silently drops stdin (0-byte ldif, exit 0) — read the directory back to confirm; (5) the
CLI's WARN is on stdout and its `Error:` block may miss a pipe — assert on a captured file.

## 13. POC4 (round 4, 2026-11-11): a Deployment Gateway on PostgreSQL, and several gateways sharing one database

> Scripts: [`poc/openshell4/80-gateway-pg.sh`](poc/openshell4/80-gateway-pg.sh) (installs PostgreSQL and two Helm
> releases), [`81-shared-db-verify.sh`](poc/openshell4/81-shared-db-verify.sh) (the verification matrix),
> [`82-cli-login.sh`](poc/openshell4/82-cli-login.sh) (device-flow login).
> Raw remote output: `/tmp/p4-81f.log`, ending in `PASS=33 FAIL=0`.
> The identity chain is still POC3's (Keycloak NodePort 31443); only the Gateway's storage changed this round.

### 13.0 Verdict

**Yes, it works.** `workload.kind: deployment` plus `server.externalDbSecret` moves the Gateway's control-plane
state into an external PostgreSQL. **Two independent Helm releases (p4a / p4b) sharing one PostgreSQL really do
read the same state**: a workspace / member / provider created on A is immediately readable on B; deleting all of
p4a's Pods does not lose it; non-member bob is still denied on B. A single release scaled to two replicas also
works: kill one replica and 10/10 calls succeed, and the replica is recreated.

Three preconditions must hold together, or "shared database" means only that two processes connected to the same
port:

| Precondition | Why | How this round checked it |
|---|---|---|
| Both releases share the **same KEK Secret** | Credentials are AES-256-GCM ciphertext in the database; the KEK defaults to one Secret per release | K-04/K-05 assert the same Secret reference and byte-identical values; **the decrypt-failure path was not measured** (§13.3) |
| Both releases use the **same OIDC configuration** | Identity comes from the token; a different issuer / audience / role mapping gives the same user different rights on each gateway | both releases render from the same values file (§13.1) |
| They share a **runtime namespace** (`poc4-runtime` here) | A Sandbox is a Kubernetes object, not a PostgreSQL row; both gateways' Kubernetes drivers list Sandboxes from this namespace | `kubectl -n poc4-runtime get sandboxes`; the `objects` table has **no** sandbox rows |

⚠ The third row is the easiest to misread as "PostgreSQL shares sandbox state". It does **not**: sandbox visibility
across gateways comes from the shared runtime namespace plus the Kubernetes driver; PostgreSQL shares the
**control-plane objects** — workspace / member / provider / provider profile. Keep the two kinds of evidence apart.

| Surface | Verdict | Evidence |
|---|---|---|
| Shape | ✅ Deployment, not StatefulSet | D-01/D-02; `kubectl get deploy,sts` shows only deployments |
| Storage entry point | ✅ `OPENSHELL_DB_URL` comes from a Secret; no `--db-url` in the args | D-03..D-06 |
| PostgreSQL schema | ✅ created automatically at Gateway startup | 7 rows in `_sqlx_migrations`; p4b logs `relation "_sqlx_migrations" already exists, skipping` |
| Control-plane sharing | ✅ written on A, read on B | S-02/S-03, K-01/K-02/K-03 |
| Survives restart | ✅ after deleting every p4a Pod, B still reads it; a rebuilt p4a reads it too | S-08..S-10 |
| Authorization still holds | ✅ non-member bob is denied on B | S-06/S-07 |
| Chart hard constraints | ✅ negative controls fail with exact errors | S-11..S-14 |
| Multiple replicas of one release | ✅ 2 replicas; kill one, 10/10 calls succeed, self-heals | S-15..S-18 |
| Credentials in the shared DB | ✅ the provider row is in PG and both gateways read the same id; KEK config matches | K-01..K-05 (incl. K-02a) |
| Credential decryption failure | ⚠️ **not measured** (not faked) | §13.3 |

---

### 13.1 Configuration

#### 13.1.1 Chart 0.1.7 hard constraints: the two values must appear together

These are not two independent switches. `workload.kind` and `server.externalDbSecret` are coupled in the chart:

| Configuration | Result (exact helm text) | Case |
|---|---|---|
| `workload.kind=statefulset` + `replicaCount=2`, no externalDbSecret | `Error: execution error at (helm-chart/templates/supervisor.yaml:1:4): replicaCount > 1 requires server.externalDbSecret; multiple gateway replicas cannot share the default per-pod SQLite database.` | S-11 |
| `workload.kind=deployment`, no externalDbSecret | `Error: execution error at (helm-chart/templates/supervisor.yaml:1:4): workload.kind=deployment requires server.externalDbSecret; use workload.kind=statefulset for the default SQLite database.` | S-12 |
| `workload.kind=deployment` + `server.externalDbSecret=p4-db-uri` | renders `OPENSHELL_DB_URL` (from Secret key `uri`) and does **not** render `--db-url` | S-13/S-14 |

Also, chart 0.1.7 **no longer ships PostgreSQL**: `postgres.enabled` is gone; the platform must provide a database.

#### 13.1.2 PostgreSQL (minimal shape for this POC)

[`poc/openshell4/postgres.yaml`](poc/openshell4/postgres.yaml): the `poc4-db` namespace, a single
`postgres:16-alpine` replica, a 2Gi PVC (`subPath: pgdata`), `pg_isready` probes, and a `postgres:5432` Service.
The password lives in the `postgres-credentials` Secret. **This is a POC shape, not a production one** (no HA,
backup, pooler or TLS).

The connection string goes into a Secret in each Gateway namespace (Secrets cannot be referenced across
namespaces, so there are two same-named, same-valued `p4-db-uri` Secrets, key `uri`):

```
postgresql://openshell:poc4pass@postgres.poc4-db.svc.cluster.local:5432/openshell
```

#### 13.1.3 The two releases differ only in name, namespace and port

| Item | p4a | p4b |
|---|---|---|
| Helm release | `p4a` | `p4b` |
| namespace | `poc4-gw-a` | `poc4-gw-b` |
| DB Secret | `p4-db-uri` (same value) | `p4-db-uri` (same value) |
| KEK Secret | `p4-credential-kek` | a copy with the same value |
| runtime namespace | `poc4-runtime` | the same one |
| workspace chart | `os-ws-p4a` (SAs `p4a-openshell` / `p4a-openshell-sandbox`) | `os-ws-p4b` (SAs `p4b-...`) |
| NodePort | 31445 | 31446 |
| OIDC | same issuer / audience / rolesClaim | same |

The workspace chart is installed twice to give each Gateway its own ServiceAccount and NetworkPolicy;
`server.sandboxNamespace` points at `poc4-runtime` (shared mode). The Gateway-generated `openshell-client-tls`
only needs copying once into the shared runtime namespace (the old POC2 trap: without it the supervisor hangs in
`ContainerCreating`).

#### 13.1.4 The key values

```yaml
workload:
  kind: deployment

server:
  externalDbSecret: "p4-db-uri"      # Secret key: uri (paired with deployment, see 13.1.1)
  credentialStorage:
    existingSecret: "p4-credential-kek"   # both gateways must share the value; the default is one per release
  oidc: { issuer: "__ISSUER__", audience: "openshell-cli", rolesClaim: "groups",
          adminRole: "os-admin", userRole: "os-user", caConfigMapName: "oidc-ca" }
  drivers:
    kubernetes:
      workspaceMode: shared
      allowDriverConfig: true
```

Full file: [`poc/openshell4/gateway-pg-values.yaml`](poc/openshell4/gateway-pg-values.yaml).

---

### 13.2 Measured results (`PASS=33 FAIL=0`)

**This round rebuilt from an empty database first**: deleting the PG Deployment/PVC/Service left
`information_schema` with **0 tables** (a 7.5 MB empty template); starting the two gateways then made the gateway
create the schema itself (7 `_sqlx_migrations` rows), with `objects` holding only the default workspace, 2
`gateway_member` rows and 1 `reconciler_lease`. The full matrix re-run against that empty database still ended
`PASS=33 FAIL=0`: the state comes entirely from PostgreSQL, not from leftovers of the previous run.

**Shape and storage (D)**: both releases are Deployments; both `OPENSHELL_DB_URL` values reference `p4-db-uri`;
the container args are only `--config /etc/openshell/gateway.toml` (no `--db-url`). PostgreSQL holds two tables:

```
_sqlx_migrations    7 rows
objects             workspace / workspace_member / gateway_member /
                    provider / provider_profile / credential.gateway-encrypted /
                    reconciler_lease (serialized payload, keyed by object_type + workspace)
```

p4a started first and created the schema; p4b logs
`sqlx::postgres::notice: relation "_sqlx_migrations" already exists, skipping` — the two releases share one
schema rather than each creating its own. Both log
`sizing Postgres connection pools max_connections=10 lock_max_connections=4`; but the pools open **lazily**: with
three gateway Pods online (two p4a replicas + p4b), `pg_stat_activity` held only 11–14 sessions in total (11 in
this round's D-07) — not the 3×14 ceiling.

**Control-plane sharing (S)**: a workspace created on p4a is immediately visible in p4b's `workspace list`;
adding alice as a member makes it visible to p4b-alice; a sandbox created on p4a appears in p4b's `sandbox list`.
Creating the same workspace name on p4b returns `already exists`; non-member bob can neither see nor enter it on
p4b (the denial text reads `not a member of workspace '...'`).

**Restarts (S-08..S-10)**: deleting **all** of p4a's Pods leaves the workspace and sandbox readable from p4b; a
rebuilt p4a reads the same state back. The state is not in a per-Pod SQLite file.

**Chart negative controls (S-11..S-14)**: the exact errors are in §13.1.1; the positive render contains
`OPENSHELL_DB_URL` and no `--db-url`.

**Replicas of one release (S-15..S-18)**: `replicaCount` 1 → 2 succeeds and both replicas are Running; killing one
leaves 10/10 consecutive `whoami` calls succeeding (the other replica serves them), and the replica count
returns to 2.

**Credentials (K)**: import a minimal custom provider profile (`id: poc4-kek`, credential `API_KEY`); `provider
create` on A returns `✓ Created provider p4-kek`. Querying PostgreSQL directly then finds a row in `objects` with
`object_type='provider'`, `name='p4-kek'` under this run's workspace (K-02) — the credential ciphertext really is in
PostgreSQL, not locally on A. `provider get` on B returns the **same id**: this round A and B both read
`b9b12042-8ca8-4bcb-9868-419e17164313` (K-03; a re-run creates a new workspace and therefore a new id — compare
"the two gateways agree", not a fixed value), with the same `Credential keys: API_KEY`. Both gateways'
`OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY` reference `p4-credential-kek`, and the values in the two
namespaces are byte-identical.

---

### 13.3 How far can several gateways share one PostgreSQL?

Three layers, three different answers:

1. **Several replicas of one release: supported and measured.**
   The chart requires `externalDbSecret` whenever `replicaCount>1` (it refuses otherwise, see S-11); this round
   used Deployment + externalDbSecret, ran 2 replicas, and 10/10 calls succeeded after killing one. This is the
   right way to make the Gateway HA.

2. **Two independent releases sharing one database: technically works, but it is not a chart contract.**
   p4a and p4b are separate Helm releases, separate namespaces and separate NodePorts, connected to the same
   database; control-plane objects are shared. The database contains exactly one `reconciler_lease` row; at the end
   of this round one gateway had logged `acquired reconciler lease` and was still holding it, while the other only
   logged `reconciler lease coordinator started` — so the gateways' reconcilers use a database lease for mutual
   exclusion (which one wins depends on start order: after the PG rebuild, p4a took it on the first boot, and one
   restart cycle later it was p4b). ⚠ Boundary: the old Pods deleted in S-08 took their logs with them, so earlier
   contention cannot be read back; and whether this fully prevents duplicate reconciliation was not stress-tested.
   But the chart neither documents nor validates "several releases on one database", so you must arrange:
   - **the same KEK**, or credentials written by A cannot be decrypted by B (design constraint, see below);
   - **identical OIDC configuration** (issuer/audience/rolesClaim/role names), or one user has different rights
     on each gateway;
   - **identical versions** (one set of sqlx migrations); when upgrading, upgrade one gateway and confirm the
     migration before touching the other;
   - **capacity**: each gateway process sizes its pool at 10 normal + 4 lock connections (startup log), so leave
     headroom in PostgreSQL's `max_connections`; in practice pools open lazily — this round three Pods held 11–14
     sessions in total (11 in D-07). That is an **observation, not a ceiling**: under load it grows toward 10+4 per process;
   - **concurrent writes**: `objects` has a `resource_version` column; whether it is used for optimistic locking,
     and what two gateways updating the same object get back, were **not load-tested** — do not treat this as a
     strong consistency coordinator.

3. **KEK decrypt failure: not measured this round, so it is not recorded as PASS.**
   The chart stores credentials as AES-256-GCM ciphertext and defaults the KEK to a per-release Secret — so
   "sharing a database requires sharing the KEK" is a **design constraint**. Empirically, though: after changing
   p4b's KEK to a different value and restarting it, `provider get` still succeeded (it reads metadata, not
   plaintext); and a sandbox created with the minimal custom profile did not produce an observable
   decrypt-failure surface. This report therefore records K-04/K-05 as **configuration consistency** only, and
   does not claim to have measured a decrypt failure.

**In one sentence**: pointing several gateways at one PostgreSQL really does share state, but it is "several
control planes sharing a database", not "a stateless service you can scale freely". KEK, OIDC, version and
connection count must be managed together.

---

### 13.4 The real cost of moving from SQLite to PostgreSQL

- **There is no migration tool**: the CLI has no `migrate` / `export` subcommand (`openshell --help` lists
  sandbox / provider / profile / gateway, etc.); the Gateway creates its schema with sqlx at startup but does
  **not** copy objects out of an old SQLite database.
- **SQLite data is per-Pod**: the default StatefulSet gives every Pod its own file, and a Deployment no longer
  mounts it. Existing workspaces / members / providers must be **recreated**; a sandbox is runtime state and is
  simply recreated.
- **Change the KEK and old credentials are unreadable**: to keep them, mount the old KEK as a Secret on the new
  Deployment; a new KEK invalidates every stored credential and they must be re-entered.
- **A workable migration**: stand up PostgreSQL and the new Gateway (new NodePort), re-declare
  workspaces/members/providers with the CLI, verify, then move traffic. Do not expect an in-place upgrade to move
  the data.

---

### 13.5 Manual re-check (NodePort, no port-forward)

```bash
ssh root@192.168.5.190
cd /root/poc2

# 0) POC3 identity chain is already up (Keycloak 31443)
kubectl --context kind-agent-runtime-poc -n identity get cm kc-config

# 1) install PostgreSQL + p4a/p4b (safe to re-run)
bash openshell4/80-gateway-pg.sh

# 2) CLI device-flow login (once per profile)
bash openshell4/82-cli-login.sh

# 3) run the matrix; it must end PASS=33 FAIL=0
bash openshell4/81-shared-db-verify.sh 2>&1 | tee /tmp/p4-81f.log

# 3b) to start over from an empty database (⚠ wipes every workspace/provider/credential, irreversible)
#     order: stop gateways → delete PG → recreate empty → clean orphan sandboxes → start gateways
CFG="--context kind-agent-runtime-poc"
kubectl $CFG -n poc4-gw-a scale deploy/p4a-openshell --replicas=0
kubectl $CFG -n poc4-gw-b scale deploy/p4b-openshell --replicas=0
kubectl $CFG delete -f openshell4/postgres.yaml
kubectl $CFG apply -f openshell4/postgres.yaml
kubectl $CFG -n poc4-db rollout status deploy/postgres --timeout=180s
kubectl $CFG -n poc4-runtime delete sandboxes.agents.x-k8s.io --all
kubectl $CFG -n poc4-gw-a scale deploy/p4a-openshell --replicas=1
kubectl $CFG -n poc4-gw-b scale deploy/p4b-openshell --replicas=1
#     after boot the gateway creates the schema: psql -c 'select count(*) from _sqlx_migrations' → 7

# what is actually in PostgreSQL
P=$(kubectl --context kind-agent-runtime-poc -n poc4-db get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl --context kind-agent-runtime-poc -n poc4-db exec $P -- \
  psql -U openshell -d openshell -c "select object_type,count(*) from objects group by 1 order by 1"

# both releases' DB entry point (both must be p4-db-uri; args must have no --db-url)
kubectl --context kind-agent-runtime-poc -n poc4-gw-a get deploy p4a-openshell \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}{"\n"}'
kubectl --context kind-agent-runtime-poc -n poc4-gw-b get deploy p4b-openshell \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}{"\n"}'
```

**Five ways to misjudge this run (all hit this round):**

1. **A workspace delete is blocked by providers/profiles.** Deleting sandboxes is not enough: while a workspace
   still holds a provider or provider profile, `workspace delete` returns
   `still contains resources: provider profile` and the workspace stays `Terminating`; the next
   `workspace create` gets `already exists`, and every later `profile import` / `sandbox create` returns
   `FAILED_PRECONDITION`. Clean up in the order **sandbox → provider → profile → workspace**. The script uses a
   fresh workspace name per run so it cannot mistake last round's state for this round's success.
2. **Sandboxes are not in PostgreSQL.** Seeing a sandbox from another gateway is the shared runtime namespace,
   not evidence of database sharing; do not write "PostgreSQL stores the sandboxes".
3. **The CLI's WARN and its result are on different lines.** Piping through `tr '\n' ' '` and then
   `grep -v WARN` deletes the result with it and leaves empty evidence; filter per line, or assert on the captured
   file.
4. **`profile import` is workspace-scoped.** A profile imported in A's workspace does not appear in another
   workspace; when `provider create` says `provider profile '...' not found`, check where you imported it.
5. **Never base64 the KEK Secret value twice.** `jsonpath` already returns base64; recreating the Secret with
   `--from-literal` encodes the base64 text again and the Gateway rejects it with
   `key_encryption_key_env value must decode to exactly 32 bytes`. Use `base64 -d`, or patch the `data` field
   directly.

---

### 13.6 Production deployment (designed and rendered, not executed on the POC cluster)

POC4 answers "can this work"; for production use [`poc/openshell4/production/`](poc/openshell4/production/):

| File | Purpose |
|---|---|
| `README.md` | Production runbook: capacity math, upgrade/migration procedure, backup/restore, security, acceptance checklist |
| `values-gateway-prod.yaml` | 3-replica Deployment, external PG, edge TLS termination + OIDC, resources/anti-affinity |
| `postgres-cnpg.yaml` | CloudNativePG 3 instances + PgBouncer (session) + S3 backups (managed PG in runbook §3.1) |
| `deploy-prod.sh` | Idempotent deploy script (preflight → workspace resources → gateway → PDB/monitoring → assertions) |
| `secrets-external-secrets.yaml` | DB URI / KEK injected from Vault/KMS via External Secrets |
| `networkpolicy.yaml`, `pdb-gateway.yaml`, `certificate-edge-tls.yaml` | Network isolation, availability, edge certificate |
| `servicemonitor.yaml`, `prometheusrule.yaml` | Scrape config and alerts (metric names scraped from POC4) |

Key differences from POC4:

- **One release with 3 replicas**, not two independent releases on one database (the latter is not a chart
  contract — §13.3).
- External PG must be **TLS + multi-AZ + PITR**: managed PostgreSQL (preferred) or a 3-instance CNPG
  cluster; PgBouncer must run **session** mode (sqlx uses server-side prepared statements).
- The edge terminates TLS at Gateway API; the gateway speaks plaintext in-cluster + OIDC (a path the chart
  explicitly supports), so mTLS client certificates are no longer distributed to every CLI.
- The KEK is injected from Vault/KMS and **never rotated**; PG backups hold only ciphertext, so a restore
  drill must restore the KEK Secret as well.
- Upgrade order: **scale to 1 replica → upgrade image/values → verify `_sqlx_migrations` → scale back to 3**,
  so replicas never race on DDL.

**Validation boundary**: `values-gateway-prod.yaml` renders cleanly with `helm template`
(Deployment/3 replicas, `OPENSHELL_DB_URL` from a Secret, no `--db-url` in args, GRPCRoute/Gateway HTTPS,
OIDC written into the TOML, 10+4 connection pools, metrics on 9090); however managed PG, CNPG,
cert-manager, External Secrets, NetworkPolicy, backup/restore, concurrent migrations and HPA have
**not been executed on this POC cluster** — each is listed in `production/README.md` §12.
These are deployment designs, not verified results.
