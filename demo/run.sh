#!/usr/bin/env bash
# Run the demo under ADOT auto-instrumentation so the GenAI spans emitted by
# mini_agent/telemetry.py are exported to CloudWatch / AgentCore Observability.
#   bash demo/run.sh                 # foreground, 127.0.0.1:8080
#   HOST=0.0.0.0 bash demo/run.sh    # what systemd uses on EC2 (SG admits CloudFront only)
# Reads demo/otel.env (copy from demo/otel.env.example). Without it the app still runs,
# but telemetry is a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f demo/otel.env ]]; then
  set -a; source demo/otel.env; set +a
else
  echo "WARN: demo/otel.env not found -> telemetry disabled" >&2
fi
# One worker because demo/app.py keeps each session's Agent (its multi-turn history) in process
# memory; more workers would split a session across processes. No --reload: auto-instrumentation
# must wrap the process that actually serves requests.
exec .venv/bin/opentelemetry-instrument .venv/bin/uvicorn demo.app:app \
  --host "${HOST:-127.0.0.1}" --port "${PORT:-8080}" --workers 1
