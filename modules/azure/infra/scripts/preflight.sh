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
#   7. The configured Postgres version and SKU are offered in the region
#   8. Globally-unique names (Postgres, Storage, Key Vault, dns_label) are free
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

# ── Derived resource names ────────────────────────────────────────────────────
# Derived once for both the RBAC scope check and the global-name check; deriving
# them separately is how RBAC drifted to a hardcoded "langsmith-rg".
# Keep in sync with local.name_base / local.name_suffix in infra/main.tf.
TFVARS="${INFRA_DIR}/terraform.tfvars"

# Read a tfvars value, quoted or bare. Mirrors _parse_tfvar in _common.sh, which
# preflight.sh deliberately does not source. Non-zero when absent or empty, so
# each caller supplies that variable's own default.
_tfvar() {
  local raw val
  [ -f "$TFVARS" ] || return 1
  raw=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1) || true
  [ -n "$raw" ] || return 1
  val=$(echo "$raw" | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '[:space:]')
  [ -n "$val" ] || val=$(echo "$raw" | sed 's/.*=[[:space:]]*//' | sed 's/#.*//' | tr -d '[:space:]"')
  [ -n "$val" ] || return 1
  echo "$val"
}

# identifier is name_prefix's legacy name. Track which one was read so a warning
# names a key the user actually has.
NAME_KEY="name_prefix"
NAME_PREFIX=$(_tfvar name_prefix || echo "")
if [ -z "$NAME_PREFIX" ] && NAME_PREFIX=$(_tfvar identifier); then
  NAME_KEY="identifier"
fi

# The separator hyphen is optional; normalize as local.name_suffix does. Empty is
# valid and means no suffix.
NAME_SUFFIX=""
[ -n "$NAME_PREFIX" ] && NAME_SUFFIX="-${NAME_PREFIX#-}"

UNIQUE_NAMES=$(_tfvar unique_resource_names || echo "false")
if [ "$UNIQUE_NAMES" = "true" ]; then NAME_BASE="ls"; else NAME_BASE="langsmith"; fi

RESOURCE_GROUP_NAME="${NAME_BASE}-rg${NAME_SUFFIX}"

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

# What terraform_principal_type has to be set to if an ABAC condition on
# principalType forces the field to be sent explicitly.
case "$PRINCIPAL_KIND" in
*"service principal"* | *"managed identity"*) PRINCIPAL_TYPE_HINT="ServicePrincipal" ;;
*) PRINCIPAL_TYPE_HINT="User" ;;
esac

# The deployer's own Key Vault Secrets Officer grant is the only role assignment
# in the tree whose target is not a service principal, so it is the only one an
# ABAC condition pinned to ServicePrincipal can reject. Mirrors main.tf: an
# explicit value wins, null follows create_keyvault.
KV_ADMIN_GRANT=$(_tfvar keyvault_manage_terraform_admin_assignment || _tfvar create_keyvault || echo "true")

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
  SCOPES=("/subscriptions/${SUB_ID_CHECK}")

  # printf supplies the newline grep needs to match an empty suffix as a line
  # rather than as no input. Empty is valid: no suffix.
  if printf '%s\n' "$NAME_SUFFIX" | grep -qE '^(-[a-z0-9][a-z0-9-]*)?$'; then
    SCOPES+=("/subscriptions/${SUB_ID_CHECK}/resourceGroups/${RESOURCE_GROUP_NAME}")
  else
    warn "terraform.tfvars: ${NAME_KEY} is not a valid resource-name suffix, so the deployment resource group was not checked"
  fi

  EXISTING_VNET=$(_tfvar vnet_id || echo "")
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
    # redisEnterprise is Azure Managed Redis, what the module provisions.
    # Microsoft.Cache/redis is classic Azure Cache and a separate RBAC action.
    "Microsoft.Cache/redisEnterprise/write",
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
    "$PRINCIPAL_IS_CALLER" \
    "$PRINCIPAL_TYPE_HINT" \
    "$KV_ADMIN_GRANT" <<'PY' || echo "unavailable"
