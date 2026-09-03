#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-devops-challenge}"
BACKEND_DEPLOYMENT="${BACKEND_DEPLOYMENT:-backend}"

printf 'Removing the DB_HOST override; the value will again come from challenge-config.\n'
kubectl set env deployment/"$BACKEND_DEPLOYMENT" --namespace "$APP_NAMESPACE" DB_HOST-
kubectl rollout status deployment/"$BACKEND_DEPLOYMENT" --namespace "$APP_NAMESPACE" --timeout=180s

kubectl get pods \
  --namespace "$APP_NAMESPACE" \
  --selector app.kubernetes.io/name=backend \
  --output wide

kubectl get applications.argoproj.io devops-challenge --namespace argocd \
  --output custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
