#!/usr/bin/env bash
# Restart the demo locally (or on the EC2 host): ./demo/run_local.sh [logfile]
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="${1:-demo/workspace/app.log}"
mkdir -p "$(dirname "$LOG")" demo/workspace
PIDFILE=demo/workspace/app.pid
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")"; sleep 2
fi
nohup .venv/bin/uvicorn demo.app:app --host 127.0.0.1 --port 8080 >"$LOG" 2>&1 &
echo $! >"$PIDFILE"
for _ in $(seq 1 30); do
  curl -sf 127.0.0.1:8080/healthz && exit 0
  sleep 1
done
echo "app did not become healthy; see $LOG" >&2
exit 1
