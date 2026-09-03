#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated_env="$project_dir/.generated/aks.env"

for command_name in az kubectl helm openssl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ -f "$generated_env" ]]; then
  # shellcheck disable=SC1090
  source "$generated_env"
fi

: "${RESOURCE_GROUP:?Run scripts/provision-aks.sh or export RESOURCE_GROUP.}"
: "${AKS_CLUSTER:?Run scripts/provision-aks.sh or export AKS_CLUSTER.}"
: "${KEY_VAULT_NAME:?Run scripts/provision-aks.sh or export KEY_VAULT_NAME.}"
: "${KEY_VAULT_TENANT_ID:?Run scripts/provision-aks.sh or export KEY_VAULT_TENANT_ID.}"
: "${WORKLOAD_IDENTITY_CLIENT_ID:?Run scripts/provision-aks.sh or export WORKLOAD_IDENTITY_CLIENT_ID.}"
: "${GITHUB_REPO_URL:?Export GITHUB_REPO_URL, for example https://github.com/user/repository.git.}"

GITOPS_BRANCH="${GITOPS_BRANCH:-gitops}"
ARGO_CD_CHART_VERSION="${ARGO_CD_CHART_VERSION:-10.7.0}"
PROMETHEUS_STACK_CHART_VERSION="${PROMETHEUS_STACK_CHART_VERSION:-88.6.3}"

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --overwrite-existing \
  --output none

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update

kubectl create namespace monitoring --dry-run=client --output yaml | kubectl apply --filename -
if ! kubectl get secret grafana-admin --namespace monitoring >/dev/null 2>&1; then
  grafana_admin_password="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
  kubectl create secret generic grafana-admin \
    --namespace monitoring \
    --from-literal=admin-user=admin \
    --from-literal="admin-password=${grafana_admin_password}"
fi

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "$PROMETHEUS_STACK_CHART_VERSION" \
  --values "$project_dir/monitoring/values.yaml" \
  --wait \
  --timeout 15m

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version "$ARGO_CD_CHART_VERSION" \
  --values "$project_dir/platform/argocd-values.yaml" \
  --wait \
  --timeout 10m

helm upgrade --install gitops-bootstrap "$project_dir/bootstrap" \
  --namespace argocd \
  --set-string "git.repositoryUrl=${GITHUB_REPO_URL}" \
  --set-string "git.targetRevision=${GITOPS_BRANCH}" \
  --set-string "azureKeyVault.name=${KEY_VAULT_NAME}" \
  --set-string "azureKeyVault.tenantId=${KEY_VAULT_TENANT_ID}" \
  --set-string "azureKeyVault.workloadIdentityClientId=${WORKLOAD_IDENTITY_CLIENT_ID}"

kubectl get applications.argoproj.io --namespace argocd
kubectl get pods --namespace monitoring
