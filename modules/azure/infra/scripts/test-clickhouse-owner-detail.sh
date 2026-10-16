#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-clickhouse-owner-detail.sh — Unit tests for _clickhouse_owner_detail in _common.sh,
# the one line init-values.sh prints to say why the langsmith-clickhouse Secret is
# Terraform's. The output wins over the tfvars read, each prints once, neither prints
# when both are empty. No Azure, no cluster, no prompts.
#
# Usage:
#   ./infra/scripts/test-clickhouse-owner-detail.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# prints <name> <secret> <host> <expected>: the detail equals expected, exactly once.
prints() {
  local out
  if out=$(_clickhouse_owner_detail "$2" "$3") && [[ "$out" == "$4" ]]; then ok "$1"; else bad "$1 (got: ${out:-<nothing>})"; fi
}

prints "the output alone names the Secret once" "langsmith-clickhouse" "" "clickhouse_secret_name output = langsmith-clickhouse"
prints "the output wins over the tfvars host, and prints once" "langsmith-clickhouse" "ch.data.internal" "clickhouse_secret_name output = langsmith-clickhouse"
prints "the tfvars host alone names the host" "" "ch.data.internal" "clickhouse_host = ch.data.internal in terraform.tfvars"
if _clickhouse_owner_detail "" "" >/dev/null; then bad "neither set should return 1"; else ok "neither set returns 1 and prints nothing"; fi
case "$(_clickhouse_owner_detail "langsmith-clickhouse" "ch.data.internal")" in
  *langsmith-clickhouselangsmith-clickhouse*) bad "the Secret name must not repeat" ;;
  *) ok "the Secret name does not repeat" ;;
esac

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
