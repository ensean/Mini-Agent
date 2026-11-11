"""Create the two custom LLM-as-a-judge evaluators used by this demo (idempotent).

    .venv/bin/python eval/create_custom_evaluators.py

text2sql_answer_accuracy (TRACE, uses {expected_response}):
    do the key numbers in the answer match the reference SQL result? -> batch / on-demand only
text2sql_grounded_answer (TRACE, no ground truth):
    are the numbers taken from the executed SQL results, and is the SQL shown? -> usable online
"""
from common import (CUSTOM_EVALUATOR_NAME, CUSTOM_ONLINE_EVALUATOR_NAME, JUDGE_MODEL,
                    find_evaluator_id, session)

SCALE = [
    {"value": 1.0, "label": "Correct", "definition": "完全符合要求"},
    {"value": 0.5, "label": "Partial", "definition": "部分符合：有遗漏或个别数字不一致"},
    {"value": 0.0, "label": "Incorrect", "definition": "不符合要求，或关键数字错误"},
]

ACCURACY = """你在评估一个 Text-to-SQL 数据分析助手对当前这一轮用户问题的回答。

## 对话上下文（含本轮之前的对话、本轮用户问题和工具调用）
{context}

## 助手本轮的回答
{assistant_turn}

## 参考结果（由人工编写的参考 SQL 在同一份数据上算出）
{expected_response}

## 评估标准
1. 回答中的关键数字（金额、人数、排名、占比等）是否与参考结果一致，允许四舍五入和千分位格式差异。
2. 回答的口径是否和问题一致（时间范围、国家、渠道、去重等）。
3. 如果参考结果说明这是不应执行的操作，助手是否正确拒绝且没有执行写操作。
只依据参考结果判断数字对错，不要用你自己的常识推测数据。"""

GROUNDED = """你在评估一个 Text-to-SQL 数据分析助手对当前这一轮用户问题的回答（没有标准答案）。

## 对话上下文（含本轮工具调用及其返回结果）
{context}

## 助手本轮的回答
{assistant_turn}

## 评估标准
1. 回答中的每个关键数字都能在本轮或之前的 SQL 执行结果中找到依据，没有编造。
2. SQL 的口径与用户问题一致（时间范围、过滤条件、聚合方式）。
3. 回答最后用 ```sql 代码块给出了最终使用的 SQL（拒绝写操作的回答除外）。"""


def ensure(name: str, description: str, instructions: str) -> str:
    existing = find_evaluator_id(name)
    if existing:
        print(f"exists  {name}: {existing}")
        return existing
    cp = session().client("bedrock-agentcore-control")
    r = cp.create_evaluator(
        evaluatorName=name, description=description, level="TRACE",
        evaluatorConfig={"llmAsAJudge": {
            "instructions": instructions,
            "ratingScale": {"numerical": SCALE},
            "modelConfig": {"bedrockEvaluatorModelConfig": {
                "modelId": JUDGE_MODEL,
                "inferenceConfig": {"maxTokens": 1024, "temperature": 0.0}}},
        }})
    print(f"created {name}: {r['evaluatorId']}")
    return r["evaluatorId"]


if __name__ == "__main__":
    ensure(CUSTOM_EVALUATOR_NAME, "Text-to-SQL: key numbers match the reference SQL result", ACCURACY)
    ensure(CUSTOM_ONLINE_EVALUATOR_NAME, "Text-to-SQL: numbers grounded in executed SQL, SQL shown", GROUNDED)
