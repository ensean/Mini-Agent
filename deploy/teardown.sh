#!/usr/bin/env bash
# Delete everything deploy_ec2.sh / setup_observability.sh / online_eval.py created for one agent.
#   CONFIRM=yes PROFILE=<profile> REGION=ap-northeast-1 AGENT_NAME=text2sql-demo bash deploy/teardown.sh
# Keeps account-level settings (Transaction Search) and the two custom evaluators, which are
# shared by name (DELETE_EVALUATORS=yes to delete them too). Takes ~15 min (CloudFront disable).
set -uo pipefail
PROFILE="${PROFILE:-default}"
REGION="${REGION:-ap-northeast-1}"
NAME="${AGENT_NAME:-text2sql-demo}"
[[ "${CONFIRM:-}" == "yes" ]] || { echo "set CONFIRM=yes to delete all '$NAME' resources in $REGION"; exit 1; }
aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
cf() { command aws --profile "$PROFILE" cloudfront "$@"; }
waf() { command aws --profile "$PROFILE" --region us-east-1 wafv2 "$@"; }
step() { echo "== $*"; }

step "online evaluation config + execution role"
CFG=$(aws bedrock-agentcore-control list-online-evaluation-configs \
       --query "onlineEvaluationConfigs[?onlineEvaluationConfigName=='${NAME//-/_}_online'].onlineEvaluationConfigId | [0]" --output text)
[[ "$CFG" != "None" && -n "$CFG" ]] && aws bedrock-agentcore-control delete-online-evaluation-config --online-evaluation-config-id "$CFG" >/dev/null && echo "deleted $CFG"
ER="AgentCoreEvaluationRole-$NAME"
for p in $(aws iam list-role-policies --role-name "$ER" --query PolicyNames --output text 2>/dev/null); do aws iam delete-role-policy --role-name "$ER" --policy-name "$p"; done
aws iam delete-role --role-name "$ER" 2>/dev/null && echo "deleted role $ER"

step "CloudFront distribution (disable -> wait -> delete)"
DIST=$(cf list-distributions --query "DistributionList.Items[?Comment=='$NAME'].Id | [0]" --output text)
if [[ "$DIST" != "None" && -n "$DIST" ]]; then
  TMP=$(mktemp -d)
  cf get-distribution-config --id "$DIST" >"$TMP/cur.json"
  if [[ "$(python3 -c "import json;print(json.load(open('$TMP/cur.json'))['DistributionConfig']['Enabled'])")" == "True" ]]; then
    python3 -c "import json;d=json.load(open('$TMP/cur.json'))['DistributionConfig'];d['Enabled']=False;json.dump(d,open('$TMP/new.json','w'))"
    cf update-distribution --id "$DIST" --if-match "$(python3 -c "import json;print(json.load(open('$TMP/cur.json'))['ETag'])")" \
      --distribution-config "file://$TMP/new.json" >/dev/null
  fi
  cf wait distribution-deployed --id "$DIST"
  cf delete-distribution --id "$DIST" --if-match "$(cf get-distribution --id "$DIST" --query ETag --output text)" && echo "deleted $DIST"
fi

step "CloudFront function + KeyValueStore"
FN="$NAME-basic-auth"
ET=$(cf describe-function --name "$FN" --query ETag --output text 2>/dev/null) && cf delete-function --name "$FN" --if-match "$ET" && echo "deleted $FN"
KVS="$NAME-auth"
ET=$(cf describe-key-value-store --name "$KVS" --query ETag --output text 2>/dev/null) && cf delete-key-value-store --name "$KVS" --if-match "$ET" && echo "deleted $KVS"

step "WAF web ACL (us-east-1)"
ACL_ID=$(waf list-web-acls --scope CLOUDFRONT --query "WebACLs[?Name=='$NAME-acl'].Id | [0]" --output text)
if [[ "$ACL_ID" != "None" && -n "$ACL_ID" ]]; then
  LOCK=$(waf get-web-acl --scope CLOUDFRONT --name "$NAME-acl" --id "$ACL_ID" --query LockToken --output text)
  waf delete-web-acl --scope CLOUDFRONT --name "$NAME-acl" --id "$ACL_ID" --lock-token "$LOCK" && echo "deleted $NAME-acl"
fi

step "EC2 instance + security group"
IID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
       --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [[ "$IID" != "None" ]]; then aws ec2 terminate-instances --instance-ids "$IID" >/dev/null; aws ec2 wait instance-terminated --instance-ids "$IID"; echo "terminated $IID"; fi
SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME-origin" --query 'SecurityGroups[0].GroupId' --output text)
[[ "$SG" != "None" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null && echo "deleted $SG"

step "instance role + profile"
R="$NAME-ec2"
aws iam remove-role-from-instance-profile --instance-profile-name "$R" --role-name "$R" 2>/dev/null
aws iam delete-instance-profile --instance-profile-name "$R" 2>/dev/null && echo "deleted instance profile $R"
for a in $(aws iam list-attached-role-policies --role-name "$R" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do aws iam detach-role-policy --role-name "$R" --policy-arn "$a"; done
for p in $(aws iam list-role-policies --role-name "$R" --query PolicyNames --output text 2>/dev/null); do aws iam delete-role-policy --role-name "$R" --policy-name "$p"; done
aws iam delete-role --role-name "$R" 2>/dev/null && echo "deleted role $R"

step "SSM parameters, log group, X-Ray resource policy"
for p in basic-auth origin-verify; do aws ssm delete-parameter --name "/$NAME/$p" 2>/dev/null && echo "deleted /$NAME/$p"; done
aws logs delete-log-group --log-group-name "/aws/bedrock-agentcore/runtimes/$NAME" 2>/dev/null && echo "deleted log group"
aws logs delete-resource-policy --policy-name "XRayTo-$NAME" 2>/dev/null && echo "deleted XRayTo-$NAME"

if [[ "${DELETE_EVALUATORS:-}" == "yes" ]]; then
  step "custom evaluators"
  for n in text2sql_answer_accuracy text2sql_grounded_answer; do
    id=$(aws bedrock-agentcore-control list-evaluators --query "evaluators[?evaluatorName=='$n'].evaluatorId | [0]" --output text)
    [[ "$id" != "None" ]] && aws bedrock-agentcore-control delete-evaluator --evaluator-id "$id" >/dev/null && echo "deleted $id"
  done
fi
echo "done."
