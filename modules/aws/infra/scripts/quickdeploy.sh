#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# quickdeploy.sh — Full deploy in one command.
#
# Usage (from terraform/aws/):
#   make quickdeploy        — interactive (prompts for terraform apply confirmation)
#   make quickdeploy-auto   — non-interactive (passes -auto-approve to terraform)
#   infra/scripts/quickdeploy.sh [--yes|-y]
#
# Prerequisites:
#   1. source infra/scripts/setup-env.sh   (exports TF_VAR_* secrets)
#   2. make quickstart                     (generates infra/terraform.tfvars)
#
# Steps chained:
#   1. Gate: TF_VAR env vars loaded
#   2. Gate: terraform.tfvars exists
#   3. Gate: terraform init (auto-runs if .terraform/ missing)
#   4. terraform apply
#   5. kubeconfig update
#   6. init-values
#   7. helm deploy
#   8. Success banner with next steps

set -euo pipefail
export AWS_PAGER=""

# ── Resolve paths (script is called from terraform/aws/) ─────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/.."
AWS_DIR="$INFRA_DIR/.."
HELM_DIR="$AWS_DIR/helm"
VALUES_DIR="$HELM_DIR/values"

source "$SCRIPT_DIR/_common.sh"

# ── Colors (direct ANSI for banner/step headers) ──────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Flags ─────────────────────────────────────────────────────────────────────
AUTO_APPROVE=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_APPROVE=true ;;
  esac
done

# ── Step header helper ────────────────────────────────────────────────────────
_step() {
  local n="$1" total="$2" label="$3"
  printf "\n${BOLD}${BLUE}[STEP %s/%s]${NC} %s\n" "$n" "$total" "$label"
  printf "${BLUE}%s${NC}\n" "────────────────────────────────────────────────"
}

TOTAL_STEPS=5

# ─────────────────────────────────────────────────────────────────────────────
# GATE 1: TF_VAR env vars loaded
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}Checking prerequisites...${NC}\n"

if [[ -z "${TF_VAR_langsmith_api_key_salt:-}" ]]; then
  printf "${RED}[ERROR]${NC} Secrets not loaded. Run first:\n"
  printf "  ${CYAN}source infra/scripts/setup-env.sh${NC}\n"
  printf "Then re-run: ${CYAN}make quickdeploy${NC}\n"
  exit 1
fi
pass "TF_VAR_* secrets are loaded"

# ─────────────────────────────────────────────────────────────────────────────
# GATE 2: terraform.tfvars exists
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  printf "${RED}[ERROR]${NC} terraform.tfvars not found. Run first:\n"
  printf "  ${CYAN}make quickstart${NC}\n"
  printf "Then re-run: ${CYAN}make quickdeploy${NC}\n"
  exit 1
fi
pass "terraform.tfvars found"

# ─────────────────────────────────────────────────────────────────────────────
# GATE 3: terraform init (auto-run if .terraform/ missing)
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -d "$INFRA_DIR/.terraform" ]]; then
  warn ".terraform/ not found — running terraform init automatically..."
  _terraform -chdir="$INFRA_DIR" init
  echo ""
else
  pass "terraform already initialized (.terraform/ exists)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1/5: terraform apply
# ─────────────────────────────────────────────────────────────────────────────
_step 1 "$TOTAL_STEPS" "Running terraform apply..."

if [[ "$AUTO_APPROVE" == "true" ]]; then
  info "Running with -auto-approve (--yes flag set)"
  if ! _terraform -chdir="$INFRA_DIR" apply -auto-approve; then
    printf "\n${RED}[ERROR]${NC} terraform apply failed. Check output above.\n"
    printf "Fix the issue and re-run: ${CYAN}make quickdeploy${NC}\n"
    exit 1
  fi
else
  if ! _terraform -chdir="$INFRA_DIR" apply; then
    printf "\n${RED}[ERROR]${NC} terraform apply failed. Check output above.\n"
    printf "Fix the issue and re-run: ${CYAN}make quickdeploy${NC}\n"
    exit 1
  fi
fi

pass "terraform apply complete"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2/5: kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
_step 2 "$TOTAL_STEPS" "Updating kubeconfig for EKS cluster..."

# set-kubeconfig.sh is designed to be sourced so it can export KUBECONFIG.
# We source it here so the KUBECONFIG env var propagates to subsequent steps.
if ! source "$SCRIPT_DIR/set-kubeconfig.sh"; then
  printf "\n${RED}[ERROR]${NC} Failed to update kubeconfig.\n"
  printf "Check that the EKS cluster is ready and your AWS credentials are valid.\n"
  printf "You can retry with: ${CYAN}make kubeconfig${NC}\n"
  exit 1
fi

pass "kubeconfig updated (KUBECONFIG=$KUBECONFIG)"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3/5: init-values
# ─────────────────────────────────────────────────────────────────────────────
_step 3 "$TOTAL_STEPS" "Generating Helm values from Terraform outputs..."

if ! "$HELM_DIR/scripts/init-values.sh"; then
  printf "\n${RED}[ERROR]${NC} init-values.sh failed. Check output above.\n"
  printf "You can retry with: ${CYAN}make init-values${NC}\n"
  exit 1
fi

pass "Helm values generated"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4/5: helm deploy
# ─────────────────────────────────────────────────────────────────────────────
_step 4 "$TOTAL_STEPS" "Deploying LangSmith via Helm..."

if ! "$HELM_DIR/scripts/deploy.sh"; then
  printf "\n${RED}[ERROR]${NC} Helm deploy failed. Check output above.\n"
  printf "You can retry with: ${CYAN}make deploy${NC}\n"
  exit 1
fi

pass "Helm deploy complete"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5/5: success banner
# ─────────────────────────────────────────────────────────────────────────────
_step 5 "$TOTAL_STEPS" "Deployment complete"

# Resolve LangSmith URL from values overrides file
_langsmith_url=""
_overrides_file="$VALUES_DIR/langsmith-values-overrides.yaml"
if [[ -f "$_overrides_file" ]]; then
  _hostname=$(grep -E '^\s*hostname:' "$_overrides_file" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _hostname=""
  _url=$(grep -E '^\s*url:' "$_overrides_file" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _url=""
  if [[ -n "$_url" ]]; then
    _langsmith_url="$_url"
  elif [[ -n "$_hostname" ]]; then
    _langsmith_url="http://$_hostname"
  fi
fi

printf "\n"
printf "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}\n"
printf "${GREEN}${BOLD}║         LangSmith deployed successfully!             ║${NC}\n"
printf "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}\n"
printf "\n"

if [[ -n "$_langsmith_url" ]]; then
  printf "  ${BOLD}LangSmith URL:${NC}  ${CYAN}%s${NC}\n" "$_langsmith_url"
fi

printf "\n"
printf "${BOLD}Next steps:${NC}\n"
printf "  Verify pods are running:\n"
printf "    ${CYAN}kubectl get pods -n langsmith${NC}\n"
printf "\n"
printf "  Check overall deployment state:\n"
printf "    ${CYAN}make status${NC}\n"
printf "\n"
printf "  If pods are still starting (normal on cold cluster — nodes provisioning):\n"
printf "    ${CYAN}kubectl get pods -n langsmith -w${NC}\n"
printf "\n"
