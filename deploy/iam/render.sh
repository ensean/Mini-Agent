#!/usr/bin/env bash
# Fill ${REGION} / ${ACCOUNT_ID} / ${AGENT_NAME} in a policy template and print it.
#   REGION=ap-northeast-1 ACCOUNT_ID=123456789012 AGENT_NAME=text2sql-demo bash deploy/iam/render.sh observability-evaluation-policy.json
set -euo pipefail
: "${REGION:?}" "${ACCOUNT_ID:?}" "${AGENT_NAME:=text2sql-demo}"
sed -e "s/\${REGION}/$REGION/g" -e "s/\${ACCOUNT_ID}/$ACCOUNT_ID/g" -e "s/\${AGENT_NAME}/$AGENT_NAME/g" \
  "$(dirname "$0")/$1"
