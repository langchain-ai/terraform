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
#   4. The identity Terraform will use can write role assignments
#   5. Subscription offer type is not blocked from provisioning Postgres
#   6. terraform.tfvars exists with required fields populated
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

# ── 4. Deployer identity and RBAC ─────────────────────────────────────────────
# Terraform does not necessarily authenticate as your az login. The azurerm
# provider reads its ARM_* environment variables before falling back to the CLI,
# so a stale ARM_CLIENT_ID in the shell means every check below validates a
# principal Terraform will never use: preflight passes, apply 403s as somebody
# else. Resolve the identity the provider will actually present, then ask what
# that identity can do.
echo ""
echo "── Deployer Identity ─────────────────────────────────"

SUB_ID_CHECK=$(az account show --query id -o tsv 2>/dev/null || echo "")
TENANT_ID_CHECK=$(az account show --query tenantId -o tsv 2>/dev/null || echo "")

if [ -n "${ARM_SUBSCRIPTION_ID:-}" ] && [ "$ARM_SUBSCRIPTION_ID" != "$SUB_ID_CHECK" ]; then
  fail "ARM_SUBSCRIPTION_ID is ${ARM_SUBSCRIPTION_ID} but the active az subscription is ${SUB_ID_CHECK}. Terraform would deploy into the former; every check in this script reads the latter."
fi
if [ -n "${ARM_TENANT_ID:-}" ] && [ "$ARM_TENANT_ID" != "$TENANT_ID_CHECK" ]; then
  fail "ARM_TENANT_ID is ${ARM_TENANT_ID} but the active az tenant is ${TENANT_ID_CHECK}."
fi

# Turning an application ID into its service principal object ID takes a
# directory read, which plenty of deployers are not granted. Without an object
# ID there is no assignee to query, so the RBAC block below degrades to a
# warning rather than reporting a verdict it cannot support.
# PRINCIPAL_IS_CALLER records whether the resolved principal is the identity
# running this script. Only that identity's PIM eligibilities are readable, so
# without the flag an eligible-but-inactive role held by the operator would be
# reported as if it belonged to the service principal Terraform will use.
PRINCIPAL_ID=""
PRINCIPAL_IS_CALLER=1
if [ -n "${ARM_CLIENT_ID:-}" ]; then
  PRINCIPAL_KIND="service principal from ARM_CLIENT_ID"
  PRINCIPAL_ID=$(az ad sp show --id "$ARM_CLIENT_ID" --query id -o tsv 2>/dev/null || echo "")
  PRINCIPAL_IS_CALLER=0
  warn "ARM_CLIENT_ID is set — Terraform authenticates as that service principal, not as your az login"
elif [ "${ARM_USE_MSI:-}" = "true" ] || [ "${ARM_USE_OIDC:-}" = "true" ]; then
  PRINCIPAL_KIND="managed identity or OIDC federation"
  PRINCIPAL_IS_CALLER=0
  warn "ARM_USE_MSI or ARM_USE_OIDC is set — Terraform authenticates as a workload identity this script cannot resolve"
elif [ "$(az account show --query user.type -o tsv 2>/dev/null || echo "")" = "servicePrincipal" ]; then
  PRINCIPAL_KIND="service principal from az login"
  SP_APP_ID=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
  PRINCIPAL_ID=$(az ad sp show --id "$SP_APP_ID" --query id -o tsv 2>/dev/null || echo "")
else
  PRINCIPAL_KIND="signed-in user"
  PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
fi

if [ -n "$PRINCIPAL_ID" ]; then
  pass "Terraform will authenticate as ${PRINCIPAL_KIND} (object ID ${PRINCIPAL_ID})"
else
  warn "Could not resolve an object ID for the ${PRINCIPAL_KIND} — a denied directory read will do this"
fi

