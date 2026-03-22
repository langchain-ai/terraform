#!/usr/bin/env bash
# pull-infra-outputs.sh — Reads Terraform outputs from ../infra and writes
# app/infra.auto.tfvars.json so the app module can consume them as variables.
#
# Usage:
#   ./app/scripts/pull-infra-outputs.sh       (from terraform/gcp/)
#   make init-app                              (same thing)
#
# Works regardless of the infra module's backend (GCS, local, TF Cloud, etc.)
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

if ! terraform -chdir="$INFRA_DIR" output -raw cluster_name &>/dev/null; then
  echo "ERROR: Cannot read infra outputs." >&2
  echo "       Is 'terraform apply' complete in $INFRA_DIR?" >&2
  echo "       Or write $APP_DIR/terraform.tfvars manually." >&2
  exit 1
fi

echo "Reading outputs from $INFRA_DIR..."

# ── Read terraform outputs ───────────────────────────────────────────────────

project_id=$(terraform -chdir="$INFRA_DIR" output -raw project_id)
region=$(terraform -chdir="$INFRA_DIR" output -raw region)
environment=$(terraform -chdir="$INFRA_DIR" output -raw environment)
name_prefix=$(terraform -chdir="$INFRA_DIR" output -raw name_prefix)
cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name)
bucket_name=$(terraform -chdir="$INFRA_DIR" output -raw storage_bucket_name)
ingress_ip=$(terraform -chdir="$INFRA_DIR" output -raw ingress_ip 2>/dev/null || echo "")
tls_certificate_source=$(terraform -chdir="$INFRA_DIR" output -raw tls_certificate_source)
langsmith_namespace=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_namespace)
postgres_source=$(terraform -chdir="$INFRA_DIR" output -raw postgres_source 2>/dev/null || echo "external")
redis_source=$(terraform -chdir="$INFRA_DIR" output -raw redis_source 2>/dev/null || echo "external")
workload_identity_annotation=$(terraform -chdir="$INFRA_DIR" output -raw workload_identity_annotation 2>/dev/null || echo "")

# ── Write infra.auto.tfvars.json ─────────────────────────────────────────────

cat > "$OUT_FILE" <<EOF
{
  "project_id":                   "$project_id",
  "region":                       "$region",
  "environment":                  "$environment",
  "name_prefix":                  "$name_prefix",
  "cluster_name":                 "$cluster_name",
  "bucket_name":                  "$bucket_name",
  "ingress_ip":                   "$ingress_ip",
  "tls_certificate_source":       "$tls_certificate_source",
  "langsmith_namespace":          "$langsmith_namespace",
  "postgres_source":              "$postgres_source",
  "redis_source":                 "$redis_source",
  "workload_identity_annotation": "$workload_identity_annotation"
}
EOF

echo ""
echo "Written: $OUT_FILE"
echo ""
cat "$OUT_FILE"
echo ""
echo "Next: review app/terraform.tfvars for app-specific settings, then: make apply-app"
