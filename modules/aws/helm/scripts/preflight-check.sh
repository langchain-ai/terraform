#!/usr/bin/env bash
# Verifies that all required tools are installed and the cluster is reachable
# before deploying LangSmith on AWS.
set -euo pipefail

REQUIRED_TOOLS=(aws kubectl helm terraform)
MISSING=()

for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING+=("$tool")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Missing required tools: ${MISSING[*]}" >&2
  exit 1
fi

echo "Checking AWS credentials..."
aws sts get-caller-identity

echo "Checking kubectl connectivity..."
kubectl cluster-info --request-timeout=5s

echo "Checking Helm langchain repo..."
if ! helm repo list 2>/dev/null | grep -q langchain; then
  echo "Adding langchain Helm repo..."
  helm repo add langchain https://langchain-ai.github.io/helm/
fi
helm repo update langchain

echo "All preflight checks passed."
