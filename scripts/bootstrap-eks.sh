#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated_env="$project_dir/.generated/eks.env"

for command_name in aws kubectl helm openssl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ -f "$generated_env" ]]; then
  # shellcheck disable=SC1090
  source "$generated_env"
fi

: "${AWS_REGION:?Run scripts/provision-eks.sh or export AWS_REGION.}"
: "${EKS_CLUSTER:?Run scripts/provision-eks.sh or export EKS_CLUSTER.}"
: "${SECRET_NAME:?Run scripts/provision-eks.sh or export SECRET_NAME.}"
: "${GITHUB_REPO_URL:?Export GITHUB_REPO_URL, for example https://github.com/user/repository.git.}"

GITOPS_BRANCH="${GITOPS_BRANCH:-gitops}"
ARGO_CD_CHART_VERSION="${ARGO_CD_CHART_VERSION:-10.7.0}"
PROMETHEUS_STACK_CHART_VERSION="${PROMETHEUS_STACK_CHART_VERSION:-88.6.3}"
SECRETS_STORE_CSI_VERSION="${SECRETS_STORE_CSI_VERSION:-1.4.8}"
ASCP_VERSION="${ASCP_VERSION:-0.3.10}"

# Configure kubectl for EKS
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$EKS_CLUSTER"

helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts --force-update
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws --force-update
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update

# Install Secrets Store CSI Driver
helm upgrade --install secrets-store-csi-driver secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --version "$SECRETS_STORE_CSI_VERSION" \
  --set syncSecret.enabled=true \
  --wait \
  --timeout 5m

# Install AWS Secrets Provider (ASCP)
helm upgrade --install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  --namespace kube-system \
  --version "$ASCP_VERSION" \
  --wait \
  --timeout 5m

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
  --set-string "awsSecretsManager.region=${AWS_REGION}" \
  --set-string "awsSecretsManager.secretName=${SECRET_NAME}"

kubectl get applications.argoproj.io --namespace argocd
kubectl get pods --namespace monitoring
