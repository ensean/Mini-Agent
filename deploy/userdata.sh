#!/bin/bash
# EC2 user data (deploy_ec2.sh fills in the __PLACEHOLDERS__): clone the branch, run bootstrap.
exec > >(tee -a /var/log/text2sql-bootstrap.log) 2>&1
set -eux
export AWS_REGION=__REGION__ BEDROCK_MODEL=__MODEL__ AGENT_NAME=__NAME__
dnf install -y git
until git clone --depth 1 --branch __BRANCH__ __REPO__ /opt/text2sql; do sleep 10; done
bash /opt/text2sql/deploy/bootstrap.sh
