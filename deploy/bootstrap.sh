#!/usr/bin/env bash
# Runs on the EC2 instance (Amazon Linux 2023) as root from /opt/text2sql. Idempotent.
# ClickHouse (loopback) + app venv with ADOT + systemd unit that starts the app through
# demo/run.sh, i.e. under `opentelemetry-instrument` - without that, no telemetry leaves the box.
set -euxo pipefail
APP_DIR=/opt/text2sql
REGION="${AWS_REGION:-ap-northeast-1}"
MODEL="${BEDROCK_MODEL:-global.anthropic.claude-sonnet-4-6}"

dnf install -y docker git
systemctl enable --now docker
bash "$APP_DIR/demo/clickhouse.sh"

if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
fi
export UV_CACHE_DIR=/var/cache/uv UV_PYTHON_INSTALL_DIR=/opt/uv-python
cd "$APP_DIR"
uv venv --python 3.12 --allow-existing .venv
uv pip install --python .venv/bin/python -e ".[demo]"
uvx mcp-clickhouse==0.7.0 --help >/dev/null 2>&1 </dev/null || true   # warm the uvx cache

# ADOT config: the example file with this region. Credentials come from the instance role.
sed "s/ap-northeast-1/$REGION/g" demo/otel.env.example > demo/otel.env

cat >/etc/systemd/system/text2sql.service <<UNIT
[Unit]
Description=Mini-Agent Text-to-SQL demo (ADOT-instrumented)
After=docker.service network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=/root
Environment=UV_CACHE_DIR=/var/cache/uv
Environment=UV_PYTHON_INSTALL_DIR=/opt/uv-python
Environment=BEDROCK_REGION=$REGION
Environment=BEDROCK_MODEL=$MODEL
# 0.0.0.0 so CloudFront can reach the origin; the SG admits only the CloudFront
# origin-facing prefix list on this port.
Environment=HOST=0.0.0.0
ExecStart=/bin/bash $APP_DIR/demo/run.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable text2sql
systemctl restart text2sql
for _ in $(seq 1 90); do curl -sf 127.0.0.1:8080/healthz && exit 0; sleep 2; done
journalctl -u text2sql --no-pager | tail -50
exit 1
