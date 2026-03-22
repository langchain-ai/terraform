#!/usr/bin/env bash
# preflight.sh — Pre-Terraform GCP permission and prerequisite check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$TF_DIR/terraform.tfvars"

REQUIRED_TOOLS=(gcloud terraform kubectl helm)
MISSING=()

for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING+=("$tool")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Missing required tools: ${MISSING[*]}" >&2
  exit 1
fi

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: terraform.tfvars not found at $TFVARS" >&2
  echo "Run: cp terraform.tfvars.example terraform.tfvars" >&2
  exit 1
fi

PROJECT_ID="$(terraform -chdir="$TF_DIR" console <<'EOF' 2>/dev/null | tr -d '"'
var.project_id
EOF
)"
REGION="$(terraform -chdir="$TF_DIR" console <<'EOF' 2>/dev/null | tr -d '"'
var.region
EOF
)"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(known after apply)" ]]; then
  PROJECT_ID="$(awk -F= '/^[[:space:]]*project_id[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$TFVARS" || true)"
fi
if [[ -z "$REGION" || "$REGION" == "(known after apply)" ]]; then
  REGION="$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$TFVARS" || true)"
fi
REGION="${REGION:-us-west2}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: Could not resolve project_id from terraform variables." >&2
  exit 1
fi

echo "Checking gcloud authentication..."
gcloud auth print-access-token >/dev/null

ACTIVE_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ "$ACTIVE_PROJECT" != "$PROJECT_ID" ]]; then
  echo "WARN: gcloud active project is '$ACTIVE_PROJECT', terraform project_id is '$PROJECT_ID'."
  echo "      Run: gcloud config set project $PROJECT_ID"
fi

echo "Checking required APIs in project '$PROJECT_ID'..."
APIS=(
  container.googleapis.com
  compute.googleapis.com
  sqladmin.googleapis.com
  redis.googleapis.com
  storage.googleapis.com
  iam.googleapis.com
  secretmanager.googleapis.com
  servicenetworking.googleapis.com
)
for api in "${APIS[@]}"; do
  enabled="$(gcloud services list --enabled --project "$PROJECT_ID" --filter="name:$api" --format='value(name)' || true)"
  if [[ -z "$enabled" ]]; then
    echo "WARN: API not enabled yet: $api (Terraform will attempt to enable it)"
  fi
done

echo "Checking project IAM access..."
gcloud projects get-iam-policy "$PROJECT_ID" --format='value(etag)' >/dev/null

echo "Checking cluster credentials command viability..."
gcloud container clusters list --project "$PROJECT_ID" --region "$REGION" >/dev/null || true

echo "GCP preflight checks passed."
