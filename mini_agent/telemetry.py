"""OpenTelemetry instrumentation for Mini-Agent (AgentCore Observability / Evaluations).

Emits three span types following the OpenTelemetry GenAI semantic conventions:

    invoke_agent <agent>      one per agent turn (Agent.run / ACP _run_turn)
      chat <model>            one per LLM call (LLMClient.generate), retries as span events
      execute_tool <tool>     one per tool call

Only the opentelemetry-api package is required here. The SDK/exporter is supplied at
runtime by ADOT (`opentelemetry-instrument python ...` with aws-opentelemetry-distro);
without it every call below is a no-op, so this module is safe to ship unconditionally.

Env switches:
    MINI_AGENT_OTEL_CAPTURE_CONTENT=false   drop prompts/responses/tool payloads from spans
    MINI_AGENT_OTEL_MAX_CONTENT_CHARS=N     truncate each content attribute (default 32000)
"""

from __future__ import annotations

import functools
import json
import os
from typing import Any, Awaitable, Callable

from opentelemetry import baggage, trace
from opentelemetry.trace import SpanKind, Status, StatusCode

# AgentCore Evaluations' generic framework support only reads scopes with this prefix.
SCOPE_NAME = "opentelemetry.instrumentation.mini_agent"
_tracer = trace.get_tracer(SCOPE_NAME, "0.1.0")

AGENT_NAME = os.getenv("MINI_AGENT_NAME", "mini-agent")


def _capture_content() -> bool:
    return os.getenv("MINI_AGENT_OTEL_CAPTURE_CONTENT", "true").lower() != "false"


def _clip(text: str) -> str:
    limit = int(os.getenv("MINI_AGENT_OTEL_MAX_CONTENT_CHARS", "32000"))
    return text if len(text) <= limit else text[:limit] + "...[truncated]"


def _stamp_session(span) -> None:
    """Copy session.id from baggage onto the span, so turns group in the AgentCore
    Sessions view regardless of whether the exporter propagates baggage itself."""
    sid = baggage.get_baggage("session.id")
    if sid:
        span.set_attribute("session.id", str(sid))


def _json(obj: Any) -> str:
    return _clip(json.dumps(obj, ensure_ascii=False, default=str))


def _text_of(content: str | list[dict[str, Any]]) -> str:
    """Mini-Agent content is either a string or a list of Anthropic-style blocks."""
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content if isinstance(b, dict))


# ---------------------------------------------------------------------------
# Message conversion: Mini-Agent Message -> GenAI semconv message JSON
# ---------------------------------------------------------------------------

def _to_genai_message(msg) -> dict[str, Any]:
    parts: list[dict[str, Any]] = []
    if msg.role == "tool":
        parts.append({"type": "tool_call_response", "id": msg.tool_call_id,
                      "response": _text_of(msg.content)})
    else:
        text = _text_of(msg.content)
        if text:
            parts.append({"type": "text", "content": text})
        for tc in msg.tool_calls or []:
            parts.append({"type": "tool_call", "id": tc.id, "name": tc.function.name,
                          "arguments": tc.function.arguments})
    return {"role": msg.role, "parts": parts}


def _tool_definitions(tools: list | None) -> list[dict[str, Any]]:
    defs = []
    for t in tools or []:
        if isinstance(t, dict):  # already a schema dict (ACP path passes dicts)
            defs.append({"type": "function", "name": t.get("name"),
                         "description": t.get("description"),
                         "parameters": t.get("input_schema") or t.get("parameters")})
        else:
            defs.append({"type": "function", "name": t.name,
                         "description": t.description, "parameters": t.parameters})
    return defs


# ---------------------------------------------------------------------------
# 1. invoke_agent: decorator for the agent-turn entry points
# ---------------------------------------------------------------------------

