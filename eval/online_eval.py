"""Create (or show) the online evaluation config that continuously scores live demo traffic.

    .venv/bin/python eval/online_eval.py            # create role + config (idempotent)
    .venv/bin/python eval/online_eval.py --disable  # stop sampling

Online evaluation reads finished sessions from the agent log group (filtered by OTel
service.name), so it works the same for agents outside AgentCore Runtime. Only evaluators
that need no ground truth can be used here.
"""
import argparse
import json
import time

from common import (AGENT_NAME, CUSTOM_ONLINE_EVALUATOR_NAME, LOG_GROUP, REGION,
                    find_evaluator_id, session)

CONFIG_NAME = f"{AGENT_NAME.replace('-', '_')}_online"
ROLE_NAME = f"AgentCoreEvaluationRole-{AGENT_NAME}"
SAMPLING_PCT = 100.0          # demo: score every session; use 1-10% in production
SESSION_TIMEOUT_MIN = 5       # idle time after the last span before a session counts as done
ONLINE_EVALUATORS = ["Builtin.Helpfulness", "Builtin.ResponseRelevance",
                     "Builtin.InstructionFollowing", "Builtin.GoalSuccessRate",
                     "Builtin.ToolSelectionAccuracy"]


def ensure_role(account: str) -> str:
    iam = session().client("iam")
    trust = {"Version": "2012-10-17", "Statement": [{
        "Effect": "Allow", "Principal": {"Service": "bedrock-agentcore.amazonaws.com"},
        "Action": "sts:AssumeRole",
        "Condition": {"StringEquals": {"aws:SourceAccount": account, "aws:ResourceAccount": account},
                      "ArnLike": {"aws:SourceArn": [
                          f"arn:aws:bedrock-agentcore:{REGION}:{account}:evaluator/*",
                          f"arn:aws:bedrock-agentcore:{REGION}:{account}:online-evaluation-config/*"]}}}]}
    policy = {"Version": "2012-10-17", "Statement": [
        {"Sid": "ReadTraces", "Effect": "Allow",
         "Action": ["logs:DescribeLogGroups", "logs:GetQueryResults", "logs:StartQuery"], "Resource": "*"},
        {"Sid": "WriteResults", "Effect": "Allow",
         "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
         "Resource": f"arn:aws:logs:{REGION}:{account}:log-group:/aws/bedrock-agentcore/evaluations/*"},
        {"Sid": "IndexPolicy", "Effect": "Allow",
         "Action": ["logs:DescribeIndexPolicies", "logs:PutIndexPolicy"],
         "Resource": [f"arn:aws:logs:{REGION}:{account}:log-group:aws/spans",
                      f"arn:aws:logs:{REGION}:{account}:log-group:aws/spans:*",
                      f"arn:aws:logs:{REGION}:{account}:log-group:{LOG_GROUP}",
                      f"arn:aws:logs:{REGION}:{account}:log-group:{LOG_GROUP}:*"]},
        {"Sid": "JudgeModel", "Effect": "Allow",   # custom evaluator; global profiles route cross-region
         "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
         "Resource": ["arn:aws:bedrock:*::foundation-model/*",
                      f"arn:aws:bedrock:*:{account}:inference-profile/*"]}]}
    try:
        arn = iam.get_role(RoleName=ROLE_NAME)["Role"]["Arn"]
    except iam.exceptions.NoSuchEntityException:
        arn = iam.create_role(RoleName=ROLE_NAME, AssumeRolePolicyDocument=json.dumps(trust),
                              Description="AgentCore online evaluation for " + AGENT_NAME)["Role"]["Arn"]
        time.sleep(10)  # IAM propagation
    iam.put_role_policy(RoleName=ROLE_NAME, PolicyName="evaluation", PolicyDocument=json.dumps(policy))
    return arn


def find_config(cp):
    for c in cp.list_online_evaluation_configs().get("onlineEvaluationConfigs", []):
        if c["onlineEvaluationConfigName"] == CONFIG_NAME:
            return c
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--disable", action="store_true")
    args = ap.parse_args()
    cp = session().client("bedrock-agentcore-control")
    existing = find_config(cp)
    if args.disable:
        if existing:
            cp.update_online_evaluation_config(
                onlineEvaluationConfigId=existing["onlineEvaluationConfigId"], executionStatus="DISABLED")
            print("disabled", existing["onlineEvaluationConfigId"])
        return
    if existing:
        print(json.dumps(cp.get_online_evaluation_config(
            onlineEvaluationConfigId=existing["onlineEvaluationConfigId"]), indent=2, default=str))
        return

    account = session().client("sts").get_caller_identity()["Account"]
    role_arn = ensure_role(account)
    evaluators = ONLINE_EVALUATORS + [e for e in [find_evaluator_id(CUSTOM_ONLINE_EVALUATOR_NAME)] if e]
    r = cp.create_online_evaluation_config(
        onlineEvaluationConfigName=CONFIG_NAME,
        description=f"Online evaluation for {AGENT_NAME} (self-hosted on EC2)",
        rule={"samplingConfig": {"samplingPercentage": SAMPLING_PCT},
              "sessionConfig": {"sessionTimeoutMinutes": SESSION_TIMEOUT_MIN}},
        dataSourceConfig={"cloudWatchLogs": {"logGroupNames": [LOG_GROUP], "serviceNames": [AGENT_NAME]}},
        evaluators=[{"evaluatorId": e} for e in evaluators],
        evaluationExecutionRoleArn=role_arn,
        enableOnCreate=True,
    )
    cid = r["onlineEvaluationConfigId"]
    print(f"created {CONFIG_NAME}: {cid} ({r.get('status')})")
    print(f"results -> /aws/bedrock-agentcore/evaluations/results/{cid}, "
          "metrics -> namespace Bedrock-AgentCore/Evaluations")


if __name__ == "__main__":
    main()
