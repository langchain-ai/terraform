#!/usr/bin/env bash
# Reads Terraform outputs and writes them as Kubernetes Secrets in the LangSmith namespace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${1:-$SCRIPT_DIR/../../infra}"
NAMESPACE="${NAMESPACE:-langsmith}"

echo "Reading Terraform outputs from: $TF_DIR"

POSTGRES_HOST=$(terraform -chdir="$TF_DIR" output -raw postgres_host 2>/dev/null || true)
POSTGRES_PORT=$(terraform -chdir="$TF_DIR" output -raw postgres_port 2>/dev/null || echo "5432")
POSTGRES_PASSWORD=$(terraform -chdir="$TF_DIR" output -raw postgres_password 2>/dev/null || true)
REDIS_HOST=$(terraform -chdir="$TF_DIR" output -raw redis_host 2>/dev/null || true)
BUCKET_NAME=$(terraform -chdir="$TF_DIR" output -raw blob_bucket_name 2>/dev/null || true)
WI_ANNOTATION=$(terraform -chdir="$TF_DIR" output -raw workload_identity_annotation 2>/dev/null || true)

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic langsmith-postgres \
  --namespace "$NAMESPACE" \
  --from-literal=host="$POSTGRES_HOST" \
  --from-literal=port="$POSTGRES_PORT" \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Secrets written to namespace: $NAMESPACE"
echo ""
echo "Next steps:"
echo "  1. Annotate the LangSmith ServiceAccount with:"
echo "       iam.gke.io/gcp-service-account=$WI_ANNOTATION"
echo "  2. Set blobStorageBucket=$BUCKET_NAME in your values-overrides.yaml"
echo "  3. Set redis host=$REDIS_HOST in your values-overrides.yaml"
