# Azure AKS and Key Vault setup

## Permissions and tools

Install Azure CLI, Helm 3, `kubectl`, and OpenSSL. The signed-in Azure identity
needs permission to create a resource group, AKS cluster, Key Vault,
user-assigned identity, federated identity credential, and role assignment. It
also needs Key Vault Secrets Officer permission to write the initial password.

## Provision

```bash
az login
export SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
export RESOURCE_GROUP="devops-challenge-rg"       # optional
export AKS_CLUSTER="devops-challenge-aks"         # optional
export LOCATION="centralindia"                    # optional
export KEY_VAULT_NAME="globally-unique-name"      # optional
export DB_PASSWORD="long-random-password"

./scripts/provision-aks.sh
```

The database password is passed only to Azure CLI and is never written to the
generated environment file. If the Key Vault secret already exists, omit
`DB_PASSWORD` to keep its current value.

The script configures this trust path:

```text
AKS service account token
  → OIDC issuer
  → federated credential
  → user-assigned managed identity
  → Key Vault Secrets User
  → Azure Key Vault secret
```

The application chart creates a `SecretProviderClass`. The CSI driver mounts
the Key Vault object and syncs it to `challenge-db-secret`, which is referenced
by the backend and PostgreSQL containers. The plain password is never present in
Git or Helm values.

## Bootstrap platform services

Run the Jenkins release first so the `gitops` branch contains valid Docker Hub
images, then run:

```bash
export GITHUB_REPO_URL="https://github.com/YOUR_USER/devops-k8s-challenge.git"
export GITOPS_BRANCH="gitops"
./scripts/bootstrap-aks.sh
```

The bootstrap pins Argo CD chart `10.7.0` and kube-prometheus-stack `88.6.3`.
Override `ARGO_CD_CHART_VERSION` or `PROMETHEUS_STACK_CHART_VERSION` only after
checking the relevant upgrade notes.

## Verify identity and secret delivery

```bash
# Confirm the AKS add-on is enabled.
az aks show -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER" \
  --query addonProfiles.azureKeyvaultSecretsProvider.enabled -o tsv

# Confirm the CSI driver/provider pods are ready.
kubectl get pods -n kube-system \
  -l 'app in (secrets-store-csi-driver,secrets-store-provider-azure)'

# Confirm the SecretProviderClass and synced Kubernetes Secret exist.
kubectl get secretproviderclass -n devops-challenge
kubectl get secret challenge-db-secret -n devops-challenge

# Inspect status without decoding or exposing the password.
kubectl get secretproviderclasspodstatus -n devops-challenge
```

If secret mounting fails, inspect the newest backend pod events and the CSI
driver/provider logs on the same node. Typical causes are an incorrect client
ID, tenant ID, Key Vault name, federated subject, missing Key Vault role, or RBAC
propagation delay.
