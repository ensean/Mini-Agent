# 基于 Mini-Agent 的 Text-to-SQL Demo，接入 AgentCore Observability 与 Evaluations

Mini-Agent + Bedrock Claude + [mcp-clickhouse](https://github.com/ClickHouse/mcp-clickhouse)，用中文业务问题查询一份合成的直播送礼数据，自托管在 EC2 上。

`mini_agent/telemetry.py` 按 OpenTelemetry GenAI 语义规范产生三类 span（`invoke_agent` / `chat` / `execute_tool`，scope 为 `opentelemetry.instrumentation.mini_agent`），AgentCore Evaluations 通过通用框架（generic framework）路径读取；进程用 ADOT（`opentelemetry-instrument`）启动，把数据导出到 CloudWatch。

```
demo/       app.py（FastAPI + 页面）、mcp_clickhouse.json、seed.sql、clickhouse.sh、run.sh、otel.env.example
eval/       dataset.json -> ground_truth.json、replay.py、batch_eval.py、online_eval.py、
            create_custom_evaluators.py、show_results.py
deploy/     setup_observability.sh（每个账号/区域执行一次）、deploy_ec2.sh、bootstrap.sh、userdata.sh
tests/test_telemetry.py   离线检查 span 结构是否符合评测要求
```

## 本地快速上手（连真实 AWS 账号）

```bash
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -e ".[demo,dev]"
.venv/bin/pytest -q tests/test_telemetry.py                    # 离线检查 span 结构，预期 5 passed
bash demo/clickhouse.sh                                        # Docker 启动 ClickHouse 并灌入示例数据
PROFILE=<profile> REGION=ap-northeast-1 bash deploy/setup_observability.sh
cp demo/otel.env.example demo/otel.env && echo AWS_PROFILE=<profile> >> demo/otel.env
bash demo/run.sh                                               # http://127.0.0.1:8080
```

首次开启 Transaction Search 可能要等 10–15 分钟才变成 ACTIVE，期间导出 span 会报 400，属于正常现象。

## 评测

```bash
export AWS_PROFILE=<profile> AWS_REGION=ap-northeast-1
.venv/bin/python eval/create_custom_evaluators.py              # 创建 2 个自定义 LLM judge
.venv/bin/python eval/replay.py [--base-url https://<cloudfront 域名> --auth agentcore-demo:<密码>]
.venv/bin/python eval/batch_eval.py eval/out/<run_id>.json     # 等 span 摄取完成后，按标准答案批量打分
.venv/bin/python eval/show_results.py eval/out/<run_id>.batch.json
.venv/bin/python eval/online_eval.py                           # 对线上流量持续自动打分
```

## 部署到 EC2

```bash
PROFILE=<profile> REGION=ap-northeast-1 bash deploy/deploy_ec2.sh
# 取登录密码（用户名 agentcore-demo，首次部署时随机生成）：
aws ssm get-parameter --name /text2sql-demo/basic-auth --with-decryption \
  --query Parameter.Value --output text --profile <profile> --region ap-northeast-1
```

访问控制：WAF 按 IP 限速（每 5 分钟 100 个请求）→ CloudFront Function 做 Basic Auth（凭证存在 KeyValueStore）→ 源站只接受 CloudFront 前缀列表的流量，且必须带 `X-Origin-Verify` 头。可以用 `BASIC_PASS`、`RATE_LIMIT` 环境变量覆盖默认值。

## 文档

- 分步实操指引（含实测输出、截图和踩坑记录）：https://qi1g2b1825p.feishu.cn/docx/STTRdgXpVotpXPxJRt4cwUh3nnd
- 自研 Agent 埋点接入 AgentCore 的通用原理：https://qi1g2b1825p.feishu.cn/docx/Q7BJdraIpov4Jkxk2G9c26S6nPf
