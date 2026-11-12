"""Offline contract test for mini_agent.telemetry against AgentCore Evaluations' generic
framework support: fake LLM + fake tool, in-memory exporter, no network.

Checks what the evaluation service relies on:
  * scope name under opentelemetry.instrumentation.*
  * invoke_agent / chat / execute_tool spans, identified by gen_ai.operation.name, one trace
  * chat + execute_tool nested under invoke_agent
  * session.id on every span (from OTel baggage)
  * content in the documented attributes (task.input/output, input/output.messages,
    tool.definitions, tool.call.arguments/result) and tool_call.id linking chat -> tool
  * retries recorded as events on ONE chat span, not as extra chat spans
"""
import json
import tempfile

import pytest
from opentelemetry import baggage, context, trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from mini_agent.agent import Agent
from mini_agent.llm import LLMClient
from mini_agent.retry import RetryConfig, async_retry
from mini_agent.schema import FunctionCall, LLMResponse, TokenUsage, ToolCall
from mini_agent.telemetry import SCOPE_NAME
from mini_agent.tools.base import Tool, ToolResult

EXPORTER = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(EXPORTER))
trace.set_tracer_provider(_provider)


class FakeClient:
    """Call 1-2: transient failures (retried). Call 3: tool call. Call 4: final answer."""

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
                return LLMResponse(
                    content="先查一下", finish_reason="tool_use",
                    tool_calls=[ToolCall(id="toolu_01", type="function",
                                         function=FunctionCall(name="run_select_query",
                                                               arguments={"query": "SELECT 1"}))],
                    usage=TokenUsage(prompt_tokens=1200, completion_tokens=30, total_tokens=1230))
            return LLMResponse(content="结果是 **1**", finish_reason="end_turn",
                               usage=TokenUsage(prompt_tokens=1300, completion_tokens=12, total_tokens=1312))
        return await _call()


class RunSelect(Tool):
    name = "run_select_query"
    description = "Run a read-only SELECT on ClickHouse"
    parameters = {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}

    async def execute(self, query: str):
        return ToolResult(success=True, content='[{"1": 1}]')


@pytest.fixture
async def spans():
    EXPORTER.clear()
    llm = LLMClient(api_key="x", model="global.anthropic.claude-sonnet-4-6")
    llm._client = FakeClient()
    agent = Agent(llm, "你是 ClickHouse 数据分析助手。", [RunSelect()], workspace_dir=tempfile.mkdtemp())
    agent.add_user_message("SELECT 1 的结果是多少？")
    token = context.attach(baggage.set_baggage("session.id", "sess-123"))
    try:
        await agent.run()
    finally:
        context.detach(token)
    return sorted(EXPORTER.get_finished_spans(), key=lambda s: s.start_time)


def _op(spans, op):
    return [s for s in spans if s.attributes.get("gen_ai.operation.name") == op]


async def test_scope_trace_and_hierarchy(spans):
    assert SCOPE_NAME.startswith("opentelemetry.instrumentation.")
    assert {s.instrumentation_scope.name for s in spans} == {SCOPE_NAME}
    assert len({s.context.trace_id for s in spans}) == 1, "one user turn = one trace"
    [agent] = _op(spans, "invoke_agent")
    assert agent.parent is None
    children = _op(spans, "chat") + _op(spans, "execute_tool")
    assert children and all(s.parent.span_id == agent.context.span_id for s in children)


async def test_session_id_on_every_span(spans):
    assert all(s.attributes.get("session.id") == "sess-123" for s in spans)


async def test_invoke_agent_content(spans):
    [agent] = _op(spans, "invoke_agent")
    assert agent.attributes["gen_ai.task.input"] == "SELECT 1 的结果是多少？"
    assert agent.attributes["gen_ai.task.output"] == "结果是 **1**"


async def test_chat_content_and_retries(spans):
    chats = _op(spans, "chat")
    assert len(chats) == 2, "retries must not create extra chat spans"
    first = chats[0]
    assert [e.name for e in first.events] == ["gen_ai.retry", "gen_ai.retry"]
    out = json.loads(first.attributes["gen_ai.output.messages"])
    assert {"type": "tool_call", "id": "toolu_01", "name": "run_select_query",
            "arguments": {"query": "SELECT 1"}} in out[0]["parts"]
    assert json.loads(first.attributes["gen_ai.tool.definitions"])[0]["name"] == "run_select_query"
    assert json.loads(first.attributes["gen_ai.system_instructions"])[0]["content"].startswith("你是")
    assert first.attributes["gen_ai.usage.input_tokens"] == 1200
    # second call sees the tool result in its input history
    hist = json.loads(chats[1].attributes["gen_ai.input.messages"])
    assert any(p.get("type") == "tool_call_response" and p.get("id") == "toolu_01"
               for m in hist for p in m["parts"])


async def test_execute_tool_content(spans):
    [tool] = _op(spans, "execute_tool")
    assert tool.attributes["gen_ai.tool.name"] == "run_select_query"
    assert tool.attributes["gen_ai.tool.call.id"] == "toolu_01"
    assert json.loads(tool.attributes["gen_ai.tool.call.arguments"]) == {"query": "SELECT 1"}
    assert tool.attributes["gen_ai.tool.call.result"] == '[{"1": 1}]'
