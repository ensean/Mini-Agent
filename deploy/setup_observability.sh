#!/usr/bin/env bash
# One-time AgentCore Observability setup for an agent hosted OUTSIDE AgentCore Runtime.
#   PROFILE=warhorse REGION=ap-northeast-1 bash deploy/setup_observability.sh
# Idempotent. Does three things:
#   1. CloudWatch Transaction Search (spans ingested as structured logs) - once per account/region
#   2. The agent's log group + streams that demo/otel.env points ADOT at
#   3. A CloudWatch Logs resource policy letting X-Ray write the agent's spans into that log group
set -euo pipefail
PROFILE="${PROFILE:-default}"
REGION="${REGION:-ap-northeast-1}"
AGENT_NAME="${AGENT_NAME:-text2sql-demo}"
INDEX_PCT="${INDEX_PCT:-100}"   # % of spans indexed as trace summaries (1% is free; demo uses 100)
LOG_GROUP="/aws/bedrock-agentcore/runtimes/$AGENT_NAME"
aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "account=$ACCOUNT region=$REGION log_group=$LOG_GROUP"

echo "== 1/3 Transaction Search"
cat >/tmp/txsearch-policy.json <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"TransactionSearchXRayAccess","Effect":"Allow",
 "Principal":{"Service":"xray.amazonaws.com"},"Action":"logs:PutLogEvents",
 "Resource":["arn:aws:logs:$REGION:$ACCOUNT:log-group:aws/spans:*",
             "arn:aws:logs:$REGION:$ACCOUNT:log-group:/aws/application-signals/data:*"],
 "Condition":{"ArnLike":{"aws:SourceArn":"arn:aws:xray:$REGION:$ACCOUNT:*"},
              "StringEquals":{"aws:SourceAccount":"$ACCOUNT"}}}]}
JSON
aws logs put-resource-policy --policy-name TransactionSearchXRayAccess \
  --policy-document file:///tmp/txsearch-policy.json >/dev/null
if [[ "$(aws xray get-trace-segment-destination --query Destination --output text)" != "CloudWatchLogs" ]]; then
  aws xray update-trace-segment-destination --destination CloudWatchLogs >/dev/null
fi
aws xray update-indexing-rule --name Default \
  --rule "{\"Probabilistic\":{\"DesiredSamplingPercentage\":$INDEX_PCT}}" >/dev/null
aws xray get-trace-segment-destination --output text

echo "== 2/3 agent log group + streams"
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30
for s in runtime-logs spans; do
  aws logs create-log-stream --log-group-name "$LOG_GROUP" --log-stream-name "$s" 2>/dev/null || true
done

echo "== 3/3 X-Ray -> agent log group resource policy (unified span destination)"
cat >/tmp/agent-spans-policy.json <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"XRayToAgentLogGroup","Effect":"Allow",
 "Principal":{"Service":"xray.amazonaws.com"},"Action":"logs:PutLogEvents",
 "Resource":"arn:aws:logs:$REGION:$ACCOUNT:log-group:$LOG_GROUP:*",
 "Condition":{"ArnLike":{"aws:SourceArn":"arn:aws:xray:$REGION:$ACCOUNT:*"},
              "StringEquals":{"aws:SourceAccount":"$ACCOUNT"}}}]}
JSON
aws logs put-resource-policy --policy-name "XRayTo-$AGENT_NAME" \
  --policy-document file:///tmp/agent-spans-policy.json >/dev/null
echo "done. Transaction Search can take ~10 min to become ACTIVE the first time."
