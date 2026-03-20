#!/usr/bin/env bash
# Wrapper: sources setup-env.sh then runs terraform with all args
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/setup-env.sh" > /dev/null 2>&1
exec terraform -chdir="$(dirname "$SCRIPT_DIR")" "$@"
