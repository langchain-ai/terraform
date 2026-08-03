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
#   5. terraform.tfvars exists with required fields populated
#   6. On the attach path, the existing cluster's nodes can hold ClickHouse
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
PRINCIPAL_ID=""
if [ -n "${ARM_CLIENT_ID:-}" ]; then
  PRINCIPAL_KIND="service principal from ARM_CLIENT_ID"
  PRINCIPAL_ID=$(az ad sp show --id "$ARM_CLIENT_ID" --query id -o tsv 2>/dev/null || echo "")
  warn "ARM_CLIENT_ID is set — Terraform authenticates as that service principal, not as your az login"
elif [ "${ARM_USE_MSI:-}" = "true" ] || [ "${ARM_USE_OIDC:-}" = "true" ]; then
  PRINCIPAL_KIND="managed identity or OIDC federation"
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
# Looking for the role names "Owner" and "User Access Administrator" does not
# decide it, in either direction: a custom role can carry the action, an ABAC
# condition can restrict which roles a delegate may assign, a deny assignment
# overrides every grant including Owner, PIM-eligible roles grant nothing until
# activated, and a grant inherited from a management group or held through a
# group carries the same weight as a direct one. So read the role definitions
# behind the assignments and the deny assignments that override them.
echo ""
echo "── RBAC Roles ────────────────────────────────────────"

RBAC_TMP=$(mktemp -d)
trap 'rm -rf "$RBAC_TMP"' EXIT

if [ -z "$PRINCIPAL_ID" ] || [ -z "$SUB_ID_CHECK" ]; then
  warn "Skipping RBAC check — no principal object ID to query"
else
  # Two queries, because neither direction is a superset of the other. ARM's
  # atScope() filter returns assignments at and above a scope, so the first call
  # is the only one that reports a grant inherited from a management group; --all
  # drops the scope filter entirely, so it is the only one that reports a grant
  # made below the subscription on a resource group. --include-inherited is what
  # keeps the above-subscription results in the first call, and has no effect on
  # the second (--all sends no scope for anything to be inherited from).
  # --include-groups makes the server filter transitive through group membership,
  # and --assignee-object-id skips the Graph lookup --assignee would need.
  ASSIGNMENTS_READ=1
  az role assignment list \
    --scope "/subscriptions/${SUB_ID_CHECK}" \
    --include-inherited \
    --assignee-object-id "$PRINCIPAL_ID" \
    --include-groups \
    -o json > "${RBAC_TMP}/at-and-above.json" 2>/dev/null || ASSIGNMENTS_READ=0
  az role assignment list \
    --all \
    --assignee-object-id "$PRINCIPAL_ID" \
    --include-groups \
    -o json > "${RBAC_TMP}/at-and-below.json" 2>/dev/null || ASSIGNMENTS_READ=0

  # Merged into one list so the evaluation below reads a single file. The
  # subscription scope itself answers both queries, hence the dedupe.
  python3 - "${RBAC_TMP}/at-and-above.json" "${RBAC_TMP}/at-and-below.json" \
    > "${RBAC_TMP}/assignments.json" <<'PY' || ASSIGNMENTS_READ=0
import json, sys

