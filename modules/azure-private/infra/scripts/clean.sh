#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# clean.sh — Remove local generated/sensitive files after teardown.
#
# Usage (from infra/):
#   bash scripts/clean.sh
#
# Removes, for both Terraform roots (infra/ and bootstrap/):
#   terraform.tfvars            — live deployment config
#   secrets.auto.tfvars         — generated secrets (Key Vault seed values)
#   .api_key_salt etc.          — temp secret files from setup-env.sh (infra/ only)
#   terraform.tfstate(.backup)  — local state (only present without a remote backend)
#
# Does NOT remove:
#   terraform.tfvars.example    — templates, keep them
#   .terraform/                 — provider cache, not sensitive
#
# Run AFTER teardown:
#   terraform -chdir=bootstrap destroy   # from the jumpbox
#   terraform -chdir=infra destroy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="$(cd "$INFRA_DIR/.." && pwd)"
BOOTSTRAP_DIR="$MODULE_DIR/bootstrap"

source "$SCRIPT_DIR/_common.sh"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith azure-private — Clean local files"
echo "══════════════════════════════════════════════════════"
echo ""
warn "This removes local secrets, tfvars, and local state for both roots."
warn "Run AFTER: terraform -chdir=bootstrap destroy && terraform -chdir=infra destroy"
echo ""

# Guard: if a tfstate still tracks resources, destroy hasn't run — deleting it
# would orphan the Azure resources. Warn and require an explicit force.
_guard_state() {
  local dir="$1" name="$2" n
  if [[ -f "$dir/terraform.tfstate" ]]; then
    n=$(grep -c '"type":' "$dir/terraform.tfstate" 2>/dev/null; true)
    if [[ "${n:-0}" -gt 0 ]]; then
      fail "$name/terraform.tfstate still tracks ${n} resource(s) — run 'terraform -chdir=$name destroy' first."
      return 1
    fi
  fi
  return 0
}

_state_ok=true
_guard_state "$INFRA_DIR" "infra" || _state_ok=false
_guard_state "$BOOTSTRAP_DIR" "bootstrap" || _state_ok=false
if [[ "$_state_ok" != "true" ]]; then
  echo ""
  warn "Destroy the tracked resources before cleaning, or force-clean anyway."
  printf "  Force clean anyway? [y/N] "
  read -r _force
  [[ "$_force" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
fi

printf "  Continue? [y/N] "
read -r _confirm
[[ "$_confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
echo ""

_removed=0
_rm() {
  if [[ -f "$1" ]]; then
    rm -f "$1"
    pass "Removed: ${1#"$MODULE_DIR"/}"
    _removed=$((_removed + 1))
  fi
}

_clean_root() {
  local dir="$1" name="$2"
  header "$name/"
  _rm "$dir/terraform.tfvars"
  _rm "$dir/secrets.auto.tfvars"
  _rm "$dir/terraform.tfstate"
  _rm "$dir/terraform.tfstate.backup"
  for f in "$dir"/terraform.tfstate.*.backup; do
    [[ -f "$f" ]] && _rm "$f"
  done
}

_clean_root "$INFRA_DIR" "infra"

# Temp secret files written by setup-env.sh before Key Vault exists (infra/ only)
for f in .api_key_salt .jwt_secret .deployments_key .agent_builder_key .insights_key .polly_key; do
  _rm "$INFRA_DIR/$f"
done

_clean_root "$BOOTSTRAP_DIR" "bootstrap"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $_removed -eq 0 ]]; then
  skip "Nothing to remove — already clean"
else
  pass "$_removed file(s) removed"
fi
echo ""
info "To redeploy from scratch, see DEPLOYMENT.md (Phase 0 → Phase 4)."
echo ""
