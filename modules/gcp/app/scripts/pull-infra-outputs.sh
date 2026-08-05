#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# pull-infra-outputs.sh — Reads Terraform outputs from ../infra and writes
# app/infra.auto.tfvars.json so the app module can consume them as variables.
#
# When infra has enable_smithdb = true, the SmithDB bucket, Workload Identity
# service account, metastore connection, and rollout gates are included too. The
# metastore password is not — it only lives in the smithdb-metastore Kubernetes
# secret that infra creates.
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
# Sourced directly, the `set -euo pipefail` below would leak into the caller's
# shell and leave it armed to exit on the next non-zero command, and any `exit`
# here would close that shell outright. So when sourced, hand off to a child
# process and return its status - `source` then behaves exactly like running it.
# Keep this above `set`.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

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

# SmithDB (chart 0.16+) — only meaningful when enable_smithdb = true in infra.
# The metastore password is deliberately not an output; it only ever lives in
# the smithdb-metastore Kubernetes secret that infra creates. The three rollout
# gates are carried across so both passes advance stages together.
enable_smithdb=$(terraform -chdir="$INFRA_DIR" output -raw enable_smithdb 2>/dev/null || echo "false")
smithdb_block=""
if [[ "$enable_smithdb" == "true" ]]; then
  smithdb_object_store_bucket=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_object_store_bucket)
  smithdb_gsa_email=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_gsa_email)
  smithdb_metastore_secret_name=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_secret_name)
  smithdb_taskdb_secret_name=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_taskdb_secret_name 2>/dev/null || echo "smithdb-taskdb")
  smithdb_metastore_port=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_port)
  smithdb_metastore_use_ssl=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_use_ssl)
  smithdb_ingestion_enabled=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_ingestion_enabled 2>/dev/null || echo "false")
  smithdb_migration_enabled=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_migration_enabled 2>/dev/null || echo "false")
  smithdb_query_enabled=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_query_enabled 2>/dev/null || echo "false")

  smithdb_block=$(cat <<SMITHDB
  "enable_smithdb":                true,
  "smithdb_object_store_bucket":   "$smithdb_object_store_bucket",
  "smithdb_gsa_email":             "$smithdb_gsa_email",
  "smithdb_metastore_secret_name": "$smithdb_metastore_secret_name",
  "smithdb_taskdb_secret_name":    "$smithdb_taskdb_secret_name",
  "smithdb_metastore_port":        $smithdb_metastore_port,
  "smithdb_metastore_use_ssl":     $smithdb_metastore_use_ssl,
  "smithdb_ingestion_enabled":     $smithdb_ingestion_enabled,
  "smithdb_migration_enabled":     $smithdb_migration_enabled,
  "smithdb_query_enabled":         $smithdb_query_enabled,
SMITHDB
)
fi

# ── Write infra.auto.tfvars.json ─────────────────────────────────────────────

cat > "$OUT_FILE" <<EOF
{
${smithdb_block:+$smithdb_block
}  "project_id":                   "$project_id",
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
