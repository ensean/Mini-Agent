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

## 接入权限（最小权限）

策略模板在 [`deploy/iam/`](../deploy/iam/)，其中的 `${REGION}`、`${ACCOUNT_ID}`、`${AGENT_NAME}` 用 `render.sh` 填充：

```bash
REGION=ap-northeast-1 ACCOUNT_ID=123456789012 AGENT_NAME=text2sql-demo \
  bash deploy/iam/render.sh observability-evaluation-policy.json > /tmp/policy.json
```

一共涉及两类身份：**执行脚本的身份**（你本地 AWS profile 对应的用户或角色）和 **Agent 运行身份**（Agent 进程使用的凭证，本 demo 中是 EC2 实例角色）。

| 场景 | 执行脚本的身份 | Agent 运行身份 |
|---|---|---|
| A. 仅接入 AgentCore Observability + Evaluations（Agent 已部署在自己的环境） | `observability-evaluation-policy.json` | `agent-runtime-policy.json` |
| B. 部署本 demo + 接入 | `observability-evaluation-policy.json` + `demo-deploy-policy.json` | 由 `deploy_ec2.sh` 自动创建（`${AGENT_NAME}-ec2` 角色），无需手动配置 |

以上策略已在 2026-11 用一个只挂这些策略的测试角色实测：完整跑通了从零部署 → 再次部署（更新路径）→ 回放 → 批量评测（含自定义 judge）→ 创建和停用在线评测。

### 场景 A：仅接入 Observability + Evaluations

**执行脚本的身份**（`observability-evaluation-policy.json`），覆盖 `setup_observability.sh` 和 `eval/*.py`：

| 用途 | 主要权限 | 资源范围 |
|---|---|---|
| 开启 Transaction Search（账号级，只需一次） | `xray:Get/UpdateTraceSegmentDestination`、`xray:Get/UpdateIndexingRule(s)`、`logs:PutResourcePolicy` | `*`（账号级 API） |
| Agent 日志组：创建、设置保留期，以及 batch_eval 等待 span 时的查询 | `logs:CreateLogGroup/PutRetentionPolicy/CreateLogStream/StartQuery`、`logs:Describe/PutIndexPolicy` | `/aws/bedrock-agentcore/runtimes/${AGENT_NAME}` |
| 评测结果日志组 | `logs:CreateLogGroup/PutRetentionPolicy/CreateLogStream/PutLogEvents/FilterLogEvents` | `/aws/bedrock-agentcore/evaluations/*` |
| 自定义 evaluator、批量评测、在线评测 | `bedrock-agentcore:*Evaluator*`、`*BatchEvaluation*`、`*OnlineEvaluationConfig*` | `*` |
| 自定义 LLM judge 调用模型 | `bedrock:InvokeModel` | Claude 推理配置 / 基础模型 |
| 在线评测的执行角色 | `iam:Get/CreateRole`、`UpdateAssumeRolePolicy`、`PutRolePolicy`，以及带 `iam:PassedToService=bedrock-agentcore` 条件的 `iam:PassRole` | 仅 `AgentCoreEvaluationRole-${AGENT_NAME}` |

**Agent 运行身份**（`agent-runtime-policy.json`）：

| 用途 | 权限 |
|---|---|
| Agent 调用模型 | `bedrock:InvokeModel`（Claude） |
| ADOT 导出 trace（OTLP → X-Ray 端点） | `xray:PutTraceSegments`、`PutTelemetryRecords`、`GetSampling*`（与托管策略 `AWSXrayWriteOnlyAccess` 相同） |
| ADOT 导出日志和 EMF 指标（OTLP → Logs 端点） | `logs:PutLogEvents/CreateLogStream/DescribeLogStreams/DescribeLogGroups`，仅限 Agent 日志组 |

托管在 AgentCore Runtime 上的 Agent 不需要这份策略，用 Runtime 自己的执行角色即可。

### 场景 B：部署本 demo + 接入

在场景 A 的基础上，执行脚本的身份再加上 `demo-deploy-policy.json`（覆盖 `deploy_ec2.sh`）：

| 用途 | 主要权限 | 资源范围 / 条件 |
|---|---|---|
| 实例角色和实例配置文件 | `iam:Get/CreateRole`、`TagRole`、`PutRolePolicy`、`AttachRolePolicy`、`*InstanceProfile`、`iam:PassRole` | 仅 `${AGENT_NAME}-ec2`；`AttachRolePolicy` 只允许挂 SSM Core 和 X-Ray 写入两个托管策略；`PassRole` 只能传给 ec2 |
| 安全组和 EC2 实例 | `ec2:Describe*`（5 个）、`CreateSecurityGroup`、`AuthorizeSecurityGroupIngress`、`RunInstances`、`CreateTags` | 写操作限定在 `${REGION}` |
| AMI 查询、密钥存储 | `ssm:GetParameter`（AMI 公共参数）、`ssm:Get/PutParameter`、`AddTagsToResource` | `/aws/service/ami-amazon-linux-latest/*`、`/${AGENT_NAME}/*` |
| CloudFront 分发、函数、KeyValueStore | `cloudfront:*Distribution*`、`*Function`、`*KeyValueStore`、`cloudfront-keyvaluestore:DescribeKeyValueStore/PutKey` | `*` |
| WAF | `wafv2:List/Get/Create/UpdateWebACL`、`TagResource` | `*`（Web ACL 建在 us-east-1） |
| 在实例上执行命令（更新代码、看日志） | `ssm:SendCommand/GetCommandInvocation/StartSession` | `*` |

`teardown.sh` 需要对应的 Delete 权限，不在上面的最小集合里，建议用管理员身份执行。

### 文档没写清楚、实测才发现的几点

- **StartBatchEvaluation 用的是调用者自己的凭证**（FAS）去建结果日志组、查询 span、调用自定义 judge 模型，所以执行脚本的身份需要评测结果日志组的写权限和 judge 模型的 `bedrock:InvokeModel`，否则会报 `FAS credentials do not have permission to ...`。内置 evaluator 由服务端调用模型，不需要这个权限。
- **在线评测的执行角色刚创建时**，可能因为 IAM 还没传播完，创建配置会报 "execution role does not have permissions to access the specified log groups"。`online_eval.py` 已经内置了重试。
- 如果 span 写到共享的 `aws/spans` 日志组（没有设置 `OTEL_EXPORTER_OTLP_TRACES_HEADERS`），需要把 `aws/spans` 也加进 `AgentLogGroup` 这条语句的资源范围，并在评测数据源里同时配置两个日志组。

## 清理

```bash
CONFIRM=yes PROFILE=<profile> REGION=ap-northeast-1 bash deploy/teardown.sh   # 约 15 分钟，CloudFront 需要先停用
```

会删除分发、函数、KVS、WAF、EC2、安全组、IAM 角色、SSM 参数、日志组和在线评测配置。不会关闭账号级的 Transaction Search；自定义 evaluator 默认保留，加 `DELETE_EVALUATORS=yes` 才会一起删。

## 文档

- 分步实操指引（含实测输出、截图和踩坑记录）：https://qi1g2b1825p.feishu.cn/docx/STTRdgXpVotpXPxJRt4cwUh3nnd
- 自研 Agent 埋点接入 AgentCore 的通用原理：https://qi1g2b1825p.feishu.cn/docx/Q7BJdraIpov4Jkxk2G9c26S6nPf
