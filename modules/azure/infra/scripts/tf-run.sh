#!/usr/bin/env bash

# MIT License - Copyright (c) 2024 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# tf-run.sh — Run setup-env.sh (if needed) then execute terraform with all provided args.
#
# Useful in CI environments where secrets.auto.tfvars must be regenerated
# before each terraform run.
#
# Usage (from azure/):
#   ./infra/scripts/tf-run.sh plan
#   ./infra/scripts/tf-run.sh apply -auto-approve
#   ./infra/scripts/tf-run.sh output -raw aks_cluster_name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Run setup-env.sh to generate/refresh secrets.auto.tfvars if it doesn't exist yet
if [[ ! -f "$INFRA_DIR/secrets.auto.tfvars" ]]; then
  echo "  secrets.auto.tfvars not found — running setup-env.sh first..."
  bash "$INFRA_DIR/setup-env.sh"
  echo ""
fi

exec terraform -chdir="$INFRA_DIR" "$@"
