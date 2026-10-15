"""Offline check of the Mini-Agent OTel instrumentation: fake LLM + fake tool, in-memory exporter."""
import asyncio
import json
import tempfile

from opentelemetry import baggage, context, trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

exporter = InMemorySpanExporter()
provider = TracerProvider()
provider.add_span_processor(SimpleSpanProcessor(exporter))
trace.set_tracer_provider(provider)

from mini_agent.agent import Agent  # noqa: E402
from mini_agent.llm import LLMClient  # noqa: E402
from mini_agent.retry import RetryConfig, async_retry  # noqa: E402
from mini_agent.schema import FunctionCall, LLMResponse, TokenUsage, ToolCall  # noqa: E402
from mini_agent.tools.base import Tool, ToolResult  # noqa: E402


class FakeClient:
    """Step 1: two transient failures (retried), then a tool call. Step 2: final answer."""

    def __init__(self):
        self.calls = 0
        self.retry_callback = None

    async def generate(self, messages, tools=None):
        @async_retry(config=RetryConfig(max_retries=3, initial_delay=0.01))
        async def _call():
            self.calls += 1
            if self.calls <= 2:
                raise TimeoutError("Timeout on reading data from socket")
            if self.calls == 3:
                return LLMResponse(content="查一下", finish_reason="tool_use",
                                   tool_calls=[ToolCall(id="toolu_01", type="function",
                                               function=FunctionCall(name="query_bi", arguments={"sql": "select 1"}))],
                                   usage=TokenUsage(prompt_tokens=1200, completion_tokens=30, total_tokens=1230))
            return LLMResponse(content="昨日营收 42", finish_reason="end_turn",
                               usage=TokenUsage(prompt_tokens=1300, completion_tokens=12, total_tokens=1312))
        return await _call()


class QueryBI(Tool):
    name = "query_bi"
    description = "run BI sql"
    parameters = {"type": "object", "properties": {"sql": {"type": "string"}}}

    async def execute(self, sql: str):
        return ToolResult(success=True, content="[[42]]")


async def main():
    llm = LLMClient(api_key="x", model="global.anthropic.claude-sonnet-4-6")
    llm._client = FakeClient()
    agent = Agent(llm, "You are a BI agent.", [QueryBI()], workspace_dir=tempfile.mkdtemp())
    agent.add_user_message("昨天营收多少？")
    token = context.attach(baggage.set_baggage("session.id", "sess-123"))
    try:
        await agent.run()
    finally:
        context.detach(token)


asyncio.run(main())

spans = sorted(exporter.get_finished_spans(), key=lambda s: s.start_time)
by_id = {s.context.span_id: s for s in spans}
for s in spans:
    depth, p = 0, s.parent
    while p is not None and p.span_id in by_id:
        depth += 1
        p = by_id[p.span_id].parent
    print("  " * depth + f"{s.name}  scope={s.instrumentation_scope.name}  trace={s.context.trace_id:032x}"[:120])
    for k, v in s.attributes.items():
        v = v if len(str(v)) < 160 else str(v)[:160] + "..."
        print("  " * depth + f"    {k} = {v}")
    for e in s.events:
        print("  " * depth + f"    [event] {e.name} {dict(e.attributes)}")
assert len({s.context.trace_id for s in spans}) == 1, "all spans must share one trace"
print("\nOK:", len(spans), "spans, one trace")

chat1 = [s for s in spans if s.name.startswith("chat")][0]
tool = [s for s in spans if s.name.startswith("execute_tool")][0]
for s in spans:
    assert s.attributes.get("session.id") == "sess-123", s.name
assert json.loads(tool.attributes["gen_ai.tool.call.arguments"]) == {"sql": "select 1"}
out = json.loads(chat1.attributes["gen_ai.output.messages"])
assert out[0]["parts"][1] == {"type": "tool_call", "id": "toolu_01", "name": "query_bi", "arguments": {"sql": "select 1"}}
assert json.loads(chat1.attributes["gen_ai.tool.definitions"])[0]["name"] == "query_bi"
assert chat1.attributes["gen_ai.provider.name"] == "anthropic"
print("OK: session.id on all spans; tool_call.id toolu_01 links chat -> execute_tool; tool definitions present")