# ── RBAC ──────────────────────────────────────────────────────────────────────
# Eight resources across the Azure modules create role assignments (storage,
# keyvault ×2, dns, bastion, k8s-cluster ×3), so
# Microsoft.Authorization/roleAssignments/write decides whether apply finishes.
# Reconstructing that answer from role definitions cannot get it right: an ABAC
# condition can restrict which roles a delegate may assign, a deny assignment
# overrides every grant including Owner, a PIM-eligible role grants nothing until
# activated, and a custom role can carry the action under any name. So ask ARM
# for the decision it will actually make, per action and per scope.
#
# checkAccess is the call the portal makes to decide which buttons to grey out.
# It is also undocumented: nothing in azure-rest-api-specs, no az command, and
# 2018-09-01-preview is the only api-version ever registered. What it does that
# nothing documented can: evaluate a named principal (not just the caller) at a
# scope that does not exist yet, with deny assignments and conditions already
# applied. A missing or reshaped response is therefore treated as unavailable and
# degrades to a role-name check, never as a verdict.
echo ""
echo "── RBAC Roles ────────────────────────────────────────"

RBAC_TMP=$(mktemp -d)
trap 'rm -rf "$RBAC_TMP"' EXIT

if [ -z "$PRINCIPAL_ID" ] || [ -z "$SUB_ID_CHECK" ]; then
  warn "Skipping RBAC check — no principal object ID to query"
else
  # Every scope the deployment writes a role assignment at is knowable before
  # apply. The subscription covers everything created beneath it by inheritance.
  # The resource group is where every LangSmith resource lands, and one of the
  # AGIC assignments names it literally. A bring-your-own VNet can sit in a
  # platform-managed resource group, which is where a landing zone puts its deny
  # assignments, so it gets checked on its own when one is configured.
  #
  # Both values come out of terraform.tfvars and end up in a request URL, so each
  # is held to the pattern its Terraform variable already validates and dropped
  # if it does not fit. An unchecked value here could aim the request elsewhere.
  TFVARS_FILE="${INFRA_DIR}/terraform.tfvars"

  # An absent key is a valid answer (every variable read here has a default), so
  # the trailing || true keeps a no-match grep from tripping set -e.
  tfvar() {
    [ -f "$TFVARS_FILE" ] || return 0
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS_FILE" 2>/dev/null | head -1 | cut -d'"' -f2 || true
  }

  SCOPES=("/subscriptions/${SUB_ID_CHECK}")

  # printf adds the newline grep needs to see an empty identifier as a line to
  # match rather than as no input at all. Empty is valid: it means no suffix.
  IDENTIFIER=$(tfvar identifier)
  if printf '%s\n' "$IDENTIFIER" | grep -qE '^(-[a-z0-9][a-z0-9-]*)?$'; then
    SCOPES+=("/subscriptions/${SUB_ID_CHECK}/resourceGroups/langsmith-rg${IDENTIFIER}")
  else
    warn "terraform.tfvars: identifier is not a valid resource-name suffix, so the deployment resource group was not checked"
  fi

  EXISTING_VNET=$(tfvar vnet_id)
  if [ -n "$EXISTING_VNET" ]; then
    if printf '%s\n' "$EXISTING_VNET" \
      | grep -qE '^/subscriptions/[0-9a-fA-F-]+/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Network/virtualNetworks/[A-Za-z0-9._-]+$'; then
      SCOPES+=("$EXISTING_VNET")
    else
      warn "terraform.tfvars: vnet_id is not a VNet resource ID, so that scope was not checked"
    fi
  fi

  # roleAssignments/write is the action that decides; the rest are what a
  # principal without broad resource access trips over first. checkAccess batches,
  # so all of them cost one request per scope. The object ID goes through
  # json.dumps into a file rather than onto a command line.
  python3 - "$PRINCIPAL_ID" > "${RBAC_TMP}/body.json" <<'PY'
import json, sys

ACTIONS = [
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleAssignments/delete",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.ContainerService/managedClusters/write",
    "Microsoft.KeyVault/vaults/write",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Network/virtualNetworks/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/write",
    "Microsoft.Cache/redis/write",
]

