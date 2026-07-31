#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
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
# Sourced directly, the `set -euo pipefail` below would leak into the caller's
# shell and leave it armed to exit on the next non-zero command, and any `exit`
# here would close that shell outright. So when sourced, hand off to a child
# process and return its status - `source` then behaves exactly like running it.
# Keep this above `set`.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source setup-env.sh silently — output suppressed, errors still surface
source "$SCRIPT_DIR/setup-env.sh" > /dev/null 2>&1
exec terraform -chdir="$(dirname "$SCRIPT_DIR")" "$@"
