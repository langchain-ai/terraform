#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

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

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Grant the langsmith SCC to the namespace's service account
oc adm policy add-scc-to-user langsmith-scc -z langsmith -n "$NAMESPACE" 2>/dev/null || true

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
echo "  1. Verify the SCC is applied: oc get scc langsmith-scc"
echo "  2. Set redis host=$REDIS_HOST in your values-overrides.yaml"
echo "  3. Configure storage backend in your values-overrides.yaml"
