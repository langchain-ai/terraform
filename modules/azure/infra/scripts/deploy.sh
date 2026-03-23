#!/usr/bin/env bash
set -euo pipefail
# deploy.sh — Pass 2: prepare values-overrides.yaml, create K8s secrets, deploy LangSmith via Helm
#
# Usage:
#   cd terraform/azure/infra
#   ./scripts/deploy.sh
#
# What this does:
#   1. Reads terraform outputs (hostname, storage, workload identity)
#   2. Copies values-overrides-pass-2.yaml.example → values-overrides.yaml and fills placeholders
#   3. Prompts for admin email and chart version
#   4. Creates langsmith-config-secret from Key Vault (calls create-k8s-secrets.sh)
#   5. Deploys LangSmith via helm upgrade --install
#
# Re-runnable — helm upgrade is idempotent. values-overrides.yaml is overwritten each run.
# To deploy a different pass: copy the pass example manually and run helm upgrade directly.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELM_VALUES_DIR="$(cd "$INFRA_DIR/../helm/values" && pwd)"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith Azure — Pass 2 Deploy"
echo "══════════════════════════════════════════════════════"
echo ""

# ── 1. Collect terraform outputs ──────────────────────────────────────────────
echo "  Reading terraform outputs..."

cd "$INFRA_DIR"

HOSTNAME=$(terraform output -raw langsmith_url 2>/dev/null | sed 's|https://||') || HOSTNAME=""
KV_NAME=$(terraform output -raw keyvault_name 2>/dev/null) || KV_NAME=""
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name 2>/dev/null) || STORAGE_ACCOUNT=""
STORAGE_CONTAINER=$(terraform output -raw storage_container_name 2>/dev/null) || STORAGE_CONTAINER=""
WI_CLIENT_ID=$(terraform output -raw storage_account_k8s_managed_identity_client_id 2>/dev/null) || WI_CLIENT_ID=""
NAMESPACE=$(terraform output -raw langsmith_namespace 2>/dev/null) || NAMESPACE="langsmith"
ADMIN_EMAIL=$(terraform output -raw langsmith_admin_email 2>/dev/null) || ADMIN_EMAIL=""

if [ -z "$HOSTNAME" ] || [ -z "$KV_NAME" ] || [ -z "$STORAGE_ACCOUNT" ]; then
  echo -e "${RED}  Error: terraform outputs missing. Run 'terraform apply' first.${NC}"
  exit 1
fi

if [ -z "$ADMIN_EMAIL" ]; then
  echo -e "${RED}  Error: admin email not set. Re-run 'bash setup-env.sh' and enter your email when prompted.${NC}"
  exit 1
fi

echo ""
echo "  hostname          : $HOSTNAME"
echo "  keyvault          : $KV_NAME"
echo "  storage_account   : $STORAGE_ACCOUNT"
echo "  storage_container : $STORAGE_CONTAINER"
echo "  workload_identity : $WI_CLIENT_ID"
echo "  namespace         : $NAMESPACE"
echo "  admin_email       : $ADMIN_EMAIL"
echo ""

# ── 2. Prompt for chart version ────────────────────────────────────────────────
echo ""
echo "  Fetching available chart versions..."
helm repo add langsmith https://langchain-ai.github.io/helm --force-update &>/dev/null
helm repo update &>/dev/null
echo ""
helm search repo langsmith/langsmith --versions | head -6
echo ""
printf "  Chart version to deploy (e.g. 0.13.28): "
read -r CHART_VERSION
if [ -z "$CHART_VERSION" ]; then
  echo -e "${RED}  Error: chart version is required.${NC}"
  exit 1
fi

# ── 3. Prepare values-overrides.yaml ──────────────────────────────────────────
VALUES_FILE="$HELM_VALUES_DIR/values-overrides.yaml"
TEMPLATE="$HELM_VALUES_DIR/values-overrides-pass-2.yaml.example"

if [ ! -f "$TEMPLATE" ]; then
  echo -e "${RED}  Error: template not found: $TEMPLATE${NC}"
  exit 1
fi

echo ""
echo "  Generating $VALUES_FILE from pass-2 template..."

cp "$TEMPLATE" "$VALUES_FILE"

# macOS sed requires '' after -i; Linux does not — detect and handle both
_sed() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

_sed "s|<your-domain.com>|${HOSTNAME}|g"                             "$VALUES_FILE"
_sed "s|<admin@example.com>|${ADMIN_EMAIL}|g"                        "$VALUES_FILE"
_sed "s|<tf output: storage_account_name>|${STORAGE_ACCOUNT}|g"      "$VALUES_FILE"
_sed "s|<tf output: storage_container_name>|${STORAGE_CONTAINER}|g"  "$VALUES_FILE"
_sed "s|<tf output: workload_identity_client_id>|${WI_CLIENT_ID}|g"  "$VALUES_FILE"

echo -e "  ${GREEN}[✓]${NC} values-overrides.yaml generated"

# ── 4. Create langsmith-config-secret ─────────────────────────────────────────
echo ""
bash "$SCRIPT_DIR/create-k8s-secrets.sh"

# ── 5. Review before deploy ───────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Review before deploying"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Values file : $VALUES_FILE"
echo "  Chart       : langsmith/langsmith v${CHART_VERSION}"
echo "  Namespace   : $NAMESPACE"
echo "  Hostname    : $HOSTNAME"
echo "  Admin email : $ADMIN_EMAIL"
echo ""
echo "  Open the values file to review:"
echo "  ${VALUES_FILE}"
echo ""
printf "  Proceed with helm deploy? [y/N] "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo ""
  echo -e "${YELLOW}  Deploy cancelled. Edit the values file and re-run to continue.${NC}"
  echo "  helm upgrade --install langsmith langsmith/langsmith \\"
  echo "    --version ${CHART_VERSION} --namespace ${NAMESPACE} \\"
  echo "    -f ${VALUES_FILE} --wait --timeout 15m"
  echo ""
  exit 0
fi

# ── 6. Helm deploy ────────────────────────────────────────────────────────────
echo ""
echo "  Deploying LangSmith chart v${CHART_VERSION} to namespace/${NAMESPACE}..."
echo ""

helm upgrade --install langsmith langsmith/langsmith \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$VALUES_FILE" \
  --wait --timeout 15m

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  LangSmith deployed successfully.${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo "  URL      : https://${HOSTNAME}"
echo "  Login    : ${ADMIN_EMAIL}"
echo "  Password : az keyvault secret show --vault-name ${KV_NAME} --name langsmith-admin-password --query value -o tsv"
echo ""
echo "  kubectl get pods -n ${NAMESPACE}"
echo ""
