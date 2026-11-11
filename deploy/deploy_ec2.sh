#!/usr/bin/env bash
# Deploy the demo to one EC2 instance behind CloudFront, with plain AWS CLI. Re-runnable.
#   PROFILE=warhorse REGION=ap-northeast-1 bash deploy/deploy_ec2.sh
# Run deploy/setup_observability.sh first (same PROFILE/REGION).
#
# Access control, outside in:
#   1. AWS WAF web ACL (us-east-1, scope CLOUDFRONT): per-IP rate limit, RATE_LIMIT requests
#      per 5 minutes, then 403 - blunts password brute force (WAF runs before the function).
#   2. CloudFront Function (viewer-request): HTTP Basic auth. The expected credential lives in
#      a CloudFront KeyValueStore, so rotating the password needs no function redeploy.
#   3. Origin: SG admits port 8080 only from the CloudFront origin-facing prefix list (no
#      0.0.0.0/0), and the app rejects requests without the X-Origin-Verify secret that only
#      this distribution adds - the prefix list is shared by every CloudFront distribution.
# Secrets are kept in SSM Parameter Store (SecureString): /$NAME/basic-auth, /$NAME/origin-verify.
set -euo pipefail
PROFILE="${PROFILE:-default}"
REGION="${REGION:-ap-northeast-1}"
NAME="${AGENT_NAME:-text2sql-demo}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"
MODEL="${BEDROCK_MODEL:-global.anthropic.claude-sonnet-4-6}"
REPO="${REPO:-https://github.com/ensean/Mini-Agent.git}"
BRANCH="${BRANCH:-agentcore-text2sql}"
BASIC_USER="${BASIC_USER:-agentcore-demo}"
RATE_LIMIT="${RATE_LIMIT:-100}"          # requests per IP per 5 minutes
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
cf() { command aws --profile "$PROFILE" cloudfront "$@"; }
waf() { command aws --profile "$PROFILE" --region us-east-1 wafv2 "$@"; }
kvs() { command aws --profile "$PROFILE" --region us-east-1 cloudfront-keyvaluestore "$@"; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
LOG_GROUP="/aws/bedrock-agentcore/runtimes/$NAME"
TAG="Key=project,Value=$NAME"
randstr() { python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range($1)))"; }

VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)}"
SUBNET_ID="${SUBNET_ID:-$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=map-public-ip-on-launch,Values=true \
             --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)}"
CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)
echo "account=$ACCOUNT region=$REGION vpc=$VPC_ID subnet=$SUBNET_ID cf_pl=$CF_PREFIX_LIST"

echo "== 0/6 secrets in SSM Parameter Store (created once, reused afterwards)"
ensure_secret() {  # name value-if-missing
  if ! aws ssm get-parameter --name "$1" >/dev/null 2>&1; then
    aws ssm put-parameter --name "$1" --type SecureString --value "$2" --tags "$TAG" >/dev/null
    echo "created $1"
  fi
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text
}
BASIC_CRED=$(ensure_secret "/$NAME/basic-auth" "$BASIC_USER:${BASIC_PASS:-$(randstr 20)}" | tail -1)
ORIGIN_SECRET=$(ensure_secret "/$NAME/origin-verify" "$(randstr 40)" | tail -1)

echo "== 1/6 IAM role: Bedrock invoke + telemetry export + origin secret + SSM"
cat >"$TMP/trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
cat >"$TMP/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"InvokeClaude","Effect":"Allow",
  "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
  "Resource":["arn:aws:bedrock:*:${ACCOUNT}:inference-profile/*anthropic.claude*",
              "arn:aws:bedrock:*::foundation-model/anthropic.claude*"]},
 {"Sid":"OtlpLogsAndEmf","Effect":"Allow",
  "Action":["logs:PutLogEvents","logs:CreateLogStream","logs:DescribeLogStreams","logs:DescribeLogGroups"],
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}","arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"]},
 {"Sid":"OriginSecret","Effect":"Allow","Action":"ssm:GetParameter",
  "Resource":"arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/${NAME}/origin-verify"}]}
JSON
if ! aws iam get-role --role-name "$NAME-ec2" >/dev/null 2>&1; then
  aws iam create-role --role-name "$NAME-ec2" --assume-role-policy-document "file://$TMP/trust.json" --tags "$TAG" >/dev/null
  aws iam attach-role-policy --role-name "$NAME-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam attach-role-policy --role-name "$NAME-ec2" --policy-arn arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess
fi
aws iam put-role-policy --role-name "$NAME-ec2" --policy-name "$NAME" --policy-document "file://$TMP/policy.json"
if ! aws iam get-instance-profile --instance-profile-name "$NAME-ec2" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$NAME-ec2" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$NAME-ec2" --role-name "$NAME-ec2"
  sleep 10   # instance profile propagation