seen, merged = set(), []
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            entries = json.load(fh) or []
    except (OSError, ValueError):
        continue
    for entry in entries:
        key = entry.get("id") or json.dumps(entry, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        merged.append(entry)
print(json.dumps(merged))
PY

  # Eligible-but-inactive PIM roles are absent from the list above, which is why
  # a deployer who "has Owner" can still be denied. Fetching them here turns the
  # failure message from "you lack the role" into "activate the role you hold".
  # asTarget() reports eligibilities for the calling identity only, so this is
  # empty (harmlessly) when Terraform runs as a service principal.
  az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUB_ID_CHECK}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&\$filter=asTarget()" \
    -o json > "${RBAC_TMP}/eligibilities.json" 2>/dev/null || echo "{}" > "${RBAC_TMP}/eligibilities.json"

  # atScope() returns deny assignments at or above the subscription, which is
  # where landing-zone blueprints and managed applications put them. Two kinds
  # stay invisible and surface as a 403 at apply: one created directly on a
  # resource group that does not exist yet, and one that names a group this
  # principal belongs to rather than the principal itself (the matching below
  # reads principal IDs, and resolving group membership needs a directory read
  # this account may not have).
  az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUB_ID_CHECK}/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01&\$filter=atScope()" \
    -o json > "${RBAC_TMP}/deny.json" 2>/dev/null || DENY_READ=0

  # A failed read is not an empty result. Reporting "no roles found" when the
  # query itself was refused would send the operator to their tenant admin for
  # a grant they may already hold, so say which read failed and stop instead.
  if [ "$ASSIGNMENTS_READ" -eq 0 ]; then
    warn "Could not list role assignments for this principal — skipping the RBAC verdict rather than reading a failed query as \"no access\""
  fi
  if [ "${DENY_READ:-1}" -eq 0 ]; then
    echo "{}" > "${RBAC_TMP}/deny.json"
    warn "Could not read deny assignments (needs Microsoft.Authorization/denyAssignments/read). One that blocks roleAssignments/write would be invisible here and would override every role grant below."
  fi

  # Resolve every role behind those assignments and eligibilities to its actual
  # permission set. One JSON object per line so each az call can append without
  # the shell having to assemble an array.
  ROLE_NAMES=$(python3 - "${RBAC_TMP}/assignments.json" "${RBAC_TMP}/eligibilities.json" <<'PY' || echo ""
import json, sys

names = set()
try:
    with open(sys.argv[1]) as fh:
        for a in json.load(fh) or []:
            if a.get("roleDefinitionName"):
                names.add(a["roleDefinitionName"])
except (OSError, ValueError, AttributeError):
    pass
try:
    with open(sys.argv[2]) as fh:
        for e in (json.load(fh) or {}).get("value") or []:
            expanded = (e.get("properties") or {}).get("expandedProperties") or {}
            name = (expanded.get("roleDefinition") or {}).get("displayName")
            if name:
                names.add(name)
except (OSError, ValueError, AttributeError):
    pass
print("\n".join(sorted(names)))
PY
  )

  : > "${RBAC_TMP}/roledefs.jsonl"
  while IFS= read -r ROLE_NAME; do
    [ -n "$ROLE_NAME" ] || continue
    { az role definition list --name "$ROLE_NAME" \
        --query "[0].{roleName:roleName,permissions:permissions}" -o json 2>/dev/null | tr -d '\n'; } \
      >> "${RBAC_TMP}/roledefs.jsonl" || true
    echo "" >> "${RBAC_TMP}/roledefs.jsonl"
  done <<EOF
