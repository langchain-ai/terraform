#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# ──────────────────────────────────────────────────────────────────────────────
# preflight.sh — Pre-flight checks for LangSmith Azure deployment.
#
# Validates:
#   1. az CLI is installed and logged in
#   2. Correct subscription is selected
#   3. Required resource providers are registered
#   4. Deployer has required RBAC roles (Contributor + User Access Admin)
#   5. terraform.tfvars exists with required fields populated
#   6. Globally-unique names (Postgres, Storage, Key Vault, dns_label) are free
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

  # Check User Access Administrator or Owner (required for role assignments in modules).
  # Owner implicitly includes all User Access Administrator permissions.
  UAA=$(az role assignment list \
    --assignee "$CURRENT_USER_ID" \
    --role "User Access Administrator" \
    --scope "/subscriptions/${SUB_ID_CHECK}" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0")

  OWNER=$(az role assignment list \
    --assignee "$CURRENT_USER_ID" \
    --role "Owner" \
    --scope "/subscriptions/${SUB_ID_CHECK}" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0")

  if [ "$UAA" -gt "0" ]; then
    pass "User Access Administrator role on subscription"
  elif [ "$OWNER" -gt "0" ]; then
    pass "Owner role on subscription (includes User Access Administrator permissions)"
  else
    fail "Neither Owner nor User Access Administrator role found. Required for RBAC role assignments in keyvault, storage, and WAF modules."
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

  # Check required fields in terraform.tfvars
  REQUIRED_TFVARS_FIELDS=("location" "subscription_id")
  for FIELD in "${REQUIRED_TFVARS_FIELDS[@]}"; do
    VALUE=$(grep "^${FIELD}" "$TFVARS" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "")
    if [ -z "$VALUE" ] || [[ "$VALUE" == *"<"* ]]; then
      fail "terraform.tfvars: ${FIELD} is empty or still a placeholder"
    else
      pass "terraform.tfvars: ${FIELD} is set"
    fi
  done

  # Check secrets.auto.tfvars exists and has license key
  # Secrets live in secrets.auto.tfvars (written by setup-env.sh), not terraform.tfvars.
  SECRETS_FILE="${INFRA_DIR}/secrets.auto.tfvars"
  if [ ! -f "$SECRETS_FILE" ]; then
    fail "secrets.auto.tfvars not found. Run: ./setup-env.sh"
  else
    pass "secrets.auto.tfvars exists"
    LICENSE=$(grep "^langsmith_license_key" "$SECRETS_FILE" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "")
    if [ -z "$LICENSE" ] || [[ "$LICENSE" == *"<"* ]]; then
      fail "secrets.auto.tfvars: langsmith_license_key is empty — re-run ./setup-env.sh"
    else
      pass "secrets.auto.tfvars: langsmith_license_key is set"
    fi
  fi
fi

# ── 6. Globally-unique resource names ────────────────────────────────────────
# Postgres, Redis, Storage, and Key Vault names live in a namespace shared by
# every Azure tenant, as does the public-IP DNS label. A collision surfaces as a
# raw Azure 400 partway through the apply, after the resource group, VNet, and
# AKS already exist — so check up front instead.
echo ""
echo "── Global Name Availability ──────────────────────────"

if [ ! -f "$TFVARS" ] || [ -z "${SUB_ID:-}" ]; then
  warn "Skipping name checks (need terraform.tfvars and an active az login)"
else
  # Read a tfvars value, quoted or bare. Mirrors _parse_tfvar in _common.sh;
  # preflight.sh deliberately has no external sourcing.
  _tfvar() {
    local raw val
    raw=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1) || true
    [ -n "$raw" ] || return 1
    val=$(echo "$raw" | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '[:space:]')
    [ -n "$val" ] || val=$(echo "$raw" | sed 's/.*=[[:space:]]*//' | sed 's/#.*//' | tr -d '[:space:]"')
    [ -n "$val" ] || return 1
    echo "$val"
  }

  NAME_PREFIX=$(_tfvar name_prefix || _tfvar identifier || echo "")
  LOCATION=$(_tfvar location || echo "")
  DNS_LABEL=$(_tfvar dns_label || echo "")
  UNIQUE_NAMES=$(_tfvar unique_resource_names || echo "false")

  # Recompute exactly what main.tf's locals derive, so the check covers the names
  # Terraform will actually request. name_prefix may carry a leading hyphen or
  # not; normalize the same way local.name_suffix does. Keep in sync with
  # local.name_base / local.name_suffix / local.uniq_suffix in infra/main.tf.
  NAME_SUFFIX=""
  [ -n "$NAME_PREFIX" ] && NAME_SUFFIX="-${NAME_PREFIX#-}"

  if [ "$UNIQUE_NAMES" = "true" ]; then
    NAME_BASE="ls"
    if command -v shasum &>/dev/null; then
      HASH=$(printf '%s' "${SUB_ID}${NAME_SUFFIX}" | shasum -a 256 | cut -c1-6)
    else
      HASH=$(printf '%s' "${SUB_ID}${NAME_SUFFIX}" | sha256sum | cut -c1-6)
    fi
    UNIQ_SUFFIX="-${HASH}"
  else
    NAME_BASE="langsmith"
    UNIQ_SUFFIX=""
    warn "unique_resource_names is false — using the legacy shared-namespace names, which collide between deployments"
  fi

  PG_NAME=$(_tfvar postgres_name || echo "${NAME_BASE}-postgres${NAME_SUFFIX}${UNIQ_SUFFIX}")
  REDIS_NAME=$(_tfvar redis_name || echo "${NAME_BASE}-redis${NAME_SUFFIX}${UNIQ_SUFFIX}")
  KV_NAME=$(_tfvar keyvault_name || echo "${NAME_BASE}-kv${NAME_SUFFIX}${UNIQ_SUFFIX}")
  BLOB_RAW=$(_tfvar storage_account_name || echo "${NAME_BASE}-blob${NAME_SUFFIX}${UNIQ_SUFFIX}")
  BLOB_NAME=$(echo "$BLOB_RAW" | tr -d '-') # the blob module strips hyphens

  # Reject anything that isn't a plain Azure resource name before it reaches a
  # URL or a JSON body — terraform.tfvars is user-authored input.
  _name_is_safe() {
    echo "$1" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$'
  }

  # _check_name <label> <name> <url> <json-body> <availability-field>
  # A definitive "taken" fails the run. Anything else (auth blip, api-version
  # drift, unparseable body) only warns — preflight must never block a deploy
  # because Azure rotated an API version.
  _check_name() {
    local label="$1" name="$2" url="$3" body="$4" field="$5" resp avail msg
    if ! _name_is_safe "$name"; then
      warn "${label}: '${name}' is not a valid Azure resource name — check skipped"
      return 0
    fi
    if [ -n "$body" ]; then
      resp=$(az rest --method post --url "$url" --body "$body" -o json 2>/dev/null || true)
    else
      resp=$(az rest --method get --url "$url" -o json 2>/dev/null || true)
    fi
    if [ -z "$resp" ]; then
      warn "${label}: '${name}' — could not verify (Azure API error); collision would surface during apply"
      return 0
    fi
    avail=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('${field}',''))" 2>/dev/null || echo "")
    # Azure's Key Vault message runs several hundred chars of soft-delete prose;
    # keep the first sentence so one failure doesn't bury the rest of the report.
    msg=$(echo "$resp" | python3 -c "
import sys, json
m = (json.load(sys.stdin).get('message', '') or '').strip()
print(m if len(m) <= 110 else m[:110].rsplit(' ', 1)[0] + ' …')" 2>/dev/null || echo "")
    case "$avail" in
      True)  pass "${label}: '${name}' is available" ;;
      False) fail "${label}: '${name}' is ALREADY TAKEN globally. ${msg}" ;;
      *)     warn "${label}: '${name}' — unexpected API response; collision would surface during apply" ;;
    esac
  }

  _check_name "Postgres" "$PG_NAME" \
    "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.DBforPostgreSQL/locations/${LOCATION}/checkNameAvailability?api-version=2023-03-01-preview" \
    "{\"name\":\"${PG_NAME}\",\"type\":\"Microsoft.DBforPostgreSQL/flexibleServers\"}" "nameAvailable"

  _check_name "Storage account" "$BLOB_NAME" \
    "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Storage/checkNameAvailability?api-version=2023-01-01" \
    "{\"name\":\"${BLOB_NAME}\",\"type\":\"Microsoft.Storage/storageAccounts\"}" "nameAvailable"

  _check_name "Key Vault" "$KV_NAME" \
    "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01" \
    "{\"name\":\"${KV_NAME}\",\"type\":\"Microsoft.KeyVault/vaults\"}" "nameAvailable"

  if [ -n "$DNS_LABEL" ]; then
    _check_name "Public IP DNS label" "$DNS_LABEL" \
      "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Network/locations/${LOCATION}/CheckDnsNameAvailability?domainNameLabel=${DNS_LABEL}&api-version=2023-09-01" \
      "" "available"
  else
    warn "dns_label not set — skipping DNS label check"
  fi

  # Azure Managed Redis (Microsoft.Cache/redisEnterprise) exposes no working
  # CheckNameAvailability endpoint: the subscription-scoped one rejects the
  # redisEnterprise type, and the location-scoped one returns "The requested
  # location is invalid" for every valid region and api-version. So only the
  # in-subscription case can be pre-checked — a leftover from a failed apply.
  # A cross-tenant Redis collision still surfaces at apply time; the hashed name
  # under unique_resource_names is what makes that unlikely.
  if _name_is_safe "$REDIS_NAME"; then
    REDIS_HIT=$(az redisenterprise list --query "length([?name=='${REDIS_NAME}'])" -o tsv 2>/dev/null || echo "0")
    echo "$REDIS_HIT" | grep -qE '^[0-9]+$' || REDIS_HIT=0
    if [ "$REDIS_HIT" -gt "0" ]; then
      fail "Redis: '${REDIS_NAME}' already exists in this subscription — import it or delete it before applying"
    else
      warn "Redis: '${REDIS_NAME}' not present in this subscription (Azure exposes no global name check for Managed Redis)"
    fi
  fi
fi

# ── 7. Other tooling ──────────────────────────────────────────────────────────
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
