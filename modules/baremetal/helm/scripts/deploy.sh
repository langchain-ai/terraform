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
#      langsmith-values-<feature>.yaml         enabled features (same order as modules/gcp), then sso
#      langsmith-values-smithdb.yaml           SmithDB sizing + wiring (Terraform output)
#      langsmith-values-local.yaml             optional local experiments (gitignored)
# 3. helm upgrade --install langsmith langchain/langsmith --version $CHART_VERSION
# 4. Waits for SmithDB (cluster-manager first, when it is on) and the core Deployments.

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
# gateway HTTPRoute, standalone Insights/Polly wiring). Chart 0.18 keeps that
# layout and only adds keys, so it is accepted too, as on the other providers
# (#433). Refuse any other line rather than deploy a half-configured release.
_chart_line="$(printf '%s' "$CHART_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$_chart_line" != "0.17" && "$_chart_line" != "0.18" ]]; then
  echo "ERROR: CHART_VERSION '$CHART_VERSION' does not resolve to the chart 0.17 or 0.18 line." >&2
  echo "       Leave CHART_VERSION unset to use the pin, or name a 0.17 or 0.18 patch explicitly:" >&2
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
  "langsmith_signing_jwks:LANGSMITH_SIGNING_JWKS"
)
# Fleet keeps the chart's legacy key name (agent_builder_encryption_key).
_feature_on fleet    && config_pairs+=("agent_builder_encryption_key:AGENT_BUILDER_ENCRYPTION_KEY")
_feature_on insights && config_pairs+=("insights_encryption_key:INSIGHTS_ENCRYPTION_KEY")
_feature_on polly    && config_pairs+=("polly_encryption_key:POLLY_ENCRYPTION_KEY")
_feature_on sandboxes && config_pairs+=("sandbox_callback_signing_jwk:SANDBOX_CALLBACK_SIGNING_JWK")
_feature_on engine   && config_pairs+=("engine_encryption_key:ENGINE_ENCRYPTION_KEY" "engine_usage_signing_secret:ENGINE_USAGE_SIGNING_SECRET")
_feature_on sso_oidc && config_pairs+=("oauth_client_id:OAUTH_CLIENT_ID" "oauth_client_secret:OAUTH_CLIENT_SECRET" "oauth_issuer_url:OAUTH_ISSUER_URL")
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

# Engine's gateway key, the file ENGINE_GATEWAY_API_KEY_FILE names (infra/sandboxes.tf).
if _feature_on engine_gateway; then
  gateway_key="$(_secret_get ENGINE_GATEWAY_API_KEY)"
  if [[ -z "$gateway_key" ]]; then
    fail "ENGINE_GATEWAY_API_KEY is not set in $SECRETS_FILE — run make setup-env"
    exit 1
  fi
  printf '%s' "$gateway_key" | _kubectl create secret generic engine-model-gateway \
    --namespace "$NAMESPACE" \
    --from-file=api-key=/dev/stdin \
    --dry-run=client -o yaml | _kubectl apply -f - >/dev/null
  unset gateway_key
  pass "engine-model-gateway (1 key; value not printed)"
fi

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
_feature_on sso_oidc    && _require_values langsmith-values-sso.yaml
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
# guess the fix: print it. Only "not found" means a first install; any other
# failure (an unreachable cluster) stops here instead of reading as one.
release_status=""
if status_json="$(_helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null)"; then
  release_status="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' <<<"$status_json")"
elif ! status_err="$(_helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>&1 >/dev/null)" \
     && [[ "$status_err" != *"release: not found"* ]]; then
  fail "helm status $RELEASE_NAME failed: $status_err"
  exit 1
fi
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
# A failed hook leaves Helm reporting only "job failed: BackoffLimitExceeded",
# which never names the job. The chart's hooks use hook-delete-policy
# before-hook-creation, so the failed Job and its pod are still there to read,
# as the AWS module does (#476).
_report_failed_hook_jobs() {
  local job failed
  _kubectl get jobs -n "$NAMESPACE" >&2 || true
  while read -r job failed; do
    [[ -n "$job" && "${failed:-}" =~ ^[0-9]+$ ]] || continue
    ((failed > 0)) || continue
    echo "── failed hook job: ${job} ──" >&2
    _kubectl describe job "$job" -n "$NAMESPACE" >&2 || true
    _kubectl logs "job/$job" -n "$NAMESPACE" --all-containers --tail=200 >&2 || true
  done < <(_kubectl get jobs -n "$NAMESPACE" \
    -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.failed}{"\n"}{end}' 2>/dev/null || true)
}

