#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# deploy.sh — Install or upgrade LangSmith (with SmithDB) on bare metal.
#
# Usage (from baremetal/):   make deploy
#
# Needs: make apply (datastores + their Secrets), make setup-env
# (infra/.secrets.env), make init-values (helm/values/).
#
# 1. Builds the langsmith-config Secret from infra/.secrets.env. Values go to
#    kubectl on stdin: never on argv, never echoed, never written to disk.
# 2. Layers the values files (in order, last wins):
#      values.yaml                             base bare-metal config (committed)
#      langsmith-values-overrides.yaml         hostname, gateway (Terraform output)
#      langsmith-values-admin.yaml             initial org admin email
#      langsmith-values-sizing-<profile>.yaml  app sizing
#      langsmith-values-<feature>.yaml         enabled features (same order as modules/gcp)
#      langsmith-values-smithdb.yaml           SmithDB sizing + wiring (Terraform output)
#      langsmith-values-local.yaml             optional local experiments (gitignored)
# 3. helm upgrade --install langsmith langchain/langsmith --version $CHART_VERSION
# 4. Waits for SmithDB (cluster-manager first) and the core Deployments.

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$(cd "$HELM_DIR/../infra" && pwd)"
VALUES_DIR="$HELM_DIR/values"
export INFRA_DIR
# shellcheck source=../../infra/scripts/_common.sh
source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="langsmith"
NAMESPACE="langsmith"
# Line pin, like the other providers: Helm resolves ~0.17.0 to the newest 0.17
# patch. Override with CHART_VERSION for an exact patch.
CHART_VERSION="${CHART_VERSION:-~0.17.0}"

# These values use the chart 0.17 schema (SmithDB per-component sizing, the
# gateway HTTPRoute, standalone Insights/Polly wiring). Chart 0.18 has not been
# validated against them, so refuse anything off the 0.17 line rather than
# deploy a half-configured release.
_chart_line="$(printf '%s' "$CHART_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$_chart_line" != "0.17" ]]; then
  echo "ERROR: CHART_VERSION '$CHART_VERSION' does not resolve to the chart 0.17 line." >&2
  echo "       Leave CHART_VERSION unset to use the pin, or name a 0.17 patch explicitly:" >&2
  echo "         CHART_VERSION=0.17.10 make deploy" >&2
  exit 1
fi

# ── Preconditions ────────────────────────────────────────────────────────────
header "Preflight"
for tool in terraform kubectl helm python3; do
  command -v "$tool" >/dev/null || { fail "$tool not found"; exit 1; }
done

# Always the cluster named in terraform.tfvars, never the current context.
kube_context="$(_parse_tfvar kube_context)"
kubeconfig="$(_parse_tfvar kubeconfig_path)"
kubeconfig="${kubeconfig/#\~/$HOME}"
if [[ -z "$kube_context" || -z "$kubeconfig" ]]; then
  fail "kube_context and kubeconfig_path must be set in infra/terraform.tfvars"
  exit 1
fi
_kubectl() { kubectl --kubeconfig "$kubeconfig" --context "$kube_context" "$@"; }
_helm()    { helm --kubeconfig "$kubeconfig" --kube-context "$kube_context" "$@"; }

if ! _kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  fail "cannot reach namespace $NAMESPACE on context $kube_context — run make apply (or check macOS Local Network permission)"
  exit 1
fi
pass "cluster: $kube_context, namespace $NAMESPACE"

# The datastore Secrets come from Terraform; the chart fails late without them.
for secret in langsmith-postgres langsmith-redis smithdb-config; do
  if ! _kubectl get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1; then
    fail "Secret $NAMESPACE/$secret is missing — run make apply"
    exit 1
  fi
done
pass "datastore Secrets: langsmith-postgres, langsmith-redis, smithdb-config"

_secrets_file_check
if [[ ! -f "$SECRETS_FILE" ]]; then
  fail "$SECRETS_FILE not found — run make setup-env"
  exit 1
fi

# Enabled features, from the applied Terraform state (not a tfvars parse).
features_json="$(terraform -chdir="$INFRA_DIR" output -json features)" || {
  fail "terraform output features is missing — run make apply"
  exit 1
}
_feature_on() {
  python3 -I -c '
import json, sys
f = json.loads(sys.argv[1]); name = sys.argv[2]
on = f.get(name) is True or name in f.get("standalone", {})
sys.exit(0 if on else 1)
' "$features_json" "$1"
}

# ── 1. langsmith-config Secret ───────────────────────────────────────────────
header "langsmith-config Secret (from infra/.secrets.env)"

