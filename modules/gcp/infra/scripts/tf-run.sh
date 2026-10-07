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
# Source setup-env.sh silently. Its output goes to /dev/null, so the trap reports
# a failure. Under set -e, a failed command can exit inside setup-env.sh while
# stderr still goes to /dev/null, so the trap writes to a copy of stderr (fd 3).
exec 3>&2
trap 'echo "ERROR: infra/scripts/setup-env.sh failed. To see why, run: source infra/scripts/setup-env.sh" >&3' EXIT
source "$SCRIPT_DIR/setup-env.sh" > /dev/null 2>&1
trap - EXIT
exec terraform -chdir="$(dirname "$SCRIPT_DIR")" "$@" 3>&-