print(json.dumps({
    "Subject": {"Attributes": {"ObjectId": sys.argv[1]}},
    "Actions": [{"Id": action, "IsDataAction": False} for action in ACTIONS],
}))
PY

  : > "${RBAC_TMP}/scopes.txt"
  SCOPE_COUNT=0
  for SCOPE in "${SCOPES[@]}"; do
    SCOPE_COUNT=$((SCOPE_COUNT + 1))
    printf '%s\n' "$SCOPE" >> "${RBAC_TMP}/scopes.txt"
    az rest --method post \
      --url "https://management.azure.com${SCOPE}/providers/Microsoft.Authorization/checkAccess?api-version=2018-09-01-preview" \
      --headers "Content-Type=application/json" \
      --body "@${RBAC_TMP}/body.json" \
      -o json > "${RBAC_TMP}/response-${SCOPE_COUNT}.json" 2>/dev/null || true
  done

  # Eligible-but-inactive PIM roles are why a deployer who "has Owner" is still
  # denied: checkAccess reports what is active now. asTarget() only reports the
  # calling identity's eligibilities, so this is skipped when Terraform will
  # authenticate as somebody else rather than mislabelled as that principal's.
  echo "{}" > "${RBAC_TMP}/eligibilities.json"
  if [ "$PRINCIPAL_IS_CALLER" -eq 1 ]; then
    az rest --method get \
      --url "https://management.azure.com/subscriptions/${SUB_ID_CHECK}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&\$filter=asTarget()" \
      -o json > "${RBAC_TMP}/eligibilities.json" 2>/dev/null || echo "{}" > "${RBAC_TMP}/eligibilities.json"
  fi

  # One pass over the responses so the shell only renders verdicts. Each line it
  # prints is "<severity> <message>"; the single word "unavailable" means no scope
  # answered and the fallback below should run instead.
  RBAC_VERDICT=$(python3 - \
    "$RBAC_TMP" \
    "${RBAC_TMP}/eligibilities.json" \
    "$PRINCIPAL_IS_CALLER" <<'PY' || echo "unavailable"
import json, os, sys

tmp, elig_path, is_caller = sys.argv[1:4]

ROLE_WRITE = "microsoft.authorization/roleassignments/write"
ROLE_DELETE = "microsoft.authorization/roleassignments/delete"

# checkAccess names the granting role by bare GUID. These four are the built-ins
# that carry roleAssignments/write, verified against az role definition list;
# anything else prints its GUID rather than a guess.
ROLE_NAMES = {
    "8e3af657a8ff443ca75c2fe8c4bcb635": "Owner",
    "b24988ac618042a0ab8820f7382dd24c": "Contributor",
    "18d7d88dd35e4fb5a5c37773c20a72d9": "User Access Administrator",
    "f58310d9a9f6439a9e8df62e7b41a168": "Role Based Access Control Administrator",
}

# Assigned to the modules by name, so an ABAC condition that omits any of them
# breaks apply even where roleAssignments/write is permitted.
ASSIGNED_ROLES = (
    "Storage Blob Data Contributor, Key Vault Secrets Officer, "
    "Key Vault Secrets User, DNS Zone Contributor, "
    "Virtual Machine Administrator Login, Reader, Contributor, "
    "Network Contributor"
)


def load(path, default):
    try:
        with open(path) as fh:
            text = fh.read().strip()
    except OSError:
        return default
    if not text:
        return default
    try:
        return json.loads(text)
    except ValueError:
        return default


def role_label(assignment):
    guid = (assignment.get("roleDefinitionId") or "").replace("-", "").lower()
    name = ROLE_NAMES.get(guid)
    if name:
        return name
    if assignment.get("assignedToCustomRole"):
        return "custom role %s" % (guid or "?")
    return "role %s" % (guid or "?")


try:
    with open(os.path.join(tmp, "scopes.txt")) as fh:
        scopes = [line.strip() for line in fh if line.strip()]
except OSError:
    scopes = []

# A 200 carrying anything but the non-empty array this API is observed to return
# means the preview contract moved. Refuse the scope rather than guess at it.
answered, unanswered = [], []
for index, scope in enumerate(scopes, start=1):
    data = load(os.path.join(tmp, "response-%d.json" % index), None)
    if isinstance(data, list) and data:
        answered.append((scope, data))
    else:
        unanswered.append(scope)

if not answered:
    print("unavailable")
    raise SystemExit(0)

out = []
if unanswered:
    out.append("warn checkAccess did not answer at %s, so nothing here speaks to what the "
               "deployment can do there." % ", ".join(unanswered))

denied_write = False
for scope, decisions in answered:
    for decision in decisions:
        if (decision.get("actionId") or "").lower() != ROLE_WRITE:
            continue
        assignment = decision.get("roleAssignment") or {}
        deny = decision.get("denyAssignment") or {}
        if decision.get("accessDecision") == "Allowed":
            out.append("pass roleAssignments/write permitted at %s, granted by %s held at %s"
                       % (scope, role_label(assignment), assignment.get("scope") or "?"))
            if assignment.get("condition"):
                out.append("warn That grant carries an ABAC condition, so it permits only the roles "
                           "the condition allows. The modules assign: %s. Condition: %s"
                           % (ASSIGNED_ROLES, " ".join(assignment["condition"].split())[:240]))
        else:
            denied_write = True
            if deny:
                # The roleAssignment shape here was read off live responses; a
                # populated denyAssignment was never one of them, because you
                # cannot create a deny assignment to test with. Try the key names
                # the RBAC APIs use elsewhere and stay useful if it is none of
                # them: that a deny assignment exists at all is the finding.
                name = (deny.get("displayName") or deny.get("denyAssignmentName")
                        or deny.get("name") or deny.get("id") or "unnamed")
                out.append("fail roleAssignments/write is denied at %s by deny assignment \"%s\". "
                           "Deny assignments override every role assignment including Owner, so no "
                           "role grant will fix this: it has to be removed, or this principal added "
                           "to its exclusion list." % (scope, name))
            else:
                out.append("fail roleAssignments/write is not permitted at %s. All eight role "
                           "assignments in the Azure modules need it." % scope)

for scope, decisions in answered:
    refused = sorted({decision.get("actionId") or "?" for decision in decisions
                      if (decision.get("actionId") or "").lower() not in (ROLE_WRITE, ROLE_DELETE)
                      and decision.get("accessDecision") != "Allowed"})
    if refused:
        out.append("fail Not permitted at %s: %s. The deployment creates all of these."
                   % (scope, ", ".join(refused)))
    else:
        out.append("pass Every resource type the deployment creates is writable at %s" % scope)

    for decision in decisions:
        if ((decision.get("actionId") or "").lower() == ROLE_DELETE
                and decision.get("accessDecision") != "Allowed"):
            out.append("warn roleAssignments/delete is not permitted at %s. Apply can create the "
                       "eight assignments, but terraform destroy and any change that replaces one "
                       "will fail." % scope)

# Only reached when the decisive action was refused, which is the one case where
# an inactive PIM role is the likely explanation and the fix is a click, not a
# ticket. Whether an eligible role carries the action is not knowable here, so
# they are all listed rather than filtered on a guess.
if denied_write:
    if is_caller == "1":
        eligible = []
        for instance in (load(elig_path, {}) or {}).get("value") or []:
            props = instance.get("properties") or {}
            expanded = (props.get("expandedProperties") or {}).get("roleDefinition") or {}
            if expanded.get("displayName"):
                eligible.append("%s at %s" % (expanded["displayName"], props.get("scope") or "?"))
        if eligible:
            out.append("fail PIM holds these roles for this identity as eligible but not active: %s. "
                       "checkAccess reports what is active now, so if one of them carries "
                       "roleAssignments/write, activating it (portal: PIM -> My roles -> Activate) "
                       "fixes this. Activation is time-bound, so activate for longer than the apply "
                       "will take." % "; ".join(sorted(set(eligible))))
    else:
        out.append("warn Terraform will authenticate as a principal other than the one running this "
                   "script, so its PIM eligibilities cannot be read here. A role that is held but "
                   "not activated looks exactly like a role that is not held.")

print("\n".join(out))
PY
  )

  if [ "$RBAC_VERDICT" = "unavailable" ]; then
    warn "checkAccess (Microsoft.Authorization/checkAccess, 2018-09-01-preview) did not answer at any scope. It is an unversioned preview API, so it may have changed or this tenant may refuse it. Falling back to a role-name check, which cannot see deny assignments, ABAC conditions, or custom roles."
    HELD=$(az role assignment list \
      --scope "/subscriptions/${SUB_ID_CHECK}" \
      --include-inherited \
      --assignee-object-id "$PRINCIPAL_ID" \
      --include-groups \
      --query "[].roleDefinitionName" -o tsv 2>/dev/null || echo "")
    HELD_FLAT=$(printf '%s' "$HELD" | tr '\n' ',' | sed 's/,$//')
    case ",${HELD_FLAT}," in
      *,Owner,*|*,"User Access Administrator",*|*,"Role Based Access Control Administrator",*)
        pass "Holds ${HELD_FLAT} at or above the subscription, which carries roleAssignments/write" ;;
      ,,)
        fail "No role assignments could be read for this principal, and checkAccess did not answer. Nothing here can tell you whether apply will succeed — check the identity by hand before applying." ;;
      *)
        fail "No Owner, User Access Administrator, or Role Based Access Control Administrator grant found at or above the subscription. Roles held: ${HELD_FLAT}. A custom role carrying roleAssignments/write would also work and is not detected on this path." ;;
    esac
  else
    pass "checkAccess answered, so the verdicts below are this principal's effective access with deny assignments and ABAC conditions applied"
    while IFS= read -r LINE; do
      case "$LINE" in
        pass\ *) pass "${LINE#pass }" ;;
        warn\ *) warn "${LINE#warn }" ;;
        fail\ *) fail "${LINE#fail }" ;;
        *) [ -z "$LINE" ] || warn "$LINE" ;;
      esac
    done <<EOF