import json, os, sys

tmp, elig_path, is_caller, principal_type_hint, kv_admin_grant = sys.argv[1:6]

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


def pins_service_principal(condition):
    """Whether an ABAC condition admits only ServicePrincipal targets for write.

    Conditions are `!(ActionMatches{<action>}) OR <constraint>` clauses joined by
    AND, so the constraint that applies to write is the text from that action up
    to the next clause — a condition that pins the type on delete alone leaves
    write unconstrained. Values are single-quoted, so matching the quoted literal
    keeps a permissive {'ServicePrincipal', 'User'} from reading as a pin.
    Anything this cannot parse falls through to the softer advice below rather
    than telling the operator to turn off a grant that would have worked.
    """
    flat = " ".join(condition.split()).lower()
    start = flat.find(ROLE_WRITE)
    if start >= 0:
        end = flat.find(" and ", start)
        flat = flat[start:end if end > 0 else len(flat)]
    return ("principaltype" in flat
            and "'serviceprincipal'" in flat
            and "'user'" not in flat)


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
                cond = " ".join(assignment["condition"].split())
                out.append("warn That grant carries an ABAC condition, so it permits only the roles "
                           "the condition allows. The modules assign: %s. Condition: %s"
                           % (ASSIGNED_ROLES, cond[:240]))
                # Terraform omits principal_type on the Key Vault Secrets Officer
                # grant by default, and a condition testing principalType rejects
                # a request that omits it as a plain AuthorizationFailed, which
                # reads like a missing role rather than an unmet condition.
                if "principaltype" in cond.lower():
                    if pins_service_principal(cond) and principal_type_hint != "ServicePrincipal":
                        # terraform_principal_type declares what the principal is,
                        # it does not change it, and ARM resolves the real type
                        # from the object ID regardless — so against this shape
                        # every value of it is denied, including the one the
                        # softer branch below recommends.
                        if kv_admin_grant == "false":
                            out.append("pass The condition admits only ServicePrincipal targets, which "
                                       "this %s is not — but keyvault_manage_terraform_admin_assignment "
                                       "is already false, so no request in the apply is subject to it."
                                       % principal_type_hint.lower())
                        else:
                            out.append("fail The condition admits only ServicePrincipal targets, and "
                                       "Terraform will authenticate as a %s. terraform_principal_type "
                                       "declares the type rather than changing it, so no value of it "
                                       "satisfies this condition. Set "
                                       "keyvault_manage_terraform_admin_assignment = false in "
                                       "terraform.tfvars and hold Key Vault Secrets Officer some other "
                                       "way — a grant inherited from the subscription or resource "
                                       "group is enough, and `az role assignment list --assignee "
                                       "<object-id> --all` says whether you already do. Running apply "
                                       "as a service principal is the other way out, and is what this "
                                       "condition exists to require."
                                       % principal_type_hint.lower())
                    else:
                        out.append("warn The condition tests principalType. Set terraform_principal_type "
                                   "= \"%s\" in terraform.tfvars, or the Key Vault Secrets Officer grant "
                                   "fails at apply with a 403 that names no condition."
                                   % principal_type_hint)
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
    FreeTrial_*|MSDN_*|MSDNDevTest_*|VisualStudio_*|AzurePass_*|MPN_*|Sponsored_*)
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
    elif [ "$FIELD" = "subscription_id" ] && ! [[ "$VALUE" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      fail "terraform.tfvars: subscription_id is \"${VALUE}\", which is not a GUID. Get it with: az account show --query id -o tsv"
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

# ── 7. PostgreSQL regional capabilities ─────────────────────────────────────
# The offer-type check above is only a heuristic. This command asks the
# subscription-scoped capability API what can actually be created in the chosen
# region, and also lets us check the exact version and SKU before apply.
echo ""
echo "── PostgreSQL Regional Availability ──────────────────"

if [ ! -f "$TFVARS" ] || [ -z "${SUB_ID:-}" ]; then
  warn "Skipping Postgres capability checks (need terraform.tfvars and an active az login)"
else
  LOCATION=$(_tfvar location || echo "")
  POSTGRES_SOURCE=$(_tfvar postgres_source || echo "external")
  POSTGRES_VERSION=$(_tfvar postgres_version || echo "16")
  POSTGRES_SKU=$(_tfvar postgres_sku_name || echo "GP_Standard_D2ds_v4")

  if [ "$POSTGRES_SOURCE" = "in-cluster" ]; then
    pass "postgres_source = in-cluster — no Flexible Server capability check needed"
  elif [ -z "$LOCATION" ]; then
    warn "terraform.tfvars: location is empty — skipping Postgres capability checks"
  else
    PG_CAPABILITIES_FILE="${RBAC_TMP}/postgres-capabilities.json"
    PG_CAPABILITIES_STDERR="${RBAC_TMP}/postgres-capabilities.stderr"

    if az postgres flexible-server list-skus -l "$LOCATION" -o json \
      > "$PG_CAPABILITIES_FILE" 2> "$PG_CAPABILITIES_STDERR"; then
      # Azure CLI always prints its pricing notice on stderr. Ignore only that
      # known line; any other stderr makes the result uncertain, so do not turn
      # it into an availability verdict.
      PG_UNEXPECTED_STDERR=$(grep -Fv \
        "For prices please refer to https://aka.ms/postgres-pricing" \
        "$PG_CAPABILITIES_STDERR" || true)
      if [ -n "$(printf '%s' "$PG_UNEXPECTED_STDERR" | tr -d '[:space:]')" ]; then
        warn "Postgres list-skus wrote unexpected stderr — skipping regional availability, version, and SKU checks"
      else
        if ! PG_CAPABILITY_VERDICT=$(python3 - \
          "$PG_CAPABILITIES_FILE" "$LOCATION" "$POSTGRES_VERSION" "$POSTGRES_SKU" <<'PY'
import json
import sys

path, location, configured_version, configured_sku = sys.argv[1:5]

try:
    with open(path) as fh:
        capabilities = json.load(fh)
except (OSError, ValueError):
    print("invalid")
    raise SystemExit(0)

if not isinstance(capabilities, list):
    print("invalid")
    raise SystemExit(0)
if not capabilities:
    print("empty")
    raise SystemExit(0)

versions = set()
skus = set()
sku_pairs = set()
tier_prefixes = {
    "Burstable": "B",
    "GeneralPurpose": "GP",
    "MemoryOptimized": "MO",
}

for capability in capabilities:
    if not isinstance(capability, dict):
        print("invalid")
        raise SystemExit(0)
    raw_versions = capability.get("supportedServerVersions")
    editions = capability.get("supportedServerEditions")
    if not isinstance(raw_versions, list) or not isinstance(editions, list):
        print("invalid")
        raise SystemExit(0)

    for version in raw_versions:
        if not isinstance(version, dict) or not isinstance(version.get("name"), str):
            print("invalid")
            raise SystemExit(0)
        versions.add(version["name"])

    for edition in editions:
        if not isinstance(edition, dict):
            print("invalid")
            raise SystemExit(0)
        tier = edition.get("name")
        raw_skus = edition.get("supportedServerSkus")
        if not isinstance(tier, str) or not isinstance(raw_skus, list):
            print("invalid")
            raise SystemExit(0)
        for sku in raw_skus:
            if not isinstance(sku, dict) or not isinstance(sku.get("name"), str):
                print("invalid")
                raise SystemExit(0)
            name = sku["name"]
            sku_pairs.add((tier.casefold(), name.casefold()))
            prefix = tier_prefixes.get(tier)
            skus.add("%s_%s" % (prefix, name) if prefix else "%s:%s" % (tier, name))

if not versions or not skus:
    print("invalid")
    raise SystemExit(0)


def version_key(value):
    return (0, int(value)) if value.isdigit() else (1, value)


def summarize(values, limit=8):
    values = list(values)
    if len(values) <= limit:
        return ", ".join(values)
    return "%s, ... (%d total)" % (", ".join(values[:limit]), len(values))


sorted_versions = sorted(versions, key=version_key)
sorted_skus = sorted(skus, key=str.casefold)
print("pass Postgres capability API returned %d SKU(s) and %d version(s) in %s"
      % (len(skus), len(versions), location))

if configured_version in versions:
    print("pass postgres_version '%s' is available in %s"
          % (configured_version, location))
else:
    print("fail postgres_version '%s' is not available in %s. Available versions: %s"
          % (configured_version, location, summarize(sorted_versions)))

prefix, separator, raw_sku = configured_sku.partition("_")
tier_by_prefix = {value: key for key, value in tier_prefixes.items()}
configured_tier = tier_by_prefix.get(prefix)
sku_available = bool(separator and configured_tier and
                     (configured_tier.casefold(), raw_sku.casefold()) in sku_pairs)
if sku_available:
    print("pass postgres_sku_name '%s' is available in %s"
          % (configured_sku, location))
else:
    print("fail postgres_sku_name '%s' is not available in %s. Available SKUs: %s"
          % (configured_sku, location, summarize(sorted_skus)))
PY
        ); then
          PG_CAPABILITY_VERDICT="invalid"
        fi

        case "$PG_CAPABILITY_VERDICT" in
          empty)
            fail "PostgreSQL Flexible Server is unavailable to the active subscription in ${LOCATION}: list-skus returned an empty array"
            ;;
          invalid)
            warn "Postgres list-skus returned an unexpected response — skipping regional availability, version, and SKU checks"
            ;;
          *)
            while IFS= read -r LINE; do
              case "$LINE" in
                pass\ *) pass "${LINE#pass }" ;;
                fail\ *) fail "${LINE#fail }" ;;
                *) [ -z "$LINE" ] || warn "$LINE" ;;
              esac
            done <<EOF
