#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated_dir="$project_dir/.generated"
generated_env="$generated_dir/eks.env"

for command_name in aws eksctl kubectl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ -f "$generated_env" && -z "${AWS_REGION:-}" ]]; then
  # shellcheck disable=SC1090
  source "$generated_env"
fi

: "${AWS_REGION:?Export AWS_REGION before running this script.}"

EKS_CLUSTER="${EKS_CLUSTER:-devops-challenge-eks}"
SECRET_NAME="${SECRET_NAME:-devops-challenge-db-password}"
SERVICE_ACCOUNT_NAMESPACE="${SERVICE_ACCOUNT_NAMESPACE:-devops-challenge}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-challenge-workload-identity}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-devops-challenge-secrets-role}"
IAM_POLICY_NAME="${IAM_POLICY_NAME:-devops-challenge-secrets-policy}"

# 1. Create EKS cluster
if ! eksctl get cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
  eksctl create cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION" \
    --nodes 2 \
    --node-type t3.medium \
    --with-oidc \
    --enable-pod-identity-agent
fi

# 2. Configure kubectl
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$EKS_CLUSTER"

# 3. Install EBS CSI add-on
if ! aws eks describe-addon \
  --cluster-name "$EKS_CLUSTER" \
  --addon-name aws-ebs-csi-driver \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks create-addon \
    --cluster-name "$EKS_CLUSTER" \
    --addon-name aws-ebs-csi-driver \
    --region "$AWS_REGION"
fi

# 4. Create AWS Secrets Manager secret
if [[ -n "${DB_PASSWORD:-}" ]]; then
  if aws secretsmanager describe-secret \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value \
      --secret-id "$SECRET_NAME" \
      --secret-string "$DB_PASSWORD" \
      --region "$AWS_REGION" \
      --output none
  else
    aws secretsmanager create-secret \
      --name "$SECRET_NAME" \
      --secret-string "$DB_PASSWORD" \
      --region "$AWS_REGION" \
      --output none
  fi
elif ! aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  printf 'DB_PASSWORD is required because Secrets Manager secret %s does not exist.\n' "$SECRET_NAME" >&2
  exit 1
fi

SECRET_ARN="$(aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query ARN --output text)"

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# 5. Create IAM policy and role
policy_document='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ],
    "Resource": "'"$SECRET_ARN"'"
  }]
}'

if ! aws iam get-policy \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}" \
  >/dev/null 2>&1; then
  POLICY_ARN="$(aws iam create-policy \
    --policy-name "$IAM_POLICY_NAME" \
    --policy-document "$policy_document" \
    --query Policy.Arn --output text)"
else
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"
fi

trust_policy='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Service": "pods.eks.amazonaws.com"
    },
    "Action": [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }]
}'

if ! aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  ROLE_ARN="$(aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "$trust_policy" \
    --query Role.Arn --output text)"
  aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn "$POLICY_ARN"
else
  ROLE_ARN="$(aws iam get-role \
    --role-name "$IAM_ROLE_NAME" \
    --query Role.Arn --output text)"
fi

# 6. Create EKS Pod Identity association
if ! aws eks list-pod-identity-associations \
  --cluster-name "$EKS_CLUSTER" \
  --region "$AWS_REGION" \
  --namespace "$SERVICE_ACCOUNT_NAMESPACE" \
  --service-account "$SERVICE_ACCOUNT_NAME" \
  --query 'associations[0].associationId' --output text 2>/dev/null | grep -q .; then
  aws eks create-pod-identity-association \
    --cluster-name "$EKS_CLUSTER" \
    --region "$AWS_REGION" \
    --namespace "$SERVICE_ACCOUNT_NAMESPACE" \
    --service-account "$SERVICE_ACCOUNT_NAME" \
    --role-arn "$ROLE_ARN"
fi

mkdir -p "$generated_dir"
umask 077
{
  printf 'AWS_REGION=%q\n' "$AWS_REGION"
  printf 'EKS_CLUSTER=%q\n' "$EKS_CLUSTER"
  printf 'SECRET_NAME=%q\n' "$SECRET_NAME"
  printf 'SECRET_ARN=%q\n' "$SECRET_ARN"
  printf 'ROLE_ARN=%q\n' "$ROLE_ARN"
  printf 'POLICY_ARN=%q\n' "$POLICY_ARN"
} > "$generated_env"

printf 'EKS cluster: %s\n' "$EKS_CLUSTER"
printf 'AWS region: %s\n' "$AWS_REGION"
printf 'Secrets Manager secret: %s\n' "$SECRET_NAME"
printf 'IAM role ARN: %s\n' "$ROLE_ARN"
printf 'Non-secret deployment values written to %s\n' "$generated_env"
