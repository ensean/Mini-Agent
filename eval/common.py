"""Shared settings for the eval scripts (override with env vars)."""
import os

import boto3

REGION = os.getenv("AWS_REGION", "ap-northeast-1")
AGENT_NAME = os.getenv("AGENT_NAME", "text2sql-demo")          # == OTel service.name
LOG_GROUP = os.getenv("AGENT_LOG_GROUP", f"/aws/bedrock-agentcore/runtimes/{AGENT_NAME}")
JUDGE_MODEL = os.getenv("JUDGE_MODEL", "global.anthropic.claude-sonnet-4-6")
CUSTOM_EVALUATOR_NAME = "text2sql_answer_accuracy"             # needs ground truth -> batch only
CUSTOM_ONLINE_EVALUATOR_NAME = "text2sql_grounded_answer"      # no ground truth -> online too


def session() -> boto3.Session:
    return boto3.Session(profile_name=os.getenv("AWS_PROFILE"), region_name=REGION)


def find_evaluator_id(name: str) -> str | None:
    cp = session().client("bedrock-agentcore-control")
    for page in cp.get_paginator("list_evaluators").paginate():
        for e in page["evaluators"]:
            if e["evaluatorName"] == name:
                return e["evaluatorId"]
    return None
