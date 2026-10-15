#!/bin/bash
# EC2 user data: clone the demo from the public fork and run the bootstrap.
exec > >(tee -a /var/log/text2sql-bootstrap.log) 2>&1
set -eux
export AWS_REGION=us-west-2
dnf install -y git
until git clone --depth 1 --branch text2sql-demo https://github.com/ensean/Mini-Agent.git /opt/text2sql; do sleep 10; done
mkdir -p /etc/systemd/system/text2sql.service.d
printf '[Service]\nEnvironment=BEDROCK_MODEL=global.anthropic.claude-sonnet-4-6\n' > /etc/systemd/system/text2sql.service.d/model.conf
bash /opt/text2sql/deploy/bootstrap.sh