# Prints secret_key=value for each pair, failing on the first empty value.
# Built fully before kubectl runs, so a missing value never replaces the
# Secret with a partial one.
_config_payload() {
  local pair key store value
  for pair in "$@"; do
    key="${pair%%:*}"
    store="${pair#*:}"
    value="$(_secret_get "$store")"
    if [[ -z "$value" ]]; then
      fail "$store is not set in $SECRETS_FILE — run make setup-env" >&2
      return 1
    fi
    printf '%s=%s\n' "$key" "$value"
  done
}

config_pairs=(
  "langsmith_license_key:LANGSMITH_LICENSE_KEY"
  "api_key_salt:API_KEY_SALT"
  "jwt_secret:JWT_SECRET"
  "initial_org_admin_password:INITIAL_ORG_ADMIN_PASSWORD"
)
# Fleet keeps the chart's legacy key name (agent_builder_encryption_key).
_feature_on fleet    && config_pairs+=("agent_builder_encryption_key:AGENT_BUILDER_ENCRYPTION_KEY")
_feature_on insights && config_pairs+=("insights_encryption_key:INSIGHTS_ENCRYPTION_KEY")
_feature_on polly    && config_pairs+=("polly_encryption_key:POLLY_ENCRYPTION_KEY")
_feature_on sandboxes && config_pairs+=("sandbox_callback_signing_jwk:SANDBOX_CALLBACK_SIGNING_JWK")
_feature_on engine   && config_pairs+=("engine_encryption_key:ENGINE_ENCRYPTION_KEY" "engine_usage_signing_secret:ENGINE_USAGE_SIGNING_SECRET")
if ! config_env="$(_config_payload "${config_pairs[@]}")"; then
  fail "The langsmith-config Secret was not changed."
  exit 1
fi

# Blob storage (config.blobStorage) uses the same RustFS keys as SmithDB:
# copy them from the Terraform-managed smithdb-config Secret. Held in shell
# variables only; never printed or passed on argv.
_secret_key() {
  _kubectl get secret smithdb-config -n "$NAMESPACE" -o "jsonpath={.data.$1}" | base64 -d
}
if _feature_on blob_storage; then
  blob_key="$(_secret_key smithdb_s3_access_key)" || blob_key=""
  blob_secret="$(_secret_key smithdb_s3_secret_key)" || blob_secret=""
  if [[ -z "$blob_key" || -z "$blob_secret" ]]; then
    fail "smithdb-config has no S3 keys for blob storage — run make apply. The langsmith-config Secret was not changed."
    exit 1
  fi
  config_env+=$'\n'"blob_storage_access_key=$blob_key"$'\n'"blob_storage_access_key_secret=$blob_secret"
  config_pairs+=("blob_storage_access_key" "blob_storage_access_key_secret")
  unset blob_key blob_secret
fi
printf '%s\n' "$config_env" | _kubectl create secret generic langsmith-config \
  --namespace "$NAMESPACE" \
  --from-env-file=/dev/stdin \
  --dry-run=client -o yaml | _kubectl apply -f - >/dev/null
unset config_env
pass "langsmith-config (${#config_pairs[@]} keys; values not printed)"

# ── 2. Values files ──────────────────────────────────────────────────────────
header "Values (in order, last wins)"

_require_values() {
  if [[ ! -f "$VALUES_DIR/$1" ]]; then
    fail "$1 not found — run make init-values"
    exit 1
  fi
  values_args+=(-f "$VALUES_DIR/$1")
  pass "$1"
}

profile="$(_parse_tfvar sizing_profile)"
profile="${profile:-minimum}"

values_args=()
_require_values values.yaml
_require_values langsmith-values-overrides.yaml
_require_values langsmith-values-admin.yaml
_require_values "langsmith-values-sizing-$profile.yaml"
_feature_on deployments && _require_values langsmith-values-agent-deploys.yaml
_feature_on fleet       && _require_values langsmith-values-fleet.yaml
_feature_on polly       && _require_values langsmith-values-standalone-polly.yaml
_feature_on insights    && _require_values langsmith-values-standalone-insights.yaml
_require_values langsmith-values-smithdb.yaml
# Optional, last: your local experiments (e.g. a short trace TTL for a load
# test). Gitignored; delete the file to go back to the generated values.
if [[ -f "$VALUES_DIR/langsmith-values-local.yaml" ]]; then
  _require_values langsmith-values-local.yaml
fi