info "running hooks (Postgres + SmithDB metastore migrations) — a few minutes"
if ! _helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  ${ssa_args[@]+"${ssa_args[@]}"} \
  "${values_args[@]}" \
  --timeout 20m; then
  fail "helm upgrade failed"
  _report_failed_hook_jobs
  exit 1
fi
pass "helm release applied"

# ── Long-running streams: no request timeout ─────────────────────────────────
# Fleet run streams and the Deployments proxy (/api-host/v2) stream for longer
# than any request timeout, and were reset mid-response. A second HTTPRoute
# with only those path prefixes and timeouts.request: 0s takes them (the longer
# prefix wins over the chart's "/"), as the AWS and Azure modules' route of the
# same name (#299, #424). The module's request-timeout policy targets the
# chart's route and the LAN route, never the Gateway, so it does not reach this
# one or the operator's agent routes. Hostname and base path come from the
# release's values, as the chart's route takes them; with no DNS name (the
# Gateway IP, this module's default) the route has no hostnames, like the
# chart's. Applied with Fleet or Deployments on, removed when both are off.
if _feature_on fleet || _feature_on deployments; then
  read -r _streams_host _streams_base _streams_gw _streams_gw_ns < <(_helm get values "$RELEASE_NAME" -n "$NAMESPACE" --all -o json 2>/dev/null \
    | python3 -I -c '
import json, re, sys
v = json.load(sys.stdin) or {}
cfg = v.get("config") or {}
host = re.sub(r"^[a-z][a-z0-9+.-]*://", "", str(cfg.get("hostname") or "").strip(), flags=re.I).rstrip("/")
dns = re.fullmatch(r"([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]", host, flags=re.I)
base = "/" + str(cfg.get("basePath") or "").strip("/ ")
gw = v.get("gateway") or {}
print(host if dns else "-", base if base != "/" else "-", gw.get("name") or "langsmith-gateway", gw.get("namespace") or "-")
' 2>/dev/null) || true
  [[ "${_streams_base:--}" == "-" ]] && _streams_base=""
  # An existing_gateway lives in its own namespace; without it the route attaches to nothing and apply still succeeds.
  [[ "${_streams_gw_ns:--}" == "-" ]] && _streams_gw_ns="$NAMESPACE"
  _streams_hostnames=""
  [[ -n "${_streams_host:-}" && "$_streams_host" != "-" ]] && _streams_hostnames="  hostnames:
  - \"${_streams_host}\""
  if _kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: langsmith-fleet-streams
  namespace: ${NAMESPACE}
spec:
  parentRefs:
  - name: ${_streams_gw:-langsmith-gateway}
    namespace: ${_streams_gw_ns}
${_streams_hostnames}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${_streams_base}/api/v1/fleet/threads
    - path:
        type: PathPrefix
        value: ${_streams_base}/api/v1/fleet/lg
    - path:
        type: PathPrefix
        value: ${_streams_base}/api-host/v2
    backendRefs:
    - name: ${RELEASE_NAME}-frontend
      port: 80
    timeouts:
      request: 0s
EOF
  then
    pass "HTTPRoute langsmith-fleet-streams: no request timeout on ${_streams_base}/api/v1/fleet and ${_streams_base}/api-host/v2"
  else
    warn "could not apply HTTPRoute langsmith-fleet-streams; Fleet and Deployments streams keep the chart route's request timeout until it applies: re-run make deploy"
  fi
else
  _kubectl delete httproute langsmith-fleet-streams -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
fi

# ── 4. Rollout ───────────────────────────────────────────────────────────────
header "Rollout"

# Every Deployment the release made, read from the cluster rather than a list kept here: the list
# missed sandbox-host, Fleet, Insights and Polly, so a chart upgrade reported ready while sandbox-host
# was still rolling (reed-lab, chart 0.17.33, 2026-10-29). The cluster-manager first: ingestion pods
# fail to start until it answers.
if ! release_deployments="$(_kubectl get deployments -n "$NAMESPACE" \
  -o jsonpath="{range .items[?(@.metadata.annotations.meta\.helm\.sh/release-name==\"$RELEASE_NAME\")]}{.metadata.name}{\"\\n\"}{end}")" \
  || [[ -z "$release_deployments" ]]; then
  fail "could not list the Deployments of release $RELEASE_NAME in $NAMESPACE"
  exit 1
fi
deployments=()
while IFS= read -r dep; do
  deployments+=("$dep")
done < <(grep -- '-smithdb-cluster-manager$' <<<"$release_deployments"; grep -v -- '-smithdb-cluster-manager$' <<<"$release_deployments")

all_ready=true
for dep in "${deployments[@]}"; do
  if _kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m >/dev/null 2>&1; then
    pass "$dep"
  else
    warn "$dep not ready within 5m"
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
