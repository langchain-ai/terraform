#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Verifies that all required tools are installed and the cluster is reachable
# before deploying LangSmith on OpenShift.
set -euo pipefail

REQUIRED_TOOLS=(oc kubectl helm terraform)
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

echo "Checking OpenShift login..."
oc whoami
oc cluster-info

echo "Checking kubectl connectivity..."
kubectl cluster-info --request-timeout=5s

echo "Checking Helm langchain repo..."
if ! helm repo list 2>/dev/null | grep -q langchain; then
  echo "Adding langchain Helm repo..."
  helm repo add langchain https://langchain-ai.github.io/helm/
fi
helm repo update langchain

echo "All preflight checks passed."
