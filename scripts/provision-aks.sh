#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated_dir="$project_dir/.generated"
generated_env="$generated_dir/aks.env"

for command_name in az kubectl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ -f "$generated_env" && -z "${SUBSCRIPTION_ID:-}" ]]; then
  # shellcheck disable=SC1090
  source "$generated_env"
fi

: "${SUBSCRIPTION_ID:?Export SUBSCRIPTION_ID before running this script.}"

RESOURCE_GROUP="${RESOURCE_GROUP:-devops-challenge-rg}"
AKS_CLUSTER="${AKS_CLUSTER:-devops-challenge-aks}"
LOCATION="${LOCATION:-centralindia}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-devopskv${RANDOM}${RANDOM}}"
WORKLOAD_IDENTITY_NAME="${WORKLOAD_IDENTITY_NAME:-devops-challenge-wi}"
KEY_VAULT_SECRET_NAME="${KEY_VAULT_SECRET_NAME:-devops-challenge-db-password}"
SERVICE_ACCOUNT_NAMESPACE="${SERVICE_ACCOUNT_NAMESPACE:-devops-challenge}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-challenge-workload-identity}"
FEDERATED_CREDENTIAL_NAME="${FEDERATED_CREDENTIAL_NAME:-devops-challenge-federated}"

az account set --subscription "$SUBSCRIPTION_ID"

if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
fi

if ! az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" >/dev/null 2>&1; then
  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_CLUSTER" \
    --location "$LOCATION" \
    --node-count 2 \
    --node-vm-size Standard_D2s_v5 \
    --enable-managed-identity \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-addons azure-keyvault-secrets-provider \
    --generate-ssh-keys \
    --output none
fi

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --overwrite-existing \
  --output none

if ! az keyvault show --name "$KEY_VAULT_NAME" >/dev/null 2>&1; then
  az keyvault create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$KEY_VAULT_NAME" \
    --location "$LOCATION" \
    --enable-rbac-authorization true \
    --output none
fi

if ! az identity show --resource-group "$RESOURCE_GROUP" --name "$WORKLOAD_IDENTITY_NAME" >/dev/null 2>&1; then
  az identity create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$WORKLOAD_IDENTITY_NAME" \
    --location "$LOCATION" \
    --output none
fi

WORKLOAD_IDENTITY_CLIENT_ID="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$WORKLOAD_IDENTITY_NAME" --query clientId --output tsv)"
workload_identity_principal_id="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$WORKLOAD_IDENTITY_NAME" --query principalId --output tsv)"
key_vault_scope="$(az keyvault show --name "$KEY_VAULT_NAME" --query id --output tsv)"
KEY_VAULT_TENANT_ID="$(az keyvault show --name "$KEY_VAULT_NAME" --query properties.tenantId --output tsv)"
aks_oidc_issuer="$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" --query oidcIssuerProfile.issuerUrl --output tsv)"

signed_in_type="$(az account show --query user.type --output tsv)"
if [[ "$signed_in_type" == "user" ]]; then
  signed_in_object_id="$(az ad signed-in-user show --query id --output tsv)"
  signed_in_principal_type="User"
else
  signed_in_client_id="$(az account show --query user.name --output tsv)"
  signed_in_object_id="$(az ad sp show --id "$signed_in_client_id" --query id --output tsv)"
  signed_in_principal_type="ServicePrincipal"
fi

secrets_officer_assignment="$(az role assignment list \
  --assignee "$signed_in_object_id" \
  --scope "$key_vault_scope" \
  --query "[?roleDefinitionName=='Key Vault Secrets Officer'].id | [0]" \
  --output tsv)"

if [[ -z "$secrets_officer_assignment" ]]; then
  az role assignment create \
    --assignee-object-id "$signed_in_object_id" \
    --assignee-principal-type "$signed_in_principal_type" \
    --role "Key Vault Secrets Officer" \
    --scope "$key_vault_scope" \
    --output none
fi

role_assignment_id="$(az role assignment list \
  --assignee "$workload_identity_principal_id" \
  --scope "$key_vault_scope" \
  --query "[?roleDefinitionName=='Key Vault Secrets User'].id | [0]" \
  --output tsv)"

if [[ -z "$role_assignment_id" ]]; then
  az role assignment create \
    --assignee-object-id "$workload_identity_principal_id" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Secrets User" \
    --scope "$key_vault_scope" \
    --output none
fi

if ! az identity federated-credential show \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name "$WORKLOAD_IDENTITY_NAME" \
  --name "$FEDERATED_CREDENTIAL_NAME" >/dev/null 2>&1; then
  az identity federated-credential create \
    --resource-group "$RESOURCE_GROUP" \
    --identity-name "$WORKLOAD_IDENTITY_NAME" \
    --name "$FEDERATED_CREDENTIAL_NAME" \
    --issuer "$aks_oidc_issuer" \
    --subject "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
    --audiences api://AzureADTokenExchange \
    --output none
fi

if [[ -n "${DB_PASSWORD:-}" ]]; then
  secret_written=false
  for _attempt in $(seq 1 12); do
    if az keyvault secret set \
      --vault-name "$KEY_VAULT_NAME" \
      --name "$KEY_VAULT_SECRET_NAME" \
      --value "$DB_PASSWORD" \
      --output none 2>/dev/null; then
      secret_written=true
      break
    fi
    sleep 10
  done
  if [[ "$secret_written" != "true" ]]; then
    printf 'Unable to write the database secret after waiting for Azure RBAC propagation.\n' >&2
    exit 1
  fi
elif ! az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$KEY_VAULT_SECRET_NAME" >/dev/null 2>&1; then
  printf 'DB_PASSWORD is required because Key Vault secret %s does not exist.\n' "$KEY_VAULT_SECRET_NAME" >&2
  exit 1
fi

mkdir -p "$generated_dir"
umask 077
{
  printf 'SUBSCRIPTION_ID=%q\n' "$SUBSCRIPTION_ID"
  printf 'RESOURCE_GROUP=%q\n' "$RESOURCE_GROUP"
  printf 'AKS_CLUSTER=%q\n' "$AKS_CLUSTER"
  printf 'LOCATION=%q\n' "$LOCATION"
  printf 'KEY_VAULT_NAME=%q\n' "$KEY_VAULT_NAME"
  printf 'KEY_VAULT_TENANT_ID=%q\n' "$KEY_VAULT_TENANT_ID"
  printf 'WORKLOAD_IDENTITY_CLIENT_ID=%q\n' "$WORKLOAD_IDENTITY_CLIENT_ID"
  printf 'KEY_VAULT_SECRET_NAME=%q\n' "$KEY_VAULT_SECRET_NAME"
} > "$generated_env"

printf 'AKS cluster: %s\n' "$AKS_CLUSTER"
printf 'Resource group: %s\n' "$RESOURCE_GROUP"
printf 'Key Vault: %s\n' "$KEY_VAULT_NAME"
printf 'Workload identity client ID: %s\n' "$WORKLOAD_IDENTITY_CLIENT_ID"
printf 'Non-secret deployment values written to %s\n' "$generated_env"