$RBAC_VERDICT
EOF
  fi
fi

# ── 5. Subscription offer type ────────────────────────────────────────────────
# Azure blocks some subscription offer types from provisioning PostgreSQL
# Flexible Server in high-demand regions, surfacing as LocationIsOfferRestricted
# well into the apply, after AKS has already been built. The restriction is a
# property of how the subscription was bought, not of regional capacity, so no
# amount of retrying or resizing clears it. quotaId is the only field that
# reports the offer type, and it is a prefix match: the suffix is a signup date.
echo ""
echo "── Subscription Offer Type ───────────────────────────"
QUOTA_ID=$(az rest --method get \
  --url "https://management.azure.com/subscriptions/${SUB_ID_CHECK}?api-version=2022-12-01" \
  --query "subscriptionPolicies.quotaId" -o tsv 2>/dev/null || echo "")

if [ -z "$QUOTA_ID" ]; then
  warn "Could not read the subscription offer type — skipping offer restriction check"
else
  case "$QUOTA_ID" in
    FreeTrial_*|MSDN_*|MSDNDevTest_*|VisualStudio_*|AzurePass_*|MPN_*|SponsoredMS_*)
      warn "Subscription offer type is ${QUOTA_ID}."
      warn "Offer types like this are commonly blocked from provisioning PostgreSQL"
      warn "Flexible Server in high-demand regions (LocationIsOfferRestricted)."
      warn "Request an exemption at https://aka.ms/postgres-request-quota-increase,"
      warn "or set postgres_source = \"in-cluster\" for a dev deployment."
      ;;
    *)
      pass "Subscription offer type: ${QUOTA_ID}"
      ;;
  esac
fi

# ── 6. terraform.tfvars ───────────────────────────────────────────────────────
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
