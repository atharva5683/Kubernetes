#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-devops-challenge}"
BACKEND_DEPLOYMENT="${BACKEND_DEPLOYMENT:-backend}"
BAD_DB_HOST="${BAD_DB_HOST:-postgres-broken.invalid}"

printf 'Injecting DB_HOST=%s into deployment/%s\n' "$BAD_DB_HOST" "$BACKEND_DEPLOYMENT"
kubectl set env deployment/"$BACKEND_DEPLOYMENT" --namespace "$APP_NAMESPACE" DB_HOST="$BAD_DB_HOST"

printf 'Waiting for two readiness checks to fail...\n'
sleep 12

printf '\nRollout status (expected to time out):\n'
kubectl rollout status deployment/"$BACKEND_DEPLOYMENT" --namespace "$APP_NAMESPACE" --timeout=15s || true

printf '\nBackend pods:\n'
kubectl get pods \
  --namespace "$APP_NAMESPACE" \
  --selector app.kubernetes.io/name=backend \
  --output wide

printf '\nReady backend endpoints:\n'
kubectl get endpointslices \
  --namespace "$APP_NAMESPACE" \
  --selector kubernetes.io/service-name=backend \
  --output wide
