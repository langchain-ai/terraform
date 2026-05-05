#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# preflight.sh — Pre-Terraform GCP permission and prerequisite check.
#
# Run this BEFORE 'terraform apply' to verify that your GCP credentials
# have the permissions needed to provision all LangSmith infrastructure.
#
# Usage (from terraform/gcp/):
#   make preflight                              # read-only checks
#   make preflight -- --domain langsmith.example.com  # + Cloud DNS zone check
#   make preflight -- --create-test-resources  # + create/destroy a real GCS bucket
#   make preflight -- -y                       # non-interactive
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Args ──────────────────────────────────────────────────────────────────────
NON_INTERACTIVE=false
CREATE_TEST_RESOURCES=false
DOMAIN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--yes)                NON_INTERACTIVE=true; shift ;;
    --create-test-resources) CREATE_TEST_RESOURCES=true; shift ;;
    --domain)
      [[ $# -lt 2 ]] && { printf "ERROR: --domain requires an argument\n" >&2; exit 1; }
      DOMAIN="$2"; shift 2 ;;
    *)
      printf "Unknown option: %s\n" "$1"
      printf "Usage: %s [-y] [--create-test-resources] [--domain <domain>]\n" "$0"
      exit 1 ;;
  esac
done

[[ "${CI:-false}" == "true" ]] && NON_INTERACTIVE=true

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf "${BLUE}[INFO]${NC}    %s\n" "$1"; }
success() { printf "${GREEN}[OK]${NC}      %s\n" "$1"; }
warning() { printf "${YELLOW}[WARN]${NC}    %s\n" "$1"; }
error()   { printf "${RED}[ERROR]${NC}   %s\n" "$1" >&2; }

# ── Required tools ────────────────────────────────────────────────────────────
REQUIRED_TOOLS=(gcloud terraform kubectl helm)
MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING+=("$tool")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "Missing required tools: ${MISSING[*]}"
  info "Install guides:"
  info "  gcloud    → https://cloud.google.com/sdk/docs/install"
  info "  terraform → https://developer.hashicorp.com/terraform/install"
  info "  kubectl   → https://kubernetes.io/docs/tasks/tools/"
  info "  helm      → https://helm.sh/docs/intro/install/"
  exit 1
fi

# Minimum gcloud SDK version (450 = late 2023; required for GKE Autopilot APIs)
SDK_VERSION=$(gcloud version 2>/dev/null | awk '/Google Cloud SDK/{print $NF}' | cut -d. -f1 || echo "0")
if [[ -n "$SDK_VERSION" && "$SDK_VERSION" =~ ^[0-9]+$ && "$SDK_VERSION" -lt 450 ]]; then
  warning "gcloud SDK version may be outdated (found ${SDK_VERSION}.x, recommend 450+). Run: gcloud components update"
fi

TF_VERSION=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 \
  || terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' || echo "")

printf "\n"
info "=== LangSmith GCP Preflight (Pass 1 — pre-Terraform) ==="
info "Default mode: READ-ONLY. Use --create-test-resources to also test resource creation."
printf "\n"

success "Required tools: $(printf '%s ' "${REQUIRED_TOOLS[@]}")"
[[ -n "${TF_VERSION:-}" ]] && info "Terraform version: $TF_VERSION"

# ── terraform.tfvars check ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="$SCRIPT_DIR/../terraform.tfvars"

if [[ ! -f "$TFVARS" ]]; then
  error "terraform.tfvars not found at $TFVARS"
  info "Quick start:"
  info "  cp terraform.tfvars.minimum terraform.tfvars    # minimum profile (cost parking, CI)"
  info "  cp terraform.tfvars.example terraform.tfvars    # full reference"
  exit 1
fi
success "terraform.tfvars found"

# ── Parse key values from tfvars ──────────────────────────────────────────────
_tfvar() {
  awk -F= "/^[[:space:]]*${1}[[:space:]]*=/{gsub(/[ \"']/, \"\", \$2); print \$2; exit}" "$TFVARS" 2>/dev/null || true
}

PROJECT_ID=$(_tfvar "project_id")
REGION=$(_tfvar "region")
REGION="${REGION:-us-west2}"
POSTGRES_SOURCE=$(_tfvar "postgres_source")
REDIS_SOURCE=$(_tfvar "redis_source")
ENABLE_SECRET_MANAGER=$(_tfvar "enable_secret_manager_module")
ENABLE_DNS=$(_tfvar "enable_dns_module")
TLS_SOURCE=$(_tfvar "tls_certificate_source")

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "your-gcp-project-id" ]]; then
  error "project_id not set in terraform.tfvars — edit it before running preflight."
  exit 1
fi

info "Project : $PROJECT_ID"
info "Region  : $REGION"

# ── Authentication ────────────────────────────────────────────────────────────
printf "\n"
info "Checking gcloud authentication..."
if ! gcloud auth print-access-token &>/dev/null; then
  error "Not authenticated. Run: gcloud auth application-default login"
  exit 1
fi
success "gcloud authenticated"