fi

echo "== 2/6 security group (8080 from CloudFront origin-facing prefix list only)"
SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME-origin" "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG" == "None" ]]; then
  SG=$(aws ec2 create-security-group --group-name "$NAME-origin" --vpc-id "$VPC_ID" \
        --description "text2sql demo origin - CloudFront origin-facing only" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$NAME-origin},{$TAG}]" \
        --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=8080,ToPort=8080,PrefixListIds=[{PrefixListId=$CF_PREFIX_LIST,Description=CloudFront origin-facing}]" >/dev/null
fi
echo "SG=$SG"

echo "== 3/6 EC2 instance"
sed -e "s#__REGION__#$REGION#; s#__MODEL__#$MODEL#; s#__BRANCH__#$BRANCH#; s#__REPO__#$REPO#; s#__NAME__#$NAME#" \
  "$HERE/userdata.sh" > "$TMP/userdata.sh"
IID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopped" \
       --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [[ "$IID" == "None" ]]; then
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --subnet-id "$SUBNET_ID" \
         --security-group-ids "$SG" --iam-instance-profile "Name=$NAME-ec2" \
         --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2 \
         --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true}' \
         --user-data "file://$TMP/userdata.sh" \
         --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{$TAG}]" \
         --query 'Instances[0].InstanceId' --output text)
fi
aws ec2 wait instance-running --instance-ids "$IID"
DNS=$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
echo "IID=$IID DNS=$DNS"

