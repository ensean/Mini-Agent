"""Text-to-SQL demo on Mini-Agent: Bedrock Claude + mcp-clickhouse, with OTel GenAI spans.

Run:  uvicorn demo.app:app --host 127.0.0.1 --port 8080
Env:
    BEDROCK_REGION   (default us-west-2)
    BEDROCK_MODEL    (default global.anthropic.claude-sonnet-4-6)
    MCP_CONFIG       (default demo/mcp.json)
"""

from __future__ import annotations

import asyncio
import os
import tempfile
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from opentelemetry import baggage, context
from pydantic import BaseModel, Field

from mini_agent.agent import Agent
from mini_agent.llm import LLMClient
from mini_agent.retry import RetryConfig
from mini_agent.schema import LLMProvider
from mini_agent.tools.mcp_loader import cleanup_mcp_connections, load_mcp_tools_async

HERE = Path(__file__).parent
REGION = os.getenv("BEDROCK_REGION", "us-west-2")
MODEL = os.getenv("BEDROCK_MODEL", "global.anthropic.claude-sonnet-4-6")
MAX_SESSIONS = 200
SQL_TOOLS = {"run_select_query", "run_query", "run_chdb_select_query"}

SYSTEM_PROMPT = """你是一个 ClickHouse 数据分析助手，把用户的中文业务问题转成 ClickHouse SQL 并给出结论。

工作方式：
1. 不确定表结构时，先用 list_databases / list_tables 查看库、表、字段和字段注释，不要臆造表名或字段名。
2. 只写只读的 SELECT 查询，使用 ClickHouse 方言（如 toStartOfDay、toYYYYMM、uniqExact、topK）。
3. 明细查询务必加 LIMIT（默认 100）；聚合优先在 SQL 里完成，不要把大量明细拉回来自己算，禁止对全表用 groupArray。
4. 列别名只用英文（如 AS revenue_usd），中文别名会报语法错误。
5. 时间字段是北京时间。涉及"最近/昨天/上周"等相对时间时，先查 max(event_time) 确认数据范围，以数据最大日期为基准。
6. 查询报错时读错误信息修正 SQL 再试，最多 3 次。

回答格式（Markdown）：
- 先一句话给结论，关键数字加粗
- 必要时附一个小表格
- 最后用 ```sql 代码块列出最终使用的 SQL
"""


class AskRequest(BaseModel):
    question: str = Field(min_length=1, max_length=2000)
    session_id: str | None = None


class AskResponse(BaseModel):
    session_id: str
    answer: str
    sql: list[str]
    tool_calls: int
    elapsed_s: float


class _Session:
    def __init__(self, agent: Agent):
        self.agent = agent
        self.lock = asyncio.Lock()
        self.last_used = time.time()


_state: dict = {"tools": [], "llm": None, "sessions": {}}


@asynccontextmanager
async def lifespan(_: FastAPI):
    _state["tools"] = await load_mcp_tools_async(os.getenv("MCP_CONFIG", str(HERE / "mcp.json")))
    if not _state["tools"]:
        raise RuntimeError("no MCP tools loaded; is mcp-clickhouse reachable?")
    _state["llm"] = LLMClient(
        api_key="",
        provider=LLMProvider.BEDROCK,
        api_base=REGION,
        model=MODEL,
        retry_config=RetryConfig(max_retries=2, initial_delay=1.0),
    )
    yield
    await cleanup_mcp_connections()


app = FastAPI(title="Mini-Agent Text-to-SQL demo", lifespan=lifespan)


def _get_session(session_id: str | None) -> tuple[str, _Session]:
    sessions: dict[str, _Session] = _state["sessions"]
    if session_id and session_id in sessions:
        s = sessions[session_id]
    else:
        if len(sessions) >= MAX_SESSIONS:  # evict least recently used
            oldest = min(sessions, key=lambda k: sessions[k].last_used)
            sessions.pop(oldest)
        session_id = session_id or uuid.uuid4().hex
        agent = Agent(
            llm_client=_state["llm"],
            system_prompt=SYSTEM_PROMPT,
            tools=_state["tools"],
            max_steps=15,
            workspace_dir=tempfile.mkdtemp(prefix="t2s-"),
        )
        s = sessions[session_id] = _Session(agent)
    s.last_used = time.time()
    return session_id, s


@app.post("/api/ask", response_model=AskResponse)
async def ask(req: AskRequest) -> AskResponse:
    session_id, s = _get_session(req.session_id)
    async with s.lock:
        start_idx = len(s.agent.messages)
        s.agent.add_user_message(req.question)
        token = context.attach(baggage.set_baggage("session.id", session_id))
        t0 = time.perf_counter()
        try:
            answer = await s.agent.run()
        except Exception as e:  # noqa: BLE001
            raise HTTPException(status_code=502, detail=f"agent failed: {e}") from e
        finally:
            context.detach(token)
        elapsed = time.perf_counter() - t0
        if answer.startswith("LLM call failed"):  # Agent.run reports LLM errors as text
            raise HTTPException(status_code=502, detail=answer)

        sql, n_calls = [], 0
        for m in s.agent.messages[start_idx:]:
            for tc in m.tool_calls or []:
                n_calls += 1
                if tc.function.name in SQL_TOOLS and "query" in tc.function.arguments:
                    sql.append(tc.function.arguments["query"])
    return AskResponse(session_id=session_id, answer=answer, sql=sql,
                       tool_calls=n_calls, elapsed_s=round(elapsed, 2))


@app.get("/healthz")
async def healthz():
    return {"ok": True, "model": MODEL, "tools": [t.name for t in _state["tools"]]}


@app.get("/")
async def index():
    return FileResponse(HERE / "index.html")
