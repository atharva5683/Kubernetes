#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-devops-challenge}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
LOG_FILE="${TMPDIR:-/tmp}/devops-challenge-port-forward.log"

kubectl port-forward --namespace "$APP_NAMESPACE" service/frontend "$LOCAL_PORT:80" >"$LOG_FILE" 2>&1 &
PORT_FORWARD_PID=$!
cleanup() {
  kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _attempt in $(seq 1 20); do
  if curl --silent --fail "http://127.0.0.1:$LOCAL_PORT/api/health/ready" >/dev/null; then
    break
  fi
  sleep 1
done

echo "Frontend:"
curl --silent --show-error --fail "http://127.0.0.1:$LOCAL_PORT/" | sed -n '/<title>/p'
echo
echo "Backend through frontend proxy:"
curl --silent --show-error --fail "http://127.0.0.1:$LOCAL_PORT/api/"
echo
echo "Database round trip:"
curl --silent --show-error --fail "http://127.0.0.1:$LOCAL_PORT/api/visits"
echo
echo "Readiness:"
curl --silent --show-error --fail "http://127.0.0.1:$LOCAL_PORT/api/health/ready"
echo
echo "Prometheus metric sample:"
curl --silent --show-error --fail "http://127.0.0.1:$LOCAL_PORT/api/metrics" \
  | sed -n '/challenge_database_ready/p;/challenge_http_requests_total/p' \
  | head -n 8