# Active project alignment
ACTIVE_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ "$ACTIVE_PROJECT" != "$PROJECT_ID" ]]; then
  warning "gcloud active project ('$ACTIVE_PROJECT') differs from terraform project_id ('$PROJECT_ID')."
  warning "  Run: gcloud config set project $PROJECT_ID"
fi

# Project existence check
if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
  error "Project '$PROJECT_ID' not found or you don't have resourcemanager.projects.get permission."
  exit 1
fi
success "Project '$PROJECT_ID' accessible"

# ── Billing check ─────────────────────────────────────────────────────────────
info "Checking billing status..."
BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT_ID" \
  --format="value(billingEnabled)" 2>/dev/null || echo "")
if [[ "$BILLING_ENABLED" == "False" ]]; then
  error "Billing is not enabled on project '$PROJECT_ID'. Enable billing before applying Terraform."
  exit 1
elif [[ -z "$BILLING_ENABLED" ]]; then
  warning "Could not verify billing status (may lack billing.resourceAssociations.list). Verify manually."
else
  success "Billing enabled"
fi

# ── Required APIs check ───────────────────────────────────────────────────────
printf "\n"
info "Checking required APIs in project '$PROJECT_ID'..."
info "(Terraform will enable any not-yet-enabled APIs — WARNs here are fine)"

APIS=(
  "container.googleapis.com:GKE"
  "compute.googleapis.com:Compute Engine"
  "sqladmin.googleapis.com:Cloud SQL"
  "redis.googleapis.com:Memorystore"
  "storage.googleapis.com:Cloud Storage"
  "iam.googleapis.com:IAM"
  "secretmanager.googleapis.com:Secret Manager"
  "servicenetworking.googleapis.com:Service Networking (VPC peering)"
  "cloudresourcemanager.googleapis.com:Resource Manager"
  "certificatemanager.googleapis.com:Certificate Manager"
)

APIS_MISSING=0
for entry in "${APIS[@]}"; do
  api="${entry%%:*}"
  label="${entry#*:}"
  enabled=$(gcloud services list --enabled --project "$PROJECT_ID" \
    --filter="name:$api" --format="value(name)" 2>/dev/null || true)
  if [[ -z "$enabled" ]]; then
    warning "API not yet enabled: $api ($label) — Terraform will enable it"
    APIS_MISSING=$((APIS_MISSING + 1))
  fi
done

if [[ "$APIS_MISSING" -eq 0 ]]; then
  success "All required APIs already enabled"
else
  info "$APIS_MISSING API(s) not yet enabled — Terraform will enable them on first apply (~2 min)"
fi

# ── IAM permission checks ─────────────────────────────────────────────────────
printf "\n"
info "Checking IAM permissions..."
info "(Uses gcloud projects test-iam-permissions — may not reflect organization policy constraints)"

# Core permissions always required
CORE_PERMISSIONS=(
  "container.clusters.create"
  "container.clusters.delete"
  "compute.networks.create"
  "compute.subnetworks.create"
  "compute.routers.create"
  "iam.serviceAccounts.create"
  "iam.serviceAccounts.setIamPolicy"
  "storage.buckets.create"
  "storage.buckets.setIamPolicy"
  "resourcemanager.projects.getIamPolicy"
  "resourcemanager.projects.setIamPolicy"
  "serviceusage.services.enable"
)

# Conditional permissions based on tfvars
CONDITIONAL_PERMISSIONS=()
if [[ "$POSTGRES_SOURCE" == "external" ]]; then
  CONDITIONAL_PERMISSIONS+=(
    "cloudsql.instances.create"
    "cloudsql.databases.create"
    "servicenetworking.services.addPeering"
    "compute.globalAddresses.create"
  )
fi
if [[ "$REDIS_SOURCE" == "external" ]]; then
  CONDITIONAL_PERMISSIONS+=("redis.instances.create")
fi
if [[ "$ENABLE_SECRET_MANAGER" == "true" ]]; then
  CONDITIONAL_PERMISSIONS+=("secretmanager.secrets.create")
fi
if [[ "$ENABLE_DNS" == "true" ]]; then
  CONDITIONAL_PERMISSIONS+=("dns.managedZones.create" "dns.resourceRecordSets.create")
fi
if [[ "$TLS_SOURCE" == "letsencrypt" ]]; then
  CONDITIONAL_PERMISSIONS+=("certificatemanager.certs.create")
fi

ALL_PERMISSIONS=("${CORE_PERMISSIONS[@]}" "${CONDITIONAL_PERMISSIONS[@]}")

