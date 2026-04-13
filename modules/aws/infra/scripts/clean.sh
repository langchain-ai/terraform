#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# clean.sh — Remove all local generated/sensitive files after teardown.
#
# Usage (from aws/):
#   make clean
#
# Removes:
#   infra/terraform.tfvars              — live deployment config
#   infra/terraform.tfstate             — local state (when not using remote backend)
#   infra/terraform.tfstate*.backup     — state backup files
#   infra/logs/                         — permutation and parallel test run logs
#   helm/values/langsmith-values*.yaml           — gitignored local copies (canonical versions in examples/)
#
# Does NOT remove:
#   infra/terraform.tfvars.example      — template, keep it
#   infra/terraform.tfvars.dev/.minimum/.production  — preset templates, keep them
#   helm/values/langsmith-values-*.yaml — static overlay files, keep them
#   .terraform/                         — provider cache, not sensitive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$(cd "$INFRA_DIR/.." && pwd)"
HELM_VALUES_DIR="$AWS_DIR/helm/values"

source "$SCRIPT_DIR/_common.sh"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith AWS — Clean local files"
echo "══════════════════════════════════════════════════════"
echo ""
warn "This removes all local secrets and generated values files."
warn "Run AFTER: make uninstall && terraform destroy"
echo ""

# Guard: if tfstate exists with tracked resources, abort unless forced.
if [[ -f "$INFRA_DIR/terraform.tfstate" ]]; then
  _state_resources=$(grep -c '"type":' "$INFRA_DIR/terraform.tfstate" 2>/dev/null || true)
  if [[ "$_state_resources" -gt 0 ]]; then
    echo ""
    fail "terraform.tfstate exists with ${_state_resources} tracked resource(s)."
    warn "Run 'terraform destroy' BEFORE 'make clean' — otherwise Terraform loses track"
    warn "of your AWS resources and you'll have to delete them manually."
    warn "  make uninstall                     # remove Helm release first"
    warn "  cd infra && terraform destroy      # terraform destroy"
    warn "  make clean                         # then clean local files"
    echo ""
    printf "  Force clean anyway? [y/N] "
    read -r _force
    [[ "$_force" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
    echo ""
  fi
fi

printf "  Continue? [y/N] "
read -r _confirm
[[ "$_confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
echo ""

_removed=0

_rm() {
  if [[ -f "$1" ]]; then
    rm -f "$1"
    pass "Removed: ${1#$AWS_DIR/}"
    _removed=$((_removed + 1))
  fi
}

# ── Terraform live config ──────────────────────────────────────────────────────
header "Terraform"
_rm "$INFRA_DIR/terraform.tfvars"

# Local state files (only present when not using a remote S3 backend)
_rm "$INFRA_DIR/terraform.tfstate"
_rm "$INFRA_DIR/terraform.tfstate.backup"
for f in "$INFRA_DIR"/terraform.tfstate.*.backup; do
  [[ -f "$f" ]] && _rm "$f"
done

# ── Test logs ─────────────────────────────────────────────────────────────────
header "Logs"
if [[ -d "$INFRA_DIR/logs" ]]; then
  _log_count=$(find "$INFRA_DIR/logs" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
  if [[ "$_log_count" -gt 0 ]]; then
    rm -rf "$INFRA_DIR/logs"
    pass "Removed: infra/logs/ ($_log_count entries)"
    _removed=$((_removed + 1))
  else
    skip "infra/logs/ already empty"
  fi
else
  skip "infra/logs/ does not exist"
fi

# ── Helm generated values ──────────────────────────────────────────────────────
header "Helm values"
for f in "$HELM_VALUES_DIR"/langsmith-values*.yaml; do
  [[ -f "$f" ]] && _rm "$f"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $_removed -eq 0 ]]; then
  skip "Nothing to remove — already clean"
else
  pass "$_removed item(s) removed"
fi
echo ""
info "To redeploy from scratch:"
info "  make quickstart   # regenerate terraform.tfvars"
info "  source infra/scripts/setup-env.sh"
info "  make init && make apply && make deploy"
echo ""
