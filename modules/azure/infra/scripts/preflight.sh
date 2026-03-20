#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# preflight.sh — Pre-flight checks for LangSmith Azure deployment.
#
# Validates:
#   1. az CLI is installed and logged in
#   2. Correct subscription is selected
#   3. Required resource providers are registered
#   4. Deployer has required RBAC roles (Contributor + User Access Admin)
#   5. terraform.tfvars exists with required fields populated
#
# Run before: terraform init / terraform apply
# Usage: bash infra/scripts/preflight.sh
# Equivalent to: terraform/aws/infra/scripts/preflight.sh (IAM validation)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS="${GREEN}[✓]${NC}"; FAIL="${RED}[✗]${NC}"; WARN="${YELLOW}[!]${NC}"

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERRORS=0

fail() { echo -e "${FAIL} $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo -e "${PASS} $1"; }
warn() { echo -e "${WARN} $1"; }

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith Azure — Pre-flight Checks"
echo "══════════════════════════════════════════════════════"
echo ""

# ── 1. az CLI ─────────────────────────────────────────────────────────────────
echo "── Azure CLI ─────────────────────────────────────────"
if ! command -v az &>/dev/null; then
  fail "az CLI not found. Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
else
  AZ_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "unknown")
  pass "az CLI installed (v${AZ_VERSION})"
fi

# ── 2. Login check ────────────────────────────────────────────────────────────
echo ""
echo "── Authentication ────────────────────────────────────"
ACCOUNT=$(az account show 2>/dev/null || true)
if [ -z "$ACCOUNT" ]; then
  fail "Not logged in to Azure. Run: az login"
else
  SUB_NAME=$(echo "$ACCOUNT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','unknown'))")
  SUB_ID=$(echo "$ACCOUNT"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','unknown'))")
  USER=$(echo "$ACCOUNT"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user',{}).get('name','unknown'))")
  pass "Logged in as: ${USER}"
  pass "Subscription: ${SUB_NAME} (${SUB_ID})"
  warn "Verify this is the correct subscription. Change with: az account set --subscription <id>"
fi

# ── 3. Resource provider registrations ───────────────────────────────────────
echo ""
echo "── Resource Providers ────────────────────────────────"
REQUIRED_PROVIDERS=(
  "Microsoft.ContainerService"
  "Microsoft.DBforPostgreSQL"
  "Microsoft.Cache"
  "Microsoft.KeyVault"
  "Microsoft.Storage"
  "Microsoft.Network"
  "Microsoft.Compute"
  "Microsoft.Authorization"
  "Microsoft.ManagedIdentity"
  "Microsoft.OperationalInsights"
  "Microsoft.Insights"
)

for PROVIDER in "${REQUIRED_PROVIDERS[@]}"; do
  STATE=$(az provider show --namespace "$PROVIDER" --query "registrationState" -o tsv 2>/dev/null || echo "NotFound")
  if [ "$STATE" = "Registered" ]; then
    pass "${PROVIDER}"
  else
    fail "${PROVIDER} is ${STATE}. Register with: az provider register --namespace ${PROVIDER}"
  fi
done

# ── 4. RBAC roles ─────────────────────────────────────────────────────────────
echo ""
echo "── RBAC Roles ────────────────────────────────────────"
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
SUB_ID_CHECK=$(az account show --query id -o tsv 2>/dev/null || echo "")

if [ -z "$CURRENT_USER_ID" ]; then
  warn "Could not determine current user object ID — skipping RBAC check (service principal?)"
else
  # Check Contributor
  CONTRIBUTOR=$(az role assignment list \
    --assignee "$CURRENT_USER_ID" \
    --role "Contributor" \
    --scope "/subscriptions/${SUB_ID_CHECK}" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0")

  if [ "$CONTRIBUTOR" -gt "0" ]; then
    pass "Contributor role on subscription"
  else
    warn "Contributor role not found at subscription scope — may have it at resource group scope (acceptable)"
  fi

  # Check User Access Administrator (required for role assignments in modules)
  UAA=$(az role assignment list \
    --assignee "$CURRENT_USER_ID" \
    --role "User Access Administrator" \
    --scope "/subscriptions/${SUB_ID_CHECK}" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0")

  if [ "$UAA" -gt "0" ]; then
    pass "User Access Administrator role on subscription"
  else
    fail "User Access Administrator role not found. Required for RBAC role assignments in keyvault, storage, and WAF modules."
  fi
fi

# ── 5. terraform.tfvars ───────────────────────────────────────────────────────
echo ""
echo "── Terraform Config ──────────────────────────────────"
TFVARS="${INFRA_DIR}/terraform.tfvars"
if [ ! -f "$TFVARS" ]; then
  fail "terraform.tfvars not found. Copy the example: cp infra/terraform.tfvars.example infra/terraform.tfvars"
else
  pass "terraform.tfvars exists"

  # Check required fields are not placeholder values
  REQUIRED_FIELDS=("location" "langsmith_license_key")
  for FIELD in "${REQUIRED_FIELDS[@]}"; do
    VALUE=$(grep "^${FIELD}" "$TFVARS" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "")
    if [ -z "$VALUE" ] || [[ "$VALUE" == *"<"* ]]; then
      fail "terraform.tfvars: ${FIELD} is empty or still a placeholder"
    else
      pass "terraform.tfvars: ${FIELD} is set"
    fi
  done
fi

# ── 6. Other tooling ──────────────────────────────────────────────────────────
echo ""
echo "── Tooling ───────────────────────────────────────────"
for TOOL in terraform kubectl helm; do
  if command -v "$TOOL" &>/dev/null; then
    VERSION=$("$TOOL" version --short 2>/dev/null | head -1 || "$TOOL" version 2>/dev/null | head -1 || echo "installed")
    pass "${TOOL}: ${VERSION}"
  else
    warn "${TOOL} not found — needed for later passes"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}  All checks passed. Ready for terraform apply.${NC}"
else
  echo -e "${RED}  ${ERRORS} check(s) failed. Fix the issues above before continuing.${NC}"
  exit 1
fi
echo "══════════════════════════════════════════════════════"
echo ""