$PG_CAPABILITY_VERDICT
EOF
            ;;
        esac
      fi
    else
      warn "Postgres list-skus failed — skipping regional availability, version, and SKU checks"
    fi
  fi
fi

# ── 8. Globally-unique resource names ────────────────────────────────────────
# Postgres, Redis, Storage, and Key Vault names live in a namespace shared by
# every Azure tenant, as does the public-IP DNS label. A collision surfaces as a
# raw Azure 400 partway through the apply, after the resource group, VNet, and
# AKS already exist — so check up front instead. A name this deployment already
# owns is not a collision, so the answer is read against Terraform state first.
echo ""
echo "── Global Name Availability ──────────────────────────"

if [ ! -f "$TFVARS" ] || [ -z "${SUB_ID:-}" ]; then
  warn "Skipping name checks (need terraform.tfvars and an active az login)"
else
  LOCATION=$(_tfvar location || echo "")
  DNS_LABEL=$(_tfvar dns_label || echo "")

  # Only these four names carry the hash, so it is derived here rather than above.
  # Keep in sync with local.uniq_suffix in infra/main.tf, salt included: omit the
  # salt and preflight keeps checking the names it was bumped to escape.
  SALT=$(_tfvar name_suffix_salt || echo "")
  if [ "$UNIQUE_NAMES" = "true" ]; then
    if command -v shasum &>/dev/null; then
      HASH=$(printf '%s' "${SUB_ID}${NAME_SUFFIX}${SALT}" | shasum -a 256 | cut -c1-6)
    else
      HASH=$(printf '%s' "${SUB_ID}${NAME_SUFFIX}${SALT}" | sha256sum | cut -c1-6)
    fi
    UNIQ_SUFFIX="-${HASH}"
  else
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

  # checkNameAvailability answers a global question and carries no notion of
  # ownership: a resource this deployment created reports "taken" exactly like
  # one a stranger holds, so re-running preflight against a live deployment
  # fails on its own resources. Terraform state is the oracle for which it is.
  # Preflight runs before `terraform init`, so `state pull` only answers once a
  # backend is initialised — fall back to the local state file, and treat no
  # state at all as the first run, where every name genuinely has to be free.
  STATE_JSON=$(terraform -chdir="$INFRA_DIR" state pull </dev/null 2>/dev/null || true)
  if [ -z "$STATE_JSON" ] && [ -f "${INFRA_DIR}/terraform.tfstate" ]; then
    STATE_JSON=$(cat "${INFRA_DIR}/terraform.tfstate")
  fi
  STATE_NAMES=$(printf '%s' "$STATE_JSON" | python3 -c "
import json, sys
try:
    state = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for res in state.get('resources', []):
    for inst in res.get('instances', []):
        attrs = inst.get('attributes') or {}
        for key in ('name', 'domain_name_label'):
            value = attrs.get(key)
            if isinstance(value, str) and value:
                print(value)
" 2>/dev/null || true)

  _in_state() {
    [ -n "$STATE_NAMES" ] && printf '%s\n' "$STATE_NAMES" | grep -qxF "$1"
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
      False)
        if _in_state "$name"; then
          pass "${label}: '${name}' is already deployed and tracked in Terraform state"
        else
          fail "${label}: '${name}' is ALREADY TAKEN globally. ${msg}"
        fi ;;
      *)     warn "${label}: '${name}' — unexpected API response; collision would surface during apply" ;;
    esac
  }

  _check_name "Postgres" "$PG_NAME" \
    "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.DBforPostgreSQL/locations/${LOCATION}/checkNameAvailability?api-version=2023-03-01-preview" \
    "{\"name\":\"${PG_NAME}\",\"type\":\"Microsoft.DBforPostgreSQL/flexibleServers\"}" "nameAvailable"

  _check_name "Storage account" "$BLOB_NAME" \
    "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Storage/checkNameAvailability?api-version=2023-01-01" \
    "{\"name\":\"${BLOB_NAME}\",\"type\":\"Microsoft.Storage/storageAccounts\"}" "nameAvailable"

  # A soft-deleted vault holds its name for the whole retention window while
  # appearing in neither Terraform state nor `az keyvault list`, so the generic
  # "already in use" message is the only signal and it names no remedy.
  KV_DELETED=0
  if _name_is_safe "$KV_NAME"; then
    KV_DELETED=$(az keyvault list-deleted --query "length([?name=='${KV_NAME}'])" -o tsv 2>/dev/null || echo "0")
    echo "$KV_DELETED" | grep -qE '^[0-9]+$' || KV_DELETED=0
  fi
  if [ "$KV_DELETED" -gt "0" ]; then
    fail "Key Vault: '${KV_NAME}' is soft-deleted, which still reserves the name. Recover it (az keyvault recover --name ${KV_NAME}) or purge it (az keyvault purge --name ${KV_NAME})."
  else
    _check_name "Key Vault" "$KV_NAME" \
      "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01" \
      "{\"name\":\"${KV_NAME}\",\"type\":\"Microsoft.KeyVault/vaults\"}" "nameAvailable"
  fi

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
      if _in_state "$REDIS_NAME"; then
        pass "Redis: '${REDIS_NAME}' is already deployed and tracked in Terraform state"
      else
        fail "Redis: '${REDIS_NAME}' already exists in this subscription — import it or delete it before applying"
      fi
    else
      warn "Redis: '${REDIS_NAME}' not present in this subscription (Azure exposes no global name check for Managed Redis)"
    fi
  fi
fi

# ── 8. Other tooling ──────────────────────────────────────────────────────────
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
