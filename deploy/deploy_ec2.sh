#!/usr/bin/env bash
# Deploy the demo to one EC2 instance behind CloudFront, with plain AWS CLI. Re-runnable.
#   PROFILE=warhorse REGION=ap-northeast-1 bash deploy/deploy_ec2.sh
# Run deploy/setup_observability.sh first (same PROFILE/REGION).
#
# Network posture: the instance SG has NO 0.0.0.0/0 ingress - only port 8080 from the
# CloudFront origin-facing managed prefix list. Admin access is via SSM Session Manager.
# A CloudFront Function restricts viewers to ALLOW_CIDRS (default: your current public IP).
set -euo pipefail
PROFILE="${PROFILE:-default}"
REGION="${REGION:-ap-northeast-1}"
NAME="${AGENT_NAME:-text2sql-demo}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"
MODEL="${BEDROCK_MODEL:-global.anthropic.claude-sonnet-4-6}"
REPO="${REPO:-https://github.com/ensean/Mini-Agent.git}"
BRANCH="${BRANCH:-agentcore-text2sql}"
ALLOW_CIDRS="${ALLOW_CIDRS:-$(curl -s https://checkip.amazonaws.com)/32}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
cf() { command aws --profile "$PROFILE" cloudfront "$@"; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
LOG_GROUP="/aws/bedrock-agentcore/runtimes/$NAME"
TAG="Key=project,Value=$NAME"

VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)}"
SUBNET_ID="${SUBNET_ID:-$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=map-public-ip-on-launch,Values=true \
             --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)}"
CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)
echo "account=$ACCOUNT region=$REGION vpc=$VPC_ID subnet=$SUBNET_ID cf_pl=$CF_PREFIX_LIST allow=$ALLOW_CIDRS"

echo "== 1/5 IAM role: Bedrock invoke + telemetry export (X-Ray OTLP + agent log group) + SSM"
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
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}","arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"]}]}
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

echo "== 2/5 security group (8080 from CloudFront origin-facing prefix list only)"
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

echo "== 3/5 EC2 instance"
sed -e "s#__REGION__#$REGION#; s#__MODEL__#$MODEL#; s#__BRANCH__#$BRANCH#; s#__REPO__#$REPO#" \
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

echo "== 4/5 CloudFront Function: viewer IP allowlist ($ALLOW_CIDRS)"
CIDRS_JS=$(printf '"%s",' ${ALLOW_CIDRS//,/ }); CIDRS_JS="[${CIDRS_JS%,}]"
cat >"$TMP/fn.js" <<JS
var CIDRS = $CIDRS_JS;
function ip2int(ip) { var p = ip.split('.'); return ((+p[0] << 24) >>> 0) + (+p[1] << 16) + (+p[2] << 8) + (+p[3]); }
function allowed(ip) {
  if (!ip || ip.indexOf(':') !== -1) return false;
  for (var i = 0; i < CIDRS.length; i++) {
    var c = CIDRS[i].split('/'), bits = +(c[1] || 32);
    var mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
    if (((ip2int(ip) & mask) >>> 0) === ((ip2int(c[0]) & mask) >>> 0)) return true;
  }
  return false;
}
function handler(event) {
  if (allowed(event.viewer.ip)) return event.request;
  return { statusCode: 403, statusDescription: 'Forbidden',
           headers: { 'content-type': { value: 'text/plain' } }, body: 'Forbidden: viewer IP not in allowlist' };
}
JS
FN="$NAME-viewer-ip-allowlist"
if ! cf describe-function --name "$FN" >/dev/null 2>&1; then
  cf create-function --name "$FN" --function-config 'Comment=viewer IP allowlist,Runtime=cloudfront-js-2.0' \
    --function-code "fileb://$TMP/fn.js" >/dev/null
else
  ETAG=$(cf describe-function --name "$FN" --query ETag --output text)
  cf update-function --name "$FN" --if-match "$ETAG" --function-config 'Comment=viewer IP allowlist,Runtime=cloudfront-js-2.0' \
    --function-code "fileb://$TMP/fn.js" >/dev/null
fi
ETAG=$(cf describe-function --name "$FN" --query ETag --output text)
cf publish-function --name "$FN" --if-match "$ETAG" >/dev/null
FN_ARN=$(cf describe-function --name "$FN" --stage LIVE --query FunctionSummary.FunctionMetadata.FunctionARN --output text)

echo "== 5/5 CloudFront distribution"
DIST=$(cf list-distributions --query "DistributionList.Items[?Comment=='$NAME'].Id | [0]" --output text)
if [[ "$DIST" == "None" || -z "$DIST" ]]; then
  cat >"$TMP/dist.json" <<JSON
{
  "CallerReference": "$NAME-$(date +%s)", "Comment": "$NAME", "Enabled": true,
  "IsIPV6Enabled": false, "PriceClass": "PriceClass_200",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "ec2-origin", "DomainName": "$DNS",
    "CustomOriginConfig": {"HTTPPort": 8080, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
                           "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 60}}]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "ec2-origin", "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","PATCH","POST","DELETE"],
                       "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
    "FunctionAssociations": {"Quantity": 1, "Items": [{"EventType": "viewer-request", "FunctionARN": "$FN_ARN"}]}
  }
}
JSON
  DIST=$(cf create-distribution --distribution-config "file://$TMP/dist.json" --query Distribution.Id --output text)
fi
DOMAIN=$(cf get-distribution --id "$DIST" --query Distribution.DomainName --output text)
echo
echo "Done. Distribution $DIST deploys in 5-10 min; the instance bootstraps in parallel (~5 min)."
echo "URL: https://$DOMAIN/"
echo "Bootstrap log: aws ssm start-session --target $IID --profile $PROFILE --region $REGION  ->  sudo tail -f /var/log/text2sql-bootstrap.log"