# Test permissions in batches of 20 (API limit)
DENIED=()
i=0
while [[ $i -lt ${#ALL_PERMISSIONS[@]} ]]; do
  batch=("${ALL_PERMISSIONS[@]:$i:20}")
  batch_args=$(printf '"%s" ' "${batch[@]}")

  result=$(gcloud projects test-iam-permissions "$PROJECT_ID" \
    --permissions="${batch_args// /,}" \
    --format="value(permissions)" 2>/dev/null || true)

  for perm in "${batch[@]}"; do
    if ! echo "$result" | grep -qF "$perm"; then
      DENIED+=("$perm")
    fi
  done

  i=$((i + 20))
done

if [[ ${#DENIED[@]} -eq 0 ]]; then
  success "IAM permissions: all required permissions granted"
else
  error "Missing IAM permissions (${#DENIED[@]} total):"
  for perm in "${DENIED[@]}"; do
    error "  ✗ $perm"
  done
  info ""
  info "Your account needs these permissions added via IAM before running terraform apply."
  info "Common roles that grant them:"
  info "  roles/owner                  — full access (not recommended for production)"
  info "  roles/editor + roles/iam.serviceAccountAdmin + roles/iam.securityAdmin"
  info "  Custom role with the specific permissions above"
fi

warning "test-iam-permissions does not check Organization Policy constraints (deny policies)."
warning "If terraform apply fails with 'constraint violated', check your org policies."

# ── Quota check ───────────────────────────────────────────────────────────────
printf "\n"
info "Checking key service quotas in region '$REGION'..."

# CPUs in region (need at least 4 per e2-standard-4 node)
CPU_QUOTA=$(gcloud compute regions describe "$REGION" --project "$PROJECT_ID" \
  --format="value(quotas[name=CPUS].limit)" 2>/dev/null | head -1 || echo "")
CPU_USED=$(gcloud compute regions describe "$REGION" --project "$PROJECT_ID" \
  --format="value(quotas[name=CPUS].usage)" 2>/dev/null | head -1 || echo "")

if [[ -n "$CPU_QUOTA" && -n "$CPU_USED" ]]; then
  CPU_AVAILABLE=$(echo "$CPU_QUOTA - $CPU_USED" | bc 2>/dev/null || echo "?")
  if [[ "$CPU_AVAILABLE" =~ ^[0-9]+$ && "$CPU_AVAILABLE" -lt 8 ]]; then
    warning "Low CPU quota in $REGION: ${CPU_AVAILABLE} available (need at least 8 for a 2-node e2-standard-4 cluster)"
  else
    success "CPU quota: ${CPU_AVAILABLE:-?} available in $REGION"
  fi
else
  warning "Could not read CPU quota — verify manually in: Console → IAM → Quotas"
fi

# ── Cloud DNS zone check ──────────────────────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
  printf "\n"
  info "Checking for Cloud DNS zone matching: $DOMAIN"
  ZONE_APEX=$(echo "$DOMAIN" | sed -E 's/^[^.]*\.(.+)$/\1/')

  MATCHING_ZONE=$(gcloud dns managed-zones list --project "$PROJECT_ID" \
    --filter="dnsName:${ZONE_APEX}." --format="value(name)" 2>/dev/null | head -1 || echo "")

  if [[ -n "$MATCHING_ZONE" ]]; then
    success "Cloud DNS zone found: $MATCHING_ZONE (covers $ZONE_APEX)"
    NS_RECORDS=$(gcloud dns managed-zones describe "$MATCHING_ZONE" --project "$PROJECT_ID" \
      --format="value(nameServers[0])" 2>/dev/null | head -4 || true)
    [[ -n "$NS_RECORDS" ]] && info "Name servers: $NS_RECORDS"
  else
    warning "No Cloud DNS zone found for '$ZONE_APEX'"
    warning "  If using enable_dns_module = true with dns_create_zone = true, Terraform will create it."
    warning "  After apply, delegate the zone by pointing your registrar NS records to the output name_servers."
  fi
fi

# ── Read-only checks complete ─────────────────────────────────────────────────
printf "\n"
if [[ "$CREATE_TEST_RESOURCES" == "false" ]]; then
  info "Read-only checks passed. Run with --create-test-resources to also validate resource creation."
  success "Preflight complete!"
  exit 0
fi

# ── Resource creation test (optional) ────────────────────────────────────────
if [[ "$NON_INTERACTIVE" == "false" ]]; then
  printf "\n"
  warning "This will create and immediately delete a real GCS bucket to verify creation permissions."
  read -p "Continue? (y/n): " -n 1 -r; printf "\n"
  [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Cancelled."; exit 0; }
fi

TEST_BUCKET="langsmith-preflight-test-$$"

cleanup_bucket() {
  [[ -n "${TEST_BUCKET:-}" ]] && \
    gsutil rb "gs://$TEST_BUCKET" 2>/dev/null || true
}
trap cleanup_bucket EXIT

info "Creating test GCS bucket: gs://$TEST_BUCKET ..."
if gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://$TEST_BUCKET" 2>/dev/null; then
  success "GCS bucket created — storage.buckets.create confirmed"
  gsutil rb "gs://$TEST_BUCKET" 2>/dev/null && TEST_BUCKET=""
  success "GCS bucket deleted — cleanup OK"
else
  error "Failed to create GCS bucket — verify storage.buckets.create permission."
  exit 1
fi

printf "\n"
success "Preflight complete! All checks passed. You are ready to run 'terraform apply'."
