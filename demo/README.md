# Text-to-SQL demo on Mini-Agent, wired to AgentCore Observability & Evaluations

Mini-Agent + Bedrock Claude + [mcp-clickhouse](https://github.com/ClickHouse/mcp-clickhouse) answering
Chinese business questions over a synthetic live-streaming gift dataset, self-hosted on EC2.
`mini_agent/telemetry.py` emits OpenTelemetry GenAI spans (`invoke_agent` / `chat` / `execute_tool`,
scope `opentelemetry.instrumentation.mini_agent`) that AgentCore Evaluations reads through its
generic-framework path; ADOT (`opentelemetry-instrument`) exports them to CloudWatch.

```
demo/       app.py (FastAPI + UI), mcp_clickhouse.json, seed.sql, clickhouse.sh, run.sh, otel.env.example
eval/       dataset.json -> ground_truth.json, replay.py, batch_eval.py, online_eval.py,
            create_custom_evaluators.py, show_results.py
deploy/     setup_observability.sh (once per account/region), deploy_ec2.sh, bootstrap.sh, userdata.sh
tests/test_telemetry.py   offline contract test of the span schema
```

## Quick start (local, against a real AWS account)

```bash
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -e ".[demo,dev]"
.venv/bin/pytest -q tests/test_telemetry.py                    # span contract, offline
bash demo/clickhouse.sh                                        # ClickHouse in Docker + seed data
PROFILE=<profile> REGION=ap-northeast-1 bash deploy/setup_observability.sh
cp demo/otel.env.example demo/otel.env && echo AWS_PROFILE=<profile> >> demo/otel.env
bash demo/run.sh                                               # http://127.0.0.1:8080
```

## Evaluate

```bash
export AWS_PROFILE=<profile> AWS_REGION=ap-northeast-1
.venv/bin/python eval/create_custom_evaluators.py              # 2 LLM-as-a-judge evaluators
.venv/bin/python eval/replay.py [--base-url https://<cloudfront-domain>]
# wait 2-3 min for CloudWatch ingestion
.venv/bin/python eval/batch_eval.py eval/out/<run_id>.json     # scores vs ground truth
.venv/bin/python eval/show_results.py eval/out/<run_id>.batch.json
.venv/bin/python eval/online_eval.py                           # continuous scoring of live traffic
```

## Deploy to EC2

```bash
PROFILE=<profile> REGION=ap-northeast-1 bash deploy/deploy_ec2.sh   # ALLOW_CIDRS=1.2.3.4/32 to override
```

The step-by-step guide (Chinese, with screenshots and troubleshooting) is in the Feishu doc linked
from the PR / branch description.