# Secrets only ever come from langsmith-config: blank any inline value a values
# file might carry, so the chart can't render its own Secret beside ours.
values_args+=(
  --set "config.existingSecretName=langsmith-config"
  --set-string "config.langsmithLicenseKey="
  --set-string "config.apiKeySalt="
  --set-string "config.basicAuth.jwtSecret="
  --set-string "config.basicAuth.initialOrgAdminPassword="
  --set-string "config.agentBuilder.encryptionKey="
  --set-string "fleet.encryptionKey="
  --set-string "insights.encryptionKey="
  --set-string "polly.encryptionKey="
)

# ── 3. Helm ──────────────────────────────────────────────────────────────────
header "Helm: $RELEASE_NAME (chart langchain/langsmith $CHART_VERSION)"

_helm repo add langchain https://langchain-ai.github.io/helm >/dev/null 2>&1 || true
# One failed fetch of the index used to end the deploy; the chart version is pinned, so a retry is
# always safe. Seen on a lab node: the fetch failed once, then answered in 0.3 s.
for attempt in 1 2 3 4 5; do
  _helm repo update langchain >/dev/null && break
  if [[ $attempt == 5 ]]; then
    fail "helm repo update langchain failed 5 times: is https://langchain-ai.github.io/helm reachable from here?"
    exit 1
  fi
  warn "helm repo update failed (attempt $attempt of 5); retrying in $((attempt * 5))s"
  sleep $((attempt * 5))
done

# A release stuck in pending-* (an interrupted run) blocks upgrades. Don't
# guess the fix: print it.
release_status="$(_helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}\$" -o json \
  | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["status"] if r else "")')"
case "$release_status" in
  pending-*|uninstalling)
    fail "release $RELEASE_NAME is $release_status. Check, roll back, then rerun:"
    action "helm --kube-context $kube_context history $RELEASE_NAME -n $NAMESPACE --max 5"
    action "helm --kube-context $kube_context rollback $RELEASE_NAME <revision> -n $NAMESPACE"
    exit 1
    ;;
  failed)   warn "previous release failed (often a hook timeout); upgrading in place" ;;
  "")       info "first install" ;;
  *)        info "upgrading release ($release_status)" ;;
esac

# Helm 4 defaults a fresh install to server-side apply; the chart is tested with
# client-side apply. Helm 3 rejects the flag, so pass it on Helm 4 only.
helm_major="$(helm version --template '{{.Version}}' 2>/dev/null | sed -e 's/^v//' -e 's/[^0-9].*$//')" || helm_major=""
ssa_args=()
[[ -n "$helm_major" && "$helm_major" -ge 4 ]] && ssa_args=(--server-side=false)

# No --wait: hooks (DB migrations, smithdb metastore migration) still run to
# completion; the rollout checks below report per component.
info "running hooks (Postgres + SmithDB metastore migrations) — a few minutes"
if ! _helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  ${ssa_args[@]+"${ssa_args[@]}"} \
  "${values_args[@]}" \
  --timeout 20m; then
  fail "helm upgrade failed"
  action "kubectl --context $kube_context get jobs,pods -n $NAMESPACE"
  exit 1
fi
pass "helm release applied"

# ── 4. Rollout ───────────────────────────────────────────────────────────────
header "Rollout"

# cluster-manager first: ingestion pods fail to start until it answers.
deployments=(
  smithdb-cluster-manager
  smithdb-ingestion smithdb-query smithdb-compaction smithdb-compaction-worker
  frontend backend platform-backend ingest-queue queue playground ace-backend
)
_feature_on deployments && deployments+=(host-backend listener operator)

all_ready=true
for dep in "${deployments[@]}"; do
  if _kubectl rollout status "deployment/$RELEASE_NAME-$dep" -n "$NAMESPACE" --timeout=5m >/dev/null 2>&1; then
    pass "$RELEASE_NAME-$dep"
  else
    warn "$RELEASE_NAME-$dep not ready within 5m"
    all_ready=false
  fi
done

header "Done"
if [[ "$all_ready" == true ]]; then
  pass "LangSmith is up: $(terraform -chdir="$INFRA_DIR" output -raw langsmith_url)"
  info "Log in with INITIAL_ORG_ADMIN_EMAIL / INITIAL_ORG_ADMIN_PASSWORD from $SECRETS_FILE"
else
  warn "Some components are not ready yet. Look at:"
  action "kubectl --context $kube_context get pods -n $NAMESPACE"
  action "kubectl --context $kube_context describe pod -n $NAMESPACE <pod>"
  exit 1
fi
