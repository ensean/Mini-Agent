#!/usr/bin/env bash
# Runs on the EC2 instance (Amazon Linux 2023) as root, from the unpacked app dir.
# Idempotent: safe to re-run after uploading a new app tarball.
set -euxo pipefail
APP_DIR=/opt/text2sql
REGION="${AWS_REGION:-us-west-2}"

dnf install -y docker git
systemctl enable --now docker

# --- ClickHouse (loopback only; reached by mcp-clickhouse on the same host) ---
if ! docker ps -a --format '{{.Names}}' | grep -qx text2sql-clickhouse; then
  docker run -d --name text2sql-clickhouse --restart unless-stopped \
    -p 127.0.0.1:8123:8123 -p 127.0.0.1:9000:9000 \
    -e CLICKHOUSE_USER=demo -e CLICKHOUSE_PASSWORD=demo -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
    --ulimit nofile=262144:262144 clickhouse/clickhouse-server:latest
fi
for _ in $(seq 1 60); do
  docker exec text2sql-clickhouse clickhouse-client -u demo --password demo -q 'SELECT 1' && break
  sleep 2
done
docker exec -i text2sql-clickhouse clickhouse-client -u demo --password demo --multiquery < "$APP_DIR/demo/seed.sql"

# --- uv + app venv ---
if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
fi
export UV_CACHE_DIR=/var/cache/uv UV_PYTHON_INSTALL_DIR=/opt/uv-python
cd "$APP_DIR"
uv venv --python 3.12 --allow-existing .venv
uv pip install --python .venv/bin/python -e . fastapi "uvicorn[standard]"
uvx mcp-clickhouse --help >/dev/null 2>&1 </dev/null || true   # warm the uvx cache

cat >/etc/systemd/system/text2sql.service <<EOF
[Unit]
Description=Mini-Agent Text-to-SQL demo
After=docker.service network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=/root
Environment=UV_CACHE_DIR=/var/cache/uv
Environment=UV_PYTHON_INSTALL_DIR=/opt/uv-python
Environment=AWS_REGION=$REGION
Environment=BEDROCK_REGION=$REGION
# 0.0.0.0 is required so CloudFront can reach the origin; the security group only
# admits the CloudFront origin-facing prefix list on this port.
ExecStart=$APP_DIR/.venv/bin/uvicorn demo.app:app --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable text2sql
systemctl restart text2sql
for _ in $(seq 1 60); do curl -sf 127.0.0.1:8080/healthz && exit 0; sleep 2; done
journalctl -u text2sql --no-pager | tail -50
exit 1
