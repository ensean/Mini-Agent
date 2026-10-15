#!/usr/bin/env bash
# Deploy the text2sql demo with plain AWS CLI (no CloudFormation).
#   bash deploy/deploy_cli.sh            # uses --profile target, us-west-2
# Re-runnable: each step skips resources that already exist.
set -euo pipefail
PROFILE="${PROFILE:-target}"
REGION="${REGION:-us-west-2}"
VPC_ID="${VPC_ID:-vpc-07433de9a72b052fc}"
SUBNET_ID="${SUBNET_ID:-subnet-046064625aa40250e}"
CF_PREFIX_LIST="${CF_PREFIX_LIST:-pl-82a045eb}"   # com.amazonaws.global.cloudfront.origin-facing
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"
NAME=text2sql-demo
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
TAG="Key=project,Value=$NAME"

echo "== 1/5 IAM role + instance profile"
cat >"$TMP/trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat >"$TMP/policy.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"InvokeClaude","Effect":"Allow",
 "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
 "Resource":["arn:aws:bedrock:*:${ACCOUNT}:inference-profile/*anthropic.claude*",
             "arn:aws:bedrock:*::foundation-model/anthropic.claude*"]}]}
EOF
if ! aws iam get-role --role-name "$NAME-ec2" >/dev/null 2>&1; then
  aws iam create-role --role-name "$NAME-ec2" --assume-role-policy-document "file://$TMP/trust.json" --tags "$TAG" >/dev/null
  aws iam attach-role-policy --role-name "$NAME-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
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
IID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopped" \
       --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [[ "$IID" == "None" ]]; then
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --subnet-id "$SUBNET_ID" \
         --security-group-ids "$SG" --iam-instance-profile "Name=$NAME-ec2" \
         --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2 \
         --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true}' \
         --user-data "file://$HERE/userdata.sh" \
         --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{$TAG}]" \
         --query 'Instances[0].InstanceId' --output text)
fi
aws ec2 wait instance-running --instance-ids "$IID"
DNS=$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
echo "IID=$IID DNS=$DNS"

echo "== 4/5 CloudFront Function (viewer IP allowlist 120/8, 129/8, 27/8)"
cat >"$TMP/fn.js" <<'EOF'
var ALLOWED_FIRST_OCTETS = { '120': true, '129': true, '27': true };
function handler(event) {
  var ip = event.viewer.ip || '';
  if (ALLOWED_FIRST_OCTETS[ip.split('.')[0]] && ip.indexOf(':') === -1) { return event.request; }
  return { statusCode: 403, statusDescription: 'Forbidden',
           headers: { 'content-type': { value: 'text/plain' } },
           body: 'Forbidden: viewer IP not in allowlist' };
}
EOF
FN="$NAME-viewer-ip-allowlist"
if ! command aws --profile "$PROFILE" cloudfront describe-function --name "$FN" >/dev/null 2>&1; then
  command aws --profile "$PROFILE" cloudfront create-function --name "$FN" \
    --function-config 'Comment=viewer IP allowlist,Runtime=cloudfront-js-2.0' \
    --function-code "fileb://$TMP/fn.js" >/dev/null
fi
ETAG=$(command aws --profile "$PROFILE" cloudfront describe-function --name "$FN" --query ETag --output text)
command aws --profile "$PROFILE" cloudfront publish-function --name "$FN" --if-match "$ETAG" >/dev/null 2>&1 || true
FN_ARN=$(command aws --profile "$PROFILE" cloudfront describe-function --name "$FN" --stage LIVE \
          --query FunctionSummary.FunctionMetadata.FunctionARN --output text)

echo "== 5/5 CloudFront distribution"
DIST=$(command aws --profile "$PROFILE" cloudfront list-distributions \
        --query "DistributionList.Items[?Comment=='$NAME'].Id | [0]" --output text)
if [[ "$DIST" == "None" || -z "$DIST" ]]; then
  cat >"$TMP/dist.json" <<EOF
{
  "CallerReference": "$NAME-$(date +%s)",
  "Comment": "$NAME",
  "Enabled": true,
  "IsIPV6Enabled": false,
  "PriceClass": "PriceClass_All",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "ec2-origin", "DomainName": "$DNS",
    "CustomOriginConfig": {"HTTPPort": 8080, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
                           "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 60}}]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "ec2-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","PATCH","POST","DELETE"],
                       "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
    "FunctionAssociations": {"Quantity": 1, "Items": [{"EventType": "viewer-request", "FunctionARN": "$FN_ARN"}]}
  }
}
EOF
  DIST=$(command aws --profile "$PROFILE" cloudfront create-distribution --distribution-config "file://$TMP/dist.json" \
          --query Distribution.Id --output text)
fi
DOMAIN=$(command aws --profile "$PROFILE" cloudfront get-distribution --id "$DIST" --query Distribution.DomainName --output text)
echo
echo "Done. Distribution $DIST is deploying (5-10 min); the instance bootstraps in parallel (~5 min)."
echo "URL: https://$DOMAIN/"
echo "Bootstrap log: aws ssm start-session --target $IID --profile $PROFILE --region $REGION  ->  sudo tail -f /var/log/text2sql-bootstrap.log"
