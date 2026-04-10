#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Wrapper: sources setup-env.sh then runs terraform with all args
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/setup-env.sh" > /dev/null 2>&1
exec terraform -chdir="$(dirname "$SCRIPT_DIR")" "$@"
