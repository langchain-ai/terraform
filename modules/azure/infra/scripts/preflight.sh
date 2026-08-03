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
