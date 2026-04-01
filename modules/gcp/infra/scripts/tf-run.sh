#!/usr/bin/env bash

# MIT License - Copyright (c) 2024 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# tf-run.sh — Sources setup-env.sh then runs terraform with all provided args.
#
# Useful in CI environments where you can't `source` setup-env.sh separately.
#
# Usage (from gcp/):
#   ./infra/scripts/tf-run.sh plan
#   ./infra/scripts/tf-run.sh apply -auto-approve
#   ./infra/scripts/tf-run.sh output -raw cluster_name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source setup-env.sh silently — output suppressed, errors still surface
source "$SCRIPT_DIR/setup-env.sh" > /dev/null 2>&1
exec terraform -chdir="$(dirname "$SCRIPT_DIR")" "$@"
