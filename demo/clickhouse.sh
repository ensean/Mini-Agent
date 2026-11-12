#!/usr/bin/env bash
# Start a loopback-only ClickHouse in Docker and load the synthetic `live` dataset.
# Used both for local development and by deploy/bootstrap.sh on EC2. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
NAME=text2sql-clickhouse
if ! docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  docker run -d --name "$NAME" --restart unless-stopped \
    -p 127.0.0.1:8123:8123 -p 127.0.0.1:9000:9000 \
    -e CLICKHOUSE_USER=demo -e CLICKHOUSE_PASSWORD=demo -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
    --ulimit nofile=262144:262144 clickhouse/clickhouse-server:25.8
fi
docker start "$NAME" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$NAME" clickhouse-client -u demo --password demo -q 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
docker exec -i "$NAME" clickhouse-client -u demo --password demo --multiquery < seed.sql
docker exec "$NAME" clickhouse-client -u demo --password demo -q \
  "SELECT 'fact_gift_send rows', count() FROM live.fact_gift_send"
