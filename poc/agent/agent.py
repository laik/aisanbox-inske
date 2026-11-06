#!/usr/bin/env python3
"""aisanbox demo agent: a real tool-using agent, instrumented with OpenTelemetry.

Runs inside an OpenShell sandbox as uid 10001. Nothing here knows about
Tetragon or the platform —— the agent just does its work and emits standard
OTLP. The platform's contribution is (a) a kernel-side view of the same
activity and (b) enforcement when the agent steps outside its boundary.
"""
import json
import os
import subprocess
import sys

from anthropic import Anthropic
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-haiku-5-5")
# The tenant/agent identity the platform put on this sandbox. We publish it on
# every span so the trace and the kernel events line up on the same key.
TENANT = os.environ.get("AISANBOX_TENANT", "unknown")
SANDBOX = os.environ.get("AISANBOX_SANDBOX", "unknown")


def init_tracing() -> trace.Tracer:
    """Standard OTel setup —— no proprietary SDK, no agent-framework dependency."""
    res = Resource.create({
        "service.name": "aisanbox-agent",
        "aisanbox.tenant": TENANT,
        "aisanbox.sandbox": SANDBOX,
    })
    tp = TracerProvider(resource=res)
    tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))  # OTEL_EXPORTER_OTLP_ENDPOINT
    trace.set_tracer_provider(tp)
    return trace.get_tracer("aisanbox.agent")


TOOLS = [{
    "name": "run_shell",
    "description": "Run a shell command inside this sandbox and return stdout/stderr.",
    "input_schema": {"type": "object",
                     "properties": {"cmd": {"type": "string"}},
                     "required": ["cmd"]},
}]


def inject_trace(env: dict) -> None:
    """Put W3C trace context into a child process's environment.

    This is the deliberate join between the two views. The child's exec is what
    Tetragon records at PROCESS_EXEC; with the agent daemon started using
    --enable-process-environment-variables, that kernel record carries the same
    traceparent string. One id, two independent sources: the application's trace
    and the kernel's.
    """
    ctx = trace.get_current_span().get_span_context()
    if not ctx.is_valid:
        return
    env["TRACEPARENT"] = f"00-{format(ctx.trace_id, '032x')}-{format(ctx.span_id, '016x')}-01"


def run_tool(tracer, name: str, tool_input: dict) -> tuple[str, bool]:
    """Execute a tool. This span is the join point with the kernel: the command
    that appears here is the same exec Tetragon records."""
    with tracer.start_as_current_span(f"tool.{name}", attributes={
            "aisanbox.tool": name,
            "gen_ai.tool.name": name,
            "gen_ai.tool.call.arguments": json.dumps(tool_input, ensure_ascii=False)}) as span:
        if name != "run_shell":
            span.set_status(trace.Status(trace.StatusCode.ERROR, "unknown tool"))
            return f"unknown tool {name}", True
        env = os.environ.copy()
        inject_trace(env)     # -> TRACEPARENT, so the kernel sees the same trace id
        try:
            p = subprocess.run(tool_input["cmd"], shell=True, capture_output=True,
                               text=True, timeout=30, env=env)
            out = (p.stdout + p.stderr)[:4000]
            span.set_attributes({"aisanbox.exit_code": p.returncode,
                                 "aisanbox.truncated": len(out) >= 4000})
            return out or "(no output)", p.returncode != 0
        except Exception as exc:                       # noqa: BLE001
            span.record_exception(exc)
            span.set_status(trace.Status(trace.StatusCode.ERROR, str(exc)))
            return f"error: {type(exc).__name__}: {exc}", True


def main() -> int:
    tracer = init_tracing()
    client = Anthropic()          # base_url / key come from the environment
    task = sys.argv[1] if len(sys.argv) > 1 else "What can you do in this sandbox?"

    # One span for the whole agent run; the Anthropic SDK's own spans
    # (anthropic.messages.create) nest underneath it automatically.
    with tracer.start_as_current_span("agent.run", attributes={
            "gen_ai.agent.name": "aisanbox-demo",
            "gen_ai.provider.name": "anthropic",
            "gen_ai.request.model": MODEL,
            "aisanbox.task": task}) as root:
        messages = [{"role": "user", "content": task}]
        served: list[str] = []
        for turn in range(6):
            resp = client.messages.create(
                model=MODEL, max_tokens=1024, tools=TOOLS, messages=messages)
            messages.append({"role": "assistant", "content": resp.content})
            root.set_attributes({
                "gen_ai.usage.input_tokens": resp.usage.input_tokens,
                "gen_ai.usage.output_tokens": resp.usage.output_tokens,
                "gen_ai.response.stop_reason": resp.stop_reason,
                # Both, on purpose: a gateway may serve a different model than the
                # one requested. Recording only the request would mislead a viewer.
                "gen_ai.response.model": resp.model})
            served.append(resp.model)
            if resp.stop_reason != "tool_use":
                break
            results = []
            for block in resp.content:
                if block.type != "tool_use":
                    continue
                out, is_err = run_tool(tracer, block.name, block.input)
                results.append({"type": "tool_result", "tool_use_id": block.id,
                                "content": out, "is_error": is_err})
            messages.append({"role": "user", "content": results})

        text = "\n".join(b.text for b in messages[-1]["content"] if getattr(b, "type", "") == "text")
        print("\n===== AGENT ANSWER =====")
        print(text or "(no text)")
        trace_id = format(root.get_span_context().trace_id, "032x")
        print("\n===== TRACE =====")
        print(f"trace_id={trace_id}")
        if served:
            print(f"model requested={MODEL} served={served[-1]}")
        print(f"look it up: http://localhost:16686/search?traceID={trace_id}")
    trace.get_tracer_provider().force_flush(timeout_millis=5000)
    return 0


if __name__ == "__main__":
    sys.exit(main())
