#!/usr/bin/env bash
# pull-infra-outputs.sh — Reads Terraform outputs from ../infra and writes
# app/infra.auto.tfvars.json so the app module can consume them as variables.
#
# Usage:
#   ./app/scripts/pull-infra-outputs.sh       (from terraform/azure/)
#   make init-app                              (same thing)
#
# Works regardless of the infra module's backend (Azurerm, local, TF Cloud, etc.)
# because it reads outputs via `terraform output`, not state files directly.
#
# For "bring your own infra" scenarios, skip this script and write
# app/terraform.tfvars manually with the required variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$APP_DIR/../infra"
OUT_FILE="$APP_DIR/infra.auto.tfvars.json"

# ── Verify infra state is available ──────────────────────────────────────────

if ! terraform -chdir="$INFRA_DIR" output -raw aks_cluster_name &>/dev/null; then
  echo "ERROR: Cannot read infra outputs." >&2
  echo "       Is 'terraform apply' complete in $INFRA_DIR?" >&2
  echo "       Or write $APP_DIR/terraform.tfvars manually." >&2
  exit 1
fi

echo "Reading outputs from $INFRA_DIR..."

# ── Read terraform outputs ───────────────────────────────────────────────────

cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw aks_cluster_name)
resource_group_name=$(terraform -chdir="$INFRA_DIR" output -raw resource_group_name)
keyvault_name=$(terraform -chdir="$INFRA_DIR" output -raw keyvault_name)
storage_account_name=$(terraform -chdir="$INFRA_DIR" output -raw storage_account_name)
storage_container_name=$(terraform -chdir="$INFRA_DIR" output -raw storage_container_name)
workload_identity_client_id=$(terraform -chdir="$INFRA_DIR" output -raw storage_account_k8s_managed_identity_client_id)
langsmith_namespace=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_namespace)

# TLS and ingress config
tls_certificate_source=$(terraform -chdir="$INFRA_DIR" output -raw tls_certificate_source 2>/dev/null || echo "none")
ingress_controller=$(terraform -chdir="$INFRA_DIR" output -raw ingress_controller 2>/dev/null || echo "nginx")
dns_label=$(terraform -chdir="$INFRA_DIR" output -raw dns_label 2>/dev/null || echo "")

# Service sources
postgres_source=$(terraform -chdir="$INFRA_DIR" output -raw postgres_source 2>/dev/null || echo "external")
redis_source=$(terraform -chdir="$INFRA_DIR" output -raw redis_source 2>/dev/null || echo "external")

# Subscription ID from Azure CLI (not always in terraform outputs)
subscription_id=$(az account show --query id -o tsv 2>/dev/null) || {
  echo "ERROR: Could not read subscription ID. Are you logged into Azure CLI?" >&2
  echo "       Run: az login" >&2
  exit 1
}

# ── Write infra.auto.tfvars.json ─────────────────────────────────────────────

cat > "$OUT_FILE" <<EOF
{
  "subscription_id": "$subscription_id",
  "resource_group_name": "$resource_group_name",
  "cluster_name": "$cluster_name",
  "keyvault_name": "$keyvault_name",
  "storage_account_name": "$storage_account_name",
  "storage_container_name": "$storage_container_name",
  "workload_identity_client_id": "$workload_identity_client_id",
  "langsmith_namespace": "$langsmith_namespace",
  "tls_certificate_source": "$tls_certificate_source",
  "ingress_controller": "$ingress_controller",
  "dns_label": "$dns_label",
  "postgres_source": "$postgres_source",
  "redis_source": "$redis_source"
}
EOF

echo ""
echo "Written: $OUT_FILE"
echo ""
cat "$OUT_FILE"
echo ""
echo "Next: review app/terraform.tfvars for app-specific settings, then: make apply-app"