$ROLE_NAMES
EOF

  # The evaluation is one pass over four files so that the shell only renders
  # verdicts. Each line it prints is "<severity> <message>".
  RBAC_VERDICT=$(python3 - \
    "${RBAC_TMP}/assignments.json" \
    "${RBAC_TMP}/eligibilities.json" \
    "${RBAC_TMP}/deny.json" \
    "${RBAC_TMP}/roledefs.jsonl" \
    "$PRINCIPAL_ID" \
    "$SUB_ID_CHECK" \
    "$ASSIGNMENTS_READ" <<'PY' || echo "warn RBAC evaluation failed to run — falling back to no verdict"
import fnmatch, json, sys

assign_path, elig_path, deny_path, defs_path, principal_id, sub_id, read_ok = sys.argv[1:8]

# The assignment list could not be read, so there is nothing to render. The
# shell has already warned; anything printed here would be a verdict built on
# an empty file.
if read_ok != "1":
    sys.exit(0)

# Microsoft.Authorization/roleAssignments/write is the action the modules need
# and the one the 403 names. The storage write is a proxy for ordinary resource
# creation: every deployment path builds a storage account.
ROLE_WRITE = "microsoft.authorization/roleassignments/write"
RES_WRITE = "microsoft.storage/storageaccounts/write"

# Assigned to the modules by name, so an ABAC condition that omits any of them
# breaks apply even though roleAssignments/write is granted.
ASSIGNED_ROLES = (
    "Storage Blob Data Contributor, Key Vault Secrets Officer, "
    "Key Vault Secrets User, DNS Zone Contributor, "
    "Virtual Machine Administrator Login, Reader, Contributor, "
    "Network Contributor"
)

ALL_PRINCIPALS = "00000000-0000-0000-0000-000000000000"
MG_PREFIX = "/providers/microsoft.management/managementgroups/"
principal_id = principal_id.lower()


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


role_perms = {}
try:
    with open(defs_path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line == "null":
                continue
            try:
                definition = json.loads(line)
            except ValueError:
                continue
            if definition and definition.get("roleName"):
                role_perms[definition["roleName"]] = definition.get("permissions") or []
except OSError:
    pass

assignments = load(assign_path, []) or []
eligibilities = (load(elig_path, {}) or {}).get("value") or []
deny_assignments = (load(deny_path, {}) or {}).get("value") or []


def matches(action, patterns):
    # Azure action patterns wildcard with *, which fnmatch spans across / — the
    # same way ARM reads Microsoft.Authorization/* as covering a nested action.
    return any(fnmatch.fnmatch(action, (p or "").lower()) for p in patterns or [])


def grants(role_name, action):
    for perm in role_perms.get(role_name, []):
        if matches(action, perm.get("actions")) and not matches(action, perm.get("notActions")):
            return True
    return False


def covers_deployment(scope):
    scope = (scope or "").lower()
    # --include-inherited only returns management groups above this
    # subscription, so a management group scope here is always an ancestor.
    return scope in ("/", "/subscriptions/%s" % sub_id.lower()) or scope.startswith(MG_PREFIX)


out = []
qualifying = [a for a in assignments if grants(a.get("roleDefinitionName"), ROLE_WRITE)]
broad = [a for a in qualifying if covers_deployment(a.get("scope"))]
narrow = [a for a in qualifying if not covers_deployment(a.get("scope"))]

if broad:
    winner = broad[0]
    out.append("pass roleAssignments/write granted by %s at %s"
               % (winner.get("roleDefinitionName"), winner.get("scope")))
elif narrow:
    scopes = ", ".join(sorted({a.get("scope") or "?" for a in narrow}))
    out.append("warn roleAssignments/write is granted only below the subscription (%s). "
               "Anything the deployment creates outside that scope will 403 — confirm every "
               "resource lands inside it." % scopes)
else:
    eligible = []
    for instance in eligibilities:
        props = instance.get("properties") or {}
        expanded = (props.get("expandedProperties") or {}).get("roleDefinition") or {}
        name = expanded.get("displayName")
        if name and grants(name, ROLE_WRITE):
            eligible.append("%s at %s" % (name, props.get("scope") or "?"))
    if eligible:
        out.append("fail roleAssignments/write is not active, but PIM holds it as eligible: %s. "
                   "Activate it (portal: PIM -> My roles -> Activate), then re-run this script. "
                   "Activation is time-bound, so activate for longer than the apply will take."
                   % "; ".join(sorted(set(eligible))))
    elif not assignments:
        out.append("fail No role assignments found for this principal at any scope in the "
                   "subscription. Either it holds nothing here, or the grant is PIM-eligible and "
                   "this account cannot read its own eligibilities.")
    else:
        held = ", ".join(sorted({a.get("roleDefinitionName") or "?" for a in assignments}))
        out.append("fail No role held by this principal grants "
                   "Microsoft.Authorization/roleAssignments/write, which all eight role "
                   "assignments in the Azure modules need. Roles found: %s." % held)

# A role whose definition could not be read carries no permissions here, which
# reads exactly like a role that grants nothing. Say which ones, so a verdict
# resting on an unreadable custom role is not mistaken for a settled one.
if not broad:
    unresolved = sorted({a.get("roleDefinitionName") or "(unnamed role)"
                         for a in assignments
                         if (a.get("roleDefinitionName") or "") not in role_perms})
    if unresolved:
        out.append("warn Could not read the permissions behind these roles held by this "
                   "principal: %s. They count as granting nothing above, so if one of them is a "
                   "custom role carrying roleAssignments/write, the verdict is wrong."
                   % ", ".join(unresolved))

for assignment in broad + narrow:
    if assignment.get("condition"):
        out.append("warn %s at %s carries an ABAC condition, so roleAssignments/write is "
                   "restricted to the roles that condition allows. The modules assign: %s. "
                   "Condition: %s"
                   % (assignment.get("roleDefinitionName"), assignment.get("scope"),
                      ASSIGNED_ROLES, " ".join(assignment["condition"].split())[:240]))

for entry in deny_assignments:
    props = entry.get("properties") or {}
    principals = [(p.get("id") or "").lower() for p in props.get("principals") or []]
    excluded = [(p.get("id") or "").lower() for p in props.get("excludePrincipals") or []]
    if principal_id not in principals and ALL_PRINCIPALS not in principals:
        continue
    if principal_id in excluded:
        continue
    blocked = any(
        matches(ROLE_WRITE, perm.get("actions")) and not matches(ROLE_WRITE, perm.get("notActions"))
        for perm in props.get("permissions") or []
    )
    if not blocked:
        continue
    name = props.get("denyAssignmentName") or entry.get("name") or "?"
    if excluded:
        out.append("warn Deny assignment \"%s\" at %s denies roleAssignments/write. Its exclusion "
                   "list may exempt this principal through a group this script cannot read — if "
                   "not, apply will 403 no matter which roles are held."
                   % (name, props.get("scope") or "?"))
    else:
        out.append("fail Deny assignment \"%s\" at %s denies roleAssignments/write. Deny "
                   "assignments override every role assignment including Owner, so no role grant "
                   "will fix this: it has to be removed or this principal added to its exclusion "
                   "list." % (name, props.get("scope") or "?"))

if any(grants(a.get("roleDefinitionName"), RES_WRITE) and covers_deployment(a.get("scope"))
       for a in assignments):
    out.append("pass Resource creation granted at subscription scope")
else:
    out.append("warn No subscription-scope grant for creating resources (checked against "
               "Microsoft.Storage/storageAccounts/write). A resource-group-scoped grant is fine "
               "if the resource group already exists and the deployment stays inside it.")

print("\n".join(out))
PY
  )

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

# ── 7. Existing-cluster node capacity ─────────────────────────────────────────
# Attach path only. Terraform validates subnet space and Kubernetes version on an
# existing cluster, but nothing checks whether a node in it is big enough to hold
# the largest pod LangSmith schedules. ClickHouse is that pod, it is a single
# replica, and Kubernetes schedules a pod onto one node — so cluster-wide totals
# do not answer the question and neither does `az vm list-sizes`, which reports
# capacity. Allocatable is capacity minus kube-reserved, system-reserved, and the
# eviction threshold, and only the live node object carries it: a Standard_D4s_v3
# advertises 4 vCPU / 16 GiB and allocates 3860m / 14.3 GiB.
#
# This tests whether the pod can ever fit, not whether it fits right now. A node
# large enough but currently full is the autoscaler's problem; a node too small
# is unfixable without adding a pool, which is the failure worth catching early.
echo ""
echo "── Existing Cluster Capacity ─────────────────────────"

# terraform.tfvars carries quoted strings and bare booleans, so read the raw
# right-hand side rather than assuming either form.
_tfvar() {
  local raw
  [ -f "${TFVARS:-}" ] || return 0
  raw=$(grep -E "^[[:space:]]*${1}[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1) || return 0
  raw=${raw#*=}
  raw=${raw%%#*}
  printf '%s' "$raw" | tr -d '"' | tr -d '[:space:]'
}

# Every value below comes from a file the operator edits by hand, so each one is
# matched against an expected literal or charset before it is used. A value that
# does not match skips the check instead of being passed along.
CREATE_CLUSTER=$(_tfvar create_cluster)
POOLS_MANAGED=$(_tfvar existing_cluster_node_pools_managed)
CH_SOURCE=$(_tfvar clickhouse_source)
SIZING=$(_tfvar sizing_profile)
CLUSTER_NAME=$(_tfvar existing_cluster_name)

# The ClickHouse request per sizing overlay, read off the files in
# helm/values/examples/. With no overlay the chart's own default applies.
case "$SIZING" in
  minimum)          REQ_CPU_M=1000; REQ_MEM_MI=2048;  REQ_LABEL="minimum" ;;
  dev)              REQ_CPU_M=2000; REQ_MEM_MI=8192;  REQ_LABEL="dev" ;;
  production)       REQ_CPU_M=2000; REQ_MEM_MI=8192;  REQ_LABEL="production" ;;
  production-large) REQ_CPU_M=4000; REQ_MEM_MI=16384; REQ_LABEL="production-large" ;;
  *)                REQ_CPU_M=3500; REQ_MEM_MI=12288; REQ_LABEL="chart default (no sizing_profile set)" ;;