def traced_agent_turn(get_agent: Callable[..., Any]):
    """Wrap an async method that runs one agent turn and returns the final text.

    get_agent(self, *args, **kwargs) must return the Agent instance, so the same
    decorator works for Agent.run (self) and ACP's _run_turn (state.agent).
    """

    def decorator(fn: Callable[..., Awaitable[str]]):
        @functools.wraps(fn)
        async def wrapper(self, *args, **kwargs):
            agent = get_agent(self, *args, **kwargs)
            with _tracer.start_as_current_span(f"invoke_agent {AGENT_NAME}",
                                               kind=SpanKind.INTERNAL) as span:
                _stamp_session(span)
                span.set_attribute("gen_ai.operation.name", "invoke_agent")
                span.set_attribute("gen_ai.agent.name", AGENT_NAME)
                span.set_attribute("gen_ai.request.model", getattr(agent.llm, "model", ""))
                user_prompt = next((_text_of(m.content) for m in reversed(agent.messages)
                                    if m.role == "user"), "")
                if _capture_content():
                    span.set_attribute("gen_ai.task.input", _clip(user_prompt))
                    # Fallback attribute AgentCore reads from any scope.
                    span.set_attribute("agentcore.invocation.user_prompt", _clip(user_prompt))
                result = await fn(self, *args, **kwargs)
                if _capture_content() and isinstance(result, str):
                    span.set_attribute("gen_ai.task.output", _clip(result))
                    span.set_attribute("agentcore.invocation.agent_response", _clip(result))
                return result

        return wrapper

    return decorator


# ---------------------------------------------------------------------------
# 2. chat: decorator for LLMClient.generate
# ---------------------------------------------------------------------------

def traced_generate(fn):
    @functools.wraps(fn)
    async def wrapper(self, messages, tools=None):
        model = getattr(self, "model", "unknown")
        with _tracer.start_as_current_span(f"chat {model}", kind=SpanKind.CLIENT) as span:
            _stamp_session(span)
            span.set_attribute("gen_ai.operation.name", "chat")
            provider = getattr(self, "provider", "")
            provider = str(getattr(provider, "value", provider))
            span.set_attribute("gen_ai.provider.name", "aws.bedrock" if provider == "bedrock" else provider)
            span.set_attribute("gen_ai.request.model", model)
            if _capture_content():
                system = [m for m in messages if m.role == "system"]
                if system:
                    span.set_attribute("gen_ai.system_instructions", _json(
                        [{"type": "text", "content": _text_of(m.content)} for m in system]))
                span.set_attribute("gen_ai.input.messages", _json(
                    [_to_genai_message(m) for m in messages if m.role != "system"]))
                span.set_attribute("gen_ai.tool.definitions", _json(_tool_definitions(tools)))

            resp = await fn(self, messages, tools)  # exceptions are recorded by the SDK

            span.set_attribute("gen_ai.response.finish_reasons", [resp.finish_reason])
            if resp.usage:
                span.set_attribute("gen_ai.usage.input_tokens", resp.usage.prompt_tokens)
                span.set_attribute("gen_ai.usage.output_tokens", resp.usage.completion_tokens)
            if _capture_content():
                out = _to_genai_message(type("M", (), {
                    "role": "assistant", "content": resp.content,
                    "tool_calls": resp.tool_calls, "tool_call_id": None})())
                out["finish_reason"] = resp.finish_reason
                span.set_attribute("gen_ai.output.messages", _json([out]))
            return resp

    return wrapper


def record_retry(exception: Exception, attempt: int, delay: float) -> None:
    """Called from retry.async_retry: lands as an event on the enclosing chat span,
    so a 4x600s socket-timeout chain shows up inside ONE chat span with 3 events."""
    trace.get_current_span().add_event("gen_ai.retry", {
        "retry.attempt": attempt,
        "retry.delay_s": delay,
        "error.type": type(exception).__name__,
        "error.message": _clip(str(exception)),
    })


# ---------------------------------------------------------------------------
# 3. execute_tool: helper replacing `await tool.execute(**arguments)`
# ---------------------------------------------------------------------------

async def traced_tool_call(tool, tool_call_id: str, arguments: dict[str, Any]):
    with _tracer.start_as_current_span(f"execute_tool {tool.name}",
                                       kind=SpanKind.INTERNAL) as span:
        _stamp_session(span)
        span.set_attribute("gen_ai.operation.name", "execute_tool")
        span.set_attribute("gen_ai.tool.name", tool.name)
        span.set_attribute("gen_ai.tool.call.id", tool_call_id)  # links to the chat span's tool_call
        span.set_attribute("gen_ai.tool.type", "function")
        if _capture_content():
            span.set_attribute("gen_ai.tool.call.arguments", _json(arguments))

        result = await tool.execute(**arguments)  # exceptions propagate; SDK records them

        if not result.success:
            span.set_status(Status(StatusCode.ERROR, _clip(result.error or "")))
            span.set_attribute("error.type", "tool_error")
        if _capture_content():
            span.set_attribute("gen_ai.tool.call.result",
                               _clip(result.content if result.success else f"Error: {result.error}"))
        return result
