#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Verifies that all required tools are installed and the cluster is reachable
# before deploying LangSmith on AWS.
set -euo pipefail
export AWS_PAGER=""

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

# deploy.sh passes a mirror from langsmith_helm_repository. An oci:// registry
# needs no repo entry; helm show chart in deploy.sh checks it instead.
_helm_repo="${LANGSMITH_HELM_REPOSITORY:-https://langchain-ai.github.io/helm/}"
if [[ "$_helm_repo" != oci://* ]]; then
  echo "Checking Helm langchain repo..."
  helm repo add langchain "$_helm_repo" --force-update >/dev/null
  helm repo update langchain
fi

echo "All preflight checks passed."