esac

if [ "$CREATE_CLUSTER" != "false" ]; then
  echo "  ○ Skipped: create_cluster is not false, so Terraform builds the pools itself"
elif [ "$CH_SOURCE" = "external" ]; then
  echo "  ○ Skipped: clickhouse_source = external, nothing to schedule in-cluster"
elif [ "$POOLS_MANAGED" = "true" ]; then
  echo "  ○ Skipped: existing_cluster_node_pools_managed = true, Terraform adds the large pool"
elif ! command -v kubectl &>/dev/null; then
  warn "kubectl not found — cannot read node allocatable, skipping capacity check"
elif ! [[ "$CLUSTER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$ ]]; then
  warn "existing_cluster_name is empty or not a valid AKS name — skipping capacity check"
else
  # Read the target before reading the cluster. A kubeconfig pointed somewhere
  # else would return another cluster's nodes and a confidently wrong verdict.
  KUBE_CTX=$(kubectl config current-context 2>/dev/null || echo "")
  if [ -z "$KUBE_CTX" ]; then
    warn "No kubectl context set — skipping capacity check. Run: az aks get-credentials --resource-group <rg> --name ${CLUSTER_NAME}"
  elif [ "$KUBE_CTX" != "$CLUSTER_NAME" ]; then
    warn "kubectl context is \"${KUBE_CTX}\" but existing_cluster_name is \"${CLUSTER_NAME}\" — skipping rather than measuring the wrong cluster"
  else
    NODES_JSON=$(kubectl get nodes -o json --request-timeout=10s 2>/dev/null || echo "")
    if [ -z "$NODES_JSON" ]; then
      warn "Could not read nodes from \"${KUBE_CTX}\" — skipping capacity check"
    else
      VERDICT=$(printf '%s' "$NODES_JSON" | python3 -c '
import json, sys

req_cpu, req_mem = int(sys.argv[1]), int(sys.argv[2])

def cpu_m(v):
    return int(v[:-1]) if v.endswith("m") else int(float(v) * 1000)

# Suffixes kubelet emits for allocatable memory. Anything else is a parse
# failure, not a value to guess at.
UNITS = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024}

def mem_mi(v):
    for suffix, factor in UNITS.items():
        if v.endswith(suffix):
            return int(float(v[: -len(suffix)]) * factor)
    return int(v) // (1024 * 1024)

try:
    nodes = json.load(sys.stdin).get("items", [])
except (ValueError, AttributeError):
    print("ERR unreadable node JSON")
    sys.exit(0)

best = None
for n in nodes:
    if n.get("spec", {}).get("unschedulable"):
        continue
    ready = any(c.get("type") == "Ready" and c.get("status") == "True"
                for c in n.get("status", {}).get("conditions", []))
    if not ready:
        continue
    alloc = n.get("status", {}).get("allocatable", {})
    try:
        c, m = cpu_m(alloc["cpu"]), mem_mi(alloc["memory"])
    except (KeyError, ValueError):
        continue
    # Rank by the tighter of the two dimensions so the reported node is the one
    # that comes closest to holding the pod, not the widest on one axis.
    score = min(c / req_cpu, m / req_mem)
    if best is None or score > best[0]:
        best = (score, c, m)

if best is None:
    print("ERR no schedulable Ready nodes found")
else:
    _, c, m = best
    print("%s %d %d" % ("FIT" if c >= req_cpu and m >= req_mem else "NOFIT", c, m))
' "$REQ_CPU_M" "$REQ_MEM_MI")

      read -r VERDICT_KIND BEST_CPU_M BEST_MEM_MI <<<"$VERDICT"
      case "${VERDICT_KIND:-ERR}" in
        FIT)
          pass "ClickHouse (${REQ_LABEL}: ${REQ_CPU_M}m / ${REQ_MEM_MI}Mi) fits — largest node allocates ${BEST_CPU_M}m / ${BEST_MEM_MI}Mi"
          ;;
        NOFIT)
          fail "No node can hold ClickHouse. Largest allocates ${BEST_CPU_M}m / ${BEST_MEM_MI}Mi; the ${REQ_LABEL} profile requests ${REQ_CPU_M}m / ${REQ_MEM_MI}Mi.
      Add a pool that fits it (az aks nodepool add --node-vm-size Standard_D16s_v3), or set
      existing_cluster_node_pools_managed = true to let Terraform add one, or drop sizing_profile
      to a smaller overlay. Autoscaling does not help: no count of nodes this size holds one pod."
          ;;
        *)
          warn "Capacity check inconclusive: ${VERDICT#ERR }"
          ;;
      esac
    fi
  fi
fi

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
