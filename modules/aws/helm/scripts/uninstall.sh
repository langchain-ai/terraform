#!/usr/bin/env bash
# Uninstalls LangSmith from the correct EKS cluster.
#
# Resolves cluster name and region from terraform.tfvars + terraform output,
# updates kubeconfig to target the right cluster, then removes the Helm release
# and ESO resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
TF_DIR="$HELM_DIR/../infra"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"

# ── Resolve config from terraform.tfvars ──────────────────────────────────────
_tfvars="$TF_DIR/terraform.tfvars"

if [[ ! -f "$_tfvars" ]]; then
  echo "ERROR: terraform.tfvars not found at $_tfvars" >&2
  exit 1
fi

_environment=$(grep -E '^\s*environment\s*=' "$_tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _environment="dev"
_name_prefix=$(grep -E '^\s*name_prefix\s*=' "$_tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _name_prefix=""
_region=$(grep -E '^\s*region\s*=' "$_tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _region="${AWS_REGION:-us-east-2}"

echo "Resolved from terraform.tfvars:"
echo "  name_prefix  = ${_name_prefix:-(empty)}"
echo "  environment  = $_environment"
echo "  region       = $_region"
echo ""

# ── Get cluster name from Terraform output ────────────────────────────────────
echo "Reading cluster name from Terraform output..."
_cluster_name=$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null) || {
  echo "ERROR: Could not read cluster_name. Is 'terraform apply' complete?" >&2
  exit 1
}
echo "  cluster_name = $_cluster_name"
echo ""

# ── Point kubeconfig at the right cluster ─────────────────────────────────────
echo "Updating kubeconfig for cluster: $_cluster_name..."
aws eks update-kubeconfig --name "$_cluster_name" --region "$_region"
echo "  Active context: $(kubectl config current-context)"
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
echo "This will remove:"
echo "  - Helm release '$RELEASE_NAME' from namespace '$NAMESPACE'"
echo "  - ExternalSecret 'langsmith-config' from namespace '$NAMESPACE'"
echo "  - ClusterSecretStore 'langsmith-ssm'"
echo ""
printf "Proceed? [y/N] "
read -r _confirm
if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

# ── Uninstall Helm release ────────────────────────────────────────────────────
if helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null | grep -q '"name"'; then
  echo "Uninstalling Helm release '$RELEASE_NAME'..."
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
else
  echo "Helm release '$RELEASE_NAME' not found in namespace '$NAMESPACE' — skipping."
fi
echo ""

# ── Remove ESO resources ──────────────────────────────────────────────────────
echo "Removing ESO resources..."
kubectl delete externalsecret langsmith-config -n "$NAMESPACE" --ignore-not-found
kubectl delete clustersecretstore langsmith-ssm --ignore-not-found
echo ""

# ── Clean up operator-managed resources ──────────────────────────────────────
# platform-backend creates agent-builder and LangGraph resources at runtime with
# no Helm owner reference. kubectl delete all removes them so K8s stops restarting
# the pods. ConfigMaps and Secrets are left intact.
echo "Removing operator-managed resources from namespace '$NAMESPACE'..."
kubectl delete all --all -n "$NAMESPACE" --ignore-not-found
echo ""

echo "Uninstall complete."