echo "== 4/6 WAF (us-east-1, scope CLOUDFRONT): default Allow, rate limit $RATE_LIMIT req / 5 min / IP"
ACL_NAME="$NAME-acl"
cat >"$TMP/rules.json" <<JSON
[{"Name": "rate-limit-per-ip", "Priority": 0,
  "Statement": {"RateBasedStatement": {"Limit": $RATE_LIMIT, "EvaluationWindowSec": 300, "AggregateKeyType": "IP"}},
  "Action": {"Block": {}},
  "VisibilityConfig": {"SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true, "MetricName": "rate-limit-per-ip"}}]
JSON
ACL_ID=$(waf list-web-acls --scope CLOUDFRONT --query "WebACLs[?Name=='$ACL_NAME'].Id | [0]" --output text)
if [[ "$ACL_ID" == "None" || -z "$ACL_ID" ]]; then
  waf create-web-acl --scope CLOUDFRONT --name "$ACL_NAME" --default-action Allow={} \
    --rules "file://$TMP/rules.json" --description "$NAME: per-IP rate limit" \
    --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName="$ACL_NAME" \
    --tags "$TAG" >/dev/null
  ACL_ID=$(waf list-web-acls --scope CLOUDFRONT --query "WebACLs[?Name=='$ACL_NAME'].Id | [0]" --output text)
else
  LOCK=$(waf get-web-acl --scope CLOUDFRONT --name "$ACL_NAME" --id "$ACL_ID" --query LockToken --output text)
  waf update-web-acl --scope CLOUDFRONT --name "$ACL_NAME" --id "$ACL_ID" --lock-token "$LOCK" \
    --default-action Allow={} --rules "file://$TMP/rules.json" --description "$NAME: per-IP rate limit" \
    --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName="$ACL_NAME" >/dev/null
fi
ACL_ARN=$(waf get-web-acl --scope CLOUDFRONT --name "$ACL_NAME" --id "$ACL_ID" --query WebACL.ARN --output text)
echo "ACL=$ACL_ARN"

echo "== 5/6 CloudFront KeyValueStore + Basic auth function (user: ${BASIC_CRED%%:*})"
KVS_NAME="$NAME-auth"
if ! cf describe-key-value-store --name "$KVS_NAME" >/dev/null 2>&1; then
  cf create-key-value-store --name "$KVS_NAME" --comment "$NAME basic auth credential" >/dev/null
fi
until [[ "$(cf describe-key-value-store --name "$KVS_NAME" --query KeyValueStore.Status --output text)" == "READY" ]]; do sleep 5; done
KVS_ARN=$(cf describe-key-value-store --name "$KVS_NAME" --query KeyValueStore.ARN --output text)
EXPECTED=$(printf '%s' "$BASIC_CRED" | base64 -w0)
KVS_ETAG=$(kvs describe-key-value-store --kvs-arn "$KVS_ARN" --query ETag --output text)
kvs put-key --kvs-arn "$KVS_ARN" --if-match "$KVS_ETAG" --key basic --value "$EXPECTED" >/dev/null
cat >"$TMP/fn.js" <<'JS'
import cf from 'cloudfront';
const kvs = cf.kvs();
function deny() {
  return { statusCode: 401, statusDescription: 'Unauthorized',
           headers: { 'www-authenticate': { value: 'Basic realm="text2sql-demo", charset="UTF-8"' } } };
}
async function handler(event) {
  const h = event.request.headers.authorization;
  if (!h || h.value.indexOf('Basic ') !== 0) return deny();
  let expected;
  try { expected = await kvs.get('basic'); } catch (e) { return deny(); }   // fail closed
  return h.value.slice(6) === expected ? event.request : deny();
}
JS
FN="$NAME-basic-auth"
FN_CONFIG="{\"Comment\":\"$NAME basic auth\",\"Runtime\":\"cloudfront-js-2.0\",\"KeyValueStoreAssociations\":{\"Quantity\":1,\"Items\":[{\"KeyValueStoreARN\":\"$KVS_ARN\"}]}}"
if ! cf describe-function --name "$FN" >/dev/null 2>&1; then
  cf create-function --name "$FN" --function-config "$FN_CONFIG" --function-code "fileb://$TMP/fn.js" >/dev/null
else
  ETAG=$(cf describe-function --name "$FN" --query ETag --output text)
  cf update-function --name "$FN" --if-match "$ETAG" --function-config "$FN_CONFIG" --function-code "fileb://$TMP/fn.js" >/dev/null
fi
ETAG=$(cf describe-function --name "$FN" --query ETag --output text)
cf publish-function --name "$FN" --if-match "$ETAG" >/dev/null
FN_ARN=$(cf describe-function --name "$FN" --stage LIVE --query FunctionSummary.FunctionMetadata.FunctionARN --output text)

echo "== 6/6 CloudFront distribution (WAF + auth function + X-Origin-Verify header)"
DIST=$(cf list-distributions --query "DistributionList.Items[?Comment=='$NAME'].Id | [0]" --output text)
if [[ "$DIST" == "None" || -z "$DIST" ]]; then
  cat >"$TMP/dist.json" <<JSON
{
  "CallerReference": "$NAME-$(date +%s)", "Comment": "$NAME", "Enabled": true,
  "IsIPV6Enabled": false, "PriceClass": "PriceClass_200",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "ec2-origin", "DomainName": "$DNS",
    "CustomHeaders": {"Quantity": 1, "Items": [{"HeaderName": "X-Origin-Verify", "HeaderValue": "$ORIGIN_SECRET"}]},
    "CustomOriginConfig": {"HTTPPort": 8080, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
                           "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 60}}]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "ec2-origin", "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","PATCH","POST","DELETE"],
                       "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
    "FunctionAssociations": {"Quantity": 1, "Items": [{"EventType": "viewer-request", "FunctionARN": "$FN_ARN"}]}
  },
  "WebACLId": "$ACL_ARN"
}
JSON
  DIST=$(cf create-distribution --distribution-config "file://$TMP/dist.json" --query Distribution.Id --output text)
else
  cf get-distribution-config --id "$DIST" >"$TMP/cur.json"
  ETAG=$(python3 -c "import json;print(json.load(open('$TMP/cur.json'))['ETag'])")
  if python3 - "$TMP/cur.json" "$ACL_ARN" "$FN_ARN" "$ORIGIN_SECRET" "$TMP/new.json" <<'EOF'
import json, sys
cur, acl, fn, secret, out = sys.argv[1:]
cfg = json.load(open(cur))["DistributionConfig"]
before = json.dumps(cfg, sort_keys=True)
cfg["WebACLId"] = acl
cfg["DefaultCacheBehavior"]["FunctionAssociations"] = {
    "Quantity": 1, "Items": [{"EventType": "viewer-request", "FunctionARN": fn}]}
cfg["Origins"]["Items"][0]["CustomHeaders"] = {
    "Quantity": 1, "Items": [{"HeaderName": "X-Origin-Verify", "HeaderValue": secret}]}
json.dump(cfg, open(out, "w"))
sys.exit(0 if json.dumps(cfg, sort_keys=True) != before else 1)
EOF
  then
    cf update-distribution --id "$DIST" --if-match "$ETAG" --distribution-config "file://$TMP/new.json" >/dev/null
    echo "updated distribution $DIST"
  fi
fi
DOMAIN=$(cf get-distribution --id "$DIST" --query Distribution.DomainName --output text)
echo
echo "Done. Distribution $DIST deploys in 5-10 min; a new instance bootstraps in parallel (~5 min)."
echo "URL: https://$DOMAIN/   user: ${BASIC_CRED%%:*}"
echo "Password: aws ssm get-parameter --name /$NAME/basic-auth --with-decryption --query Parameter.Value --output text --profile $PROFILE --region $REGION"
echo "Bootstrap log: aws ssm start-session --target $IID --profile $PROFILE --region $REGION  ->  sudo tail -f /var/log/text2sql-bootstrap.log"
