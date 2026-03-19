#!/usr/bin/env bash
# pull-infra-outputs.sh — Reads Terraform outputs from ../infra and writes
# app/infra.auto.tfvars.json so the app module can consume them as variables.
#
# Usage:
#   ./app/scripts/pull-infra-outputs.sh       (from terraform/aws/)
#   make init-app                              (same thing)
#
# Works regardless of the infra module's backend (S3, local, TF Cloud, etc.)
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

cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name)
name_prefix=$(terraform -chdir="$INFRA_DIR" output -raw name_prefix)
langsmith_irsa_role_arn=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_irsa_role_arn)
bucket_name=$(terraform -chdir="$INFRA_DIR" output -raw bucket_name)
alb_arn=$(terraform -chdir="$INFRA_DIR" output -raw alb_arn 2>/dev/null || echo "")
alb_dns_name=$(terraform -chdir="$INFRA_DIR" output -raw alb_dns_name 2>/dev/null || echo "")
alb_scheme=$(terraform -chdir="$INFRA_DIR" output -raw alb_scheme) || {
  echo "ERROR: Could not read alb_scheme from infra outputs." >&2
  echo "       This is required to set the correct ALB ingress annotation." >&2
  echo "       Set alb_scheme manually in app/terraform.tfvars (internet-facing or internal)." >&2
  exit 1
}
tls_certificate_source=$(terraform -chdir="$INFRA_DIR" output -raw tls_certificate_source)
acm_certificate_arn=$(terraform -chdir="$INFRA_DIR" output -raw acm_certificate_arn 2>/dev/null || echo "")
postgres_source=$(terraform -chdir="$INFRA_DIR" output -raw postgres_source 2>/dev/null || echo "external")
redis_source=$(terraform -chdir="$INFRA_DIR" output -raw redis_source 2>/dev/null || echo "external")
langsmith_namespace=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_namespace)

# ── Read region and environment from terraform output ────────────────────────

region=$(terraform -chdir="$INFRA_DIR" output -raw region 2>/dev/null) || region=""
environment=$(terraform -chdir="$INFRA_DIR" output -raw environment 2>/dev/null) || environment=""

if [[ -z "$region" ]]; then
  echo "ERROR: Could not read region from infra outputs." >&2
  echo "       If using an older infra module, set region manually in app/terraform.tfvars." >&2
  exit 1
fi
if [[ -z "$environment" ]]; then
  echo "ERROR: Could not read environment from infra outputs." >&2
  echo "       If using an older infra module, set environment manually in app/terraform.tfvars." >&2
  exit 1
fi

# ── Write infra.auto.tfvars.json ─────────────────────────────────────────────

cat > "$OUT_FILE" <<EOF
{
  "region": "$region",
  "name_prefix": "$name_prefix",
  "environment": "$environment",
  "cluster_name": "$cluster_name",
  "langsmith_irsa_role_arn": "$langsmith_irsa_role_arn",
  "bucket_name": "$bucket_name",
  "alb_arn": "$alb_arn",
  "alb_dns_name": "$alb_dns_name",
  "alb_scheme": "$alb_scheme",
  "tls_certificate_source": "$tls_certificate_source",
  "acm_certificate_arn": "$acm_certificate_arn",
  "postgres_source": "$postgres_source",
  "redis_source": "$redis_source",
  "langsmith_namespace": "$langsmith_namespace"
}
EOF

echo ""
echo "Written: $OUT_FILE"
echo ""
cat "$OUT_FILE"
echo ""
echo "Next: review app/terraform.tfvars for app-specific settings, then: make apply-app"
