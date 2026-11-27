#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Runs init-values.sh for each case below and checks the two values files it
# writes against the LangSmith chart. No cluster and no GCP calls: init-values.sh
# runs for real, with stub terraform and kubectl commands that answer from a
# fixture terraform.tfvars and fixture Terraform outputs.
#
# Each case checks the settings its flags control, and also that:
#   - init-values.sh writes langsmith-values.yaml and langsmith-values-overrides.yaml,
#     and the chart accepts the two as deploy.sh applies them;
#   - the two files give Helm the same values as their sources layered one by one;
#   - no secret reaches either file, and the chart reads each from langsmith-config;
#   - a second run writes the same bytes, and the checks of deploy.sh pass.
# Further checks cover langsmith-values-local.yaml, a hand edit, a terraform.tfvars
# change, a langsmith_domain change, the Gateway IP refresh of deploy.sh, the 0.17
# layout, and the sizing examples.
#
# Requires helm, and network access to fetch the chart unless LANGSMITH_CHART
# names a local chart directory or archive.
# Usage: bash modules/gcp/helm/scripts/test-values.sh
#        CHART_VERSION=0.18.5 bash modules/gcp/helm/scripts/test-values.sh
# Exit 0 pass, 1 a failing check, 2 the test could not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXAMPLES_DIR="$MODULE_DIR/helm/values/examples"
CHART_REPO="https://langchain-ai.github.io/helm"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is not installed" >&2; exit 2; }

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

# Same chart line as deploy.sh: its pin, unless CHART_VERSION is exported.
version="${CHART_VERSION:-}"
if [[ -z "$version" ]]; then
  version=$(grep -oE 'CHART_VERSION:-~[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT_DIR/deploy.sh" | head -1) || true
  version="${version#CHART_VERSION:-}"
fi
[[ -n "$version" ]] || { echo "ERROR: no chart pin found in deploy.sh" >&2; exit 2; }

if [[ -n "${LANGSMITH_CHART:-}" ]]; then
  chart="$LANGSMITH_CHART"
else
  pull=(helm pull langsmith --repo "$CHART_REPO" --version "$version" --destination "$TEST_TMP")
  [[ "$version" != *-* ]] || pull+=(--devel)
  if ! "${pull[@]}" > "$TEST_TMP/pull.log" 2>&1; then
    cat "$TEST_TMP/pull.log" >&2
    echo "ERROR: could not fetch chart langsmith $version from $CHART_REPO" >&2
    exit 2
  fi
  chart=$(find "$TEST_TMP" -maxdepth 1 -name 'langsmith-*.tgz' | head -1)
fi
if ! chart_meta=$(helm show chart "$chart") || ! chart_version=$(awk '/^version:/ { print $2 }' <<< "$chart_meta") \
  || [[ -z "$chart_version" ]]; then
  echo "ERROR: $chart is not a readable chart" >&2
  exit 2
fi
# deploy.sh runs sandbox-host from the chart's appVersion.
app_version=$(awk '/^appVersion:/ { print $2 }' <<< "$chart_meta" | tr -d "\"'")
echo "Chart: langsmith $chart_version (pin $version)"

# _parse_tfvar reads $INFRA_DIR/terraform.tfvars; each case sets INFRA_DIR.
INFRA_DIR="$TEST_TMP/no-case"
source "$MODULE_DIR/infra/scripts/_common.sh"
# shellcheck source=_values.sh
source "$SCRIPT_DIR/_values.sh"

# ── Stub commands ─────────────────────────────────────────────────────────────
STUB_BIN="$TEST_TMP/bin"
mkdir -p "$STUB_BIN"
# terraform -chdir=<infra> output -raw|-json <name> answers from <infra>/outputs/
# and fails, as an empty state does, for a missing output or any other command.
cat > "$STUB_BIN/terraform" <<'STUB'
#!/usr/bin/env bash
dir="$PWD"
args=()
for a in "$@"; do
  case "$a" in
    -chdir=*) dir="${a#-chdir=}" ;;
    *) args+=("$a") ;;
  esac
done
[[ "${args[0]:-}" == output ]] || exit 1
case "${args[1]:-}" in
  -raw) file="$dir/outputs/${args[2]:-}" ;;
  -json) file="$dir/outputs/${args[2]:-}.json" ;;
  *) exit 1 ;;
esac
[[ -f "$file" ]] || exit 1
cat "$file"
STUB
# The external ClickHouse Secret exists.
cat > "$STUB_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "get secret langsmith-clickhouse "*) exit 0 ;;
esac
echo "values test: unexpected kubectl $*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/terraform" "$STUB_BIN/kubectl"

# The secrets setup-env.sh exports. None of them may reach a values file.
SECRET_MARK="values-test-secret"
export TF_VAR_langsmith_license_key="$SECRET_MARK-license"
export TF_VAR_langsmith_api_key_salt="$SECRET_MARK-salt"
export TF_VAR_langsmith_jwt_secret="$SECRET_MARK-jwt"
export TF_VAR_langsmith_admin_password="$SECRET_MARK-password"
export TF_VAR_langsmith_agent_builder_encryption_key="$SECRET_MARK-fleet"
export TF_VAR_langsmith_insights_encryption_key="$SECRET_MARK-insights"
export TF_VAR_langsmith_polly_encryption_key="$SECRET_MARK-polly"
export TF_VAR_sandbox_callback_signing_jwk="$SECRET_MARK-jwk"
export TF_VAR_sandbox_service_auth_secret="$SECRET_MARK-service-auth"
export TF_VAR_langsmith_oauth_client_id="$SECRET_MARK-oauth-id"
export TF_VAR_langsmith_oauth_client_secret="$SECRET_MARK-oauth-secret"
export TF_VAR_langsmith_oauth_issuer_url="https://issuer.example.com/$SECRET_MARK"
# The values each of them filled on 0.17. The chart now reads all of them from
# the langsmith-config Secret that deploy.sh writes.
INLINE_SECRET_KEYS="config.langsmithLicenseKey config.apiKeySalt config.basicAuth.jwtSecret
config.basicAuth.initialOrgAdminPassword config.agentBuilder.encryptionKey fleet.encryptionKey
insights.encryptionKey polly.encryptionKey sandboxes.callbackSigningJwk config.oauth.oauthClientId
config.oauth.oauthClientSecret config.oauth.oauthIssuerUrl"

# ── Fixtures ──────────────────────────────────────────────────────────────────
BASE_TFVARS='project_id = "values-test-project"
name_prefix = "vt"
environment = "test"
region = "us-west2"
tls_certificate_source = "letsencrypt"
postgres_source = "external"
redis_source = "external"
langsmith_admin_email = "admin@example.com"'
# name=value; a name ending in .json answers terraform output -json.
WI_SA="values-test@values-test-project.iam.gserviceaccount.com"
SMITHDB_SA="values-test-smithdb@values-test-project.iam.gserviceaccount.com"
BASE_OUTPUTS="langsmith_domain=langsmith.example.com
storage_bucket_name=values-test-blob
cluster_name=values-test-gke
workload_identity_annotation=$WI_SA
ingress_ip=34.0.0.10
sandbox_juicefs_csi_config_secret_name=juicefs-csi-config
smithdb_object_store_bucket=values-test-smithdb
smithdb_gsa_email=$SMITHDB_SA
smithdb_metastore_port=5432
smithdb_metastore_use_ssl=false
smithdb_metastore_secret_name=smithdb-metastore
smithdb_metastore_use_auth_proxy=true
smithdb_metastore_connection_name=values-test-project:us-west2:values-test-smithdb
smithdb_auth_proxy_image=gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1
sandbox_cluster_name=values-test-sandbox
sandbox_runtime_secret_name=langsmith-sandbox-runtime"
# terraform output -raw smithdb_helm_values, as yamlencode writes it.
SMITHDB_HELM_VALUES='"smithdb":
  "resourceTier": "medium"'

CASES="default deployments tls-none agent-builder fleet insights clickhouse-external polly standalone-polly standalone-insights sandboxes smithdb sizing-production sizing-minimum sso in-cluster-db ip all"
# The external sandbox runtime ships with chart 0.18, and deploy.sh refuses an
# external runtime on an earlier chart.
_chart_minor=$(awk -F. '{ print $1 * 1000 + $2 }' <<< "$chart_version")
if (( _chart_minor >= 18 )); then
  CASES="$CASES sandboxes-external"
fi

# Prints the terraform.tfvars lines of a case. They go before BASE_TFVARS, and the
# parser reads the first line of a key, so they win.
case_tfvars() {
  case "$1" in
    deployments) echo 'enable_deployments = true' ;;
    tls-none) printf '%s\n' 'tls_certificate_source = "none"' 'enable_deployments = true' ;;
    agent-builder) printf '%s\n' 'enable_deployments = true' 'enable_agent_builder = true' ;;
    fleet) echo 'enable_fleet = true' ;;
    insights) echo 'enable_insights = true' ;;
    clickhouse-external) printf '%s\n' 'enable_insights = true' 'clickhouse_source = "external"' ;;
    polly) printf '%s\n' 'enable_deployments = true' 'enable_polly = true' ;;
    standalone-polly) echo 'enable_standalone_polly = true' ;;
    standalone-insights) echo 'enable_standalone_insights = true' ;;
    sandboxes) echo 'enable_sandboxes = true' ;;
    sandboxes-external) printf '%s\n' 'enable_sandboxes = true' 'sandbox_runtime_source = "external"' ;;
    smithdb) printf '%s\n' 'enable_smithdb = true' 'smithdb_ingestion_enabled = true' 'smithdb_query_enabled = true' ;;
    sizing-production) printf '%s\n' 'sizing_profile = "production"' 'enable_deployments = true' ;;
    sizing-minimum) printf '%s\n' 'sizing_profile = "minimum"' 'enable_deployments = true' ;;
    sso) echo 'enable_sso_oidc = true' ;;
    in-cluster-db) printf '%s\n' 'postgres_source = "in-cluster"' 'redis_source = "in-cluster"' ;;
    all) printf '%s\n' 'sizing_profile = "production"' 'enable_deployments = true' 'enable_fleet = true' \
      'enable_insights = true' 'enable_polly = true' 'enable_sandboxes = true' 'enable_smithdb = true' \
      'smithdb_ingestion_enabled = true' 'smithdb_query_enabled = true' 'enable_sso_oidc = true' ;;
  esac
}

# Prints the Terraform outputs a case changes, as name=value. An external runtime
# refuses the placeholder domain langsmith.example.com.
case_outputs() {
  case "$1" in
    ip) echo 'langsmith_domain=' ;;
    sandboxes-external) echo 'langsmith_domain=langsmith.values-test.dev' ;;
  esac
}

# Prints the hostname init-values.sh must write for a case.
case_hostname() {
  case "$1" in
    ip) echo 34.0.0.10 ;;
    sandboxes-external) echo langsmith.values-test.dev ;;
    *) echo langsmith.example.com ;;
  esac
}

# make_case <name> <dir>: writes the fixture of a case into <dir>.
make_case() {
  local name="$1" dir="$2" line
  mkdir -p "$dir/infra/outputs" "$dir/values" "$dir/plan"
  { case_tfvars "$name"; printf '%s\n' "$BASE_TFVARS"; } > "$dir/infra/terraform.tfvars"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s' "${line#*=}" > "$dir/infra/outputs/${line%%=*}"
  done <<< "$(printf '%s\n' "$BASE_OUTPUTS"; case_outputs "$name")"
  if grep -q '^enable_smithdb = true' "$dir/infra/terraform.tfvars"; then
    printf '%s\n' "$SMITHDB_HELM_VALUES" > "$dir/infra/outputs/smithdb_helm_values"
  fi
}

# run_init <dir>: runs init-values.sh for the case in <dir>, without a terminal.
run_init() {
  PATH="$STUB_BIN:$PATH" LANGSMITH_INFRA_DIR="$1/infra" LANGSMITH_VALUES_DIR="$1/values" \
    LANGSMITH_VALUES_PLAN_DIR="$1/plan" NAMESPACE=langsmith \
    bash "$SCRIPT_DIR/init-values.sh" < /dev/null > "$1/init.log" 2>&1
}

# render <dir> <out>: the chart with the two files, as deploy.sh applies them.
render() {
  helm template langsmith "$chart" --namespace langsmith \
    -f "$1/values/$_VALUES_BASE" -f "$1/values/$_VALUES_OVERRIDES" \
    --set-string "images.sandboxHostImage.tag=$app_version" > "$2" 2> "$2.err"
}

# value <dir> <key>...: a value from the two files of a case.
value() {
  local dir="$1"
  shift
  _values_get "$dir/values/$_VALUES_BASE" "$dir/values/$_VALUES_OVERRIDES" -- "$@"
}

# deploy_checks <dir>: the checks deploy.sh runs on the two files before it
# touches the cluster.
deploy_checks() (
  # shellcheck disable=SC2034  # _parse_tfvar reads it
  INFRA_DIR="$1/infra"
  PATH="$STUB_BIN:$PATH"
  _values_check "$MODULE_DIR" "$1/values" || exit 1
  domain=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_domain 2>/dev/null) || domain=$(_parse_tfvar langsmith_domain)
  drift=$(_values_resolved_drift "$1/values/$_VALUES_OVERRIDES" "langsmith_domain=$domain")
  [[ -z "$drift" ]] || { echo "$drift" >&2; exit 1; }
)

# same_values <dir>: the two files give Helm the same values as the sources that
# init-values.sh merged, layered one by one after the base values.
same_values() {
  local dir="$1" line
  local layered=(-f "$EXAMPLES_DIR/$_VALUES_BASE")
  while IFS= read -r line; do
    layered+=("$line")
  done < "$dir/plan/args"
  _values_merge "$dir/layered.yaml" "${layered[@]}" \
    && _values_merge "$dir/merged.yaml" -f "$dir/values/$_VALUES_BASE" -f "$dir/values/$_VALUES_OVERRIDES" \
    && cmp -s "$dir/layered.yaml" "$dir/merged.yaml"
}

# ── Manifest helpers ──────────────────────────────────────────────────────────
# Prints the manifest with this kind and metadata.name, or nothing.
manifest() {
  awk -v kind="$2" -v name="$3" '
    function flush() {
      if (k == kind && n == name) printf "%s", doc
      doc = ""; k = ""; n = ""; top = ""
    }
    /^---/ { flush(); next }
    { doc = doc $0 "\n" }
    /^[^ #]/ { top = $1 }
    /^kind:/ { k = $2 }
    top == "metadata:" && /^  name:/ && n == "" { n = $2; gsub(/"/, "", n) }
    END { flush() }
  ' "$1"
}

has() {
  [[ -n "$(manifest "$1" "$2" "$3")" ]]
}

# The ServiceAccount carries the Workload Identity annotation.
expect_identity() {
  local out="$1" name="$2" sa="$3"
  manifest "$out" ServiceAccount "$name" | grep -qF "iam.gke.io/gcp-service-account: $sa" ||
    { echo "$name: the ServiceAccount does not carry $sa"; return 1; }
}

# The feature examples merge after the sizing profile: each hostBackend
# autoscaling setting that both the agent-deploys example and the profile set
# comes from the example, and a backend setting only the profile sets comes from
# the profile.
expect_order() {
  local dir="$1" profile="$2" path want got
  for path in "autoscaling hpa minReplicas" "autoscaling hpa maxReplicas"; do
    # shellcheck disable=SC2086 # one key per word
    want=$(_values_get "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml" -- hostBackend $path) || continue
    # shellcheck disable=SC2086
    got=$(value "$dir" hostBackend $path || true)
    [[ "$got" == "$want" ]] || echo "hostBackend.${path// /.} is $got, and the agent-deploys example sets $want"
  done
  for path in "autoscaling hpa minReplicas" "deployment resources requests cpu"; do
    # shellcheck disable=SC2086
    want=$(_values_get "$EXAMPLES_DIR/langsmith-values-sizing-$profile.yaml" -- backend $path) || continue
    # shellcheck disable=SC2086
    got=$(value "$dir" backend $path || true)
    [[ "$got" == "$want" ]] || echo "backend.${path// /.} is $got, and the $profile profile sets $want"
  done
}

# ── Checks for each case ──────────────────────────────────────────────────────
# check_case <name> <dir> <out>: prints one line for each problem.
check_case() {
  local name="$1" dir="$2" out="$3" spec key tfvars want_host want_url
  tfvars=" $(case_tfvars "$name" | tr '\n' ' ')"
  want_host=$(case_hostname "$name")
  want_url="https://$want_host"
  [[ "$name" != tls-none ]] || want_url="http://$want_host"
  [[ "$(value "$dir" config hostname || true)" == "$want_host" ]] || echo "config.hostname is not $want_host"
  [[ "$(value "$dir" config deployment url || true)" == "$want_url" ]] || echo "config.deployment.url is not $want_url"
  [[ "$(value "$dir" config existingSecretName || true)" == langsmith-config ]] ||
    echo "config.existingSecretName is not langsmith-config"
  for key in $INLINE_SECRET_KEYS; do
    # shellcheck disable=SC2086 # one key per word
    ! value "$dir" ${key//./ } >/dev/null 2>&1 || echo "$key is set in a values file; the chart must read it from langsmith-config"
  done
  [[ "$(value "$dir" gateway name || true)" == vt-test-gateway ]] || echo "gateway.name is not vt-test-gateway"
  expect_identity "$out" langsmith-backend "$WI_SA" || true
  for spec in polly:polly insights:insights fleet:fleet; do
    if [[ "$tfvars" == *" enable_${spec%%:*} = true "* || "$tfvars" == *" enable_standalone_${spec%%:*} = true "* ]]; then
      has "$out" Deployment "langsmith-standalone-${spec#*:}-api-server" || echo "${spec%%:*} is on, but its api-server is not rendered"
    else
      ! has "$out" Deployment "langsmith-standalone-${spec#*:}-api-server" || echo "${spec%%:*} is off, but its api-server is rendered"
    fi
  done
  if [[ "$tfvars" == *" enable_deployments = true "* ]]; then
    for spec in host-backend listener operator; do
      has "$out" Deployment "langsmith-$spec" || echo "langsmith-$spec: no Deployment rendered"
    done
  fi

  case "$name" in
    default|ip)
      has "$out" HTTPRoute langsmith || echo "Envoy Gateway: no HTTPRoute rendered"
      has "$out" StatefulSet langsmith-clickhouse || echo "in-cluster ClickHouse: no StatefulSet rendered"
      ! has "$out" Deployment langsmith-host-backend || echo "Deployments are off, but host-backend is rendered"
      [[ "$(value "$dir" postgres external existingSecretName || true)" == langsmith-postgres-credentials ]] ||
        echo "postgres.external.existingSecretName is not langsmith-postgres-credentials"
      [[ "$(value "$dir" config blobStorage bucketName || true)" == values-test-blob ]] || echo "config.blobStorage.bucketName is not values-test-blob"
      [[ "$(_values_resolved "$dir/values/$_VALUES_OVERRIDES" langsmith_domain)" == "$([[ "$name" == ip ]] || echo langsmith.example.com)" ]] ||
        echo "the header does not record the langsmith_domain output"
      ;;
    deployments|tls-none)
      [[ "$(value "$dir" config deployment tlsEnabled || true)" == "$([[ "$name" == tls-none ]] && echo false || echo true)" ]] ||
        echo "config.deployment.tlsEnabled does not follow tls_certificate_source"
      ;;
    agent-builder)
      [[ "$(value "$dir" config agentBuilder enabled || true)" == true ]] || echo "config.agentBuilder.enabled is not true"
      ;;
    fleet)
      [[ "$(value "$dir" hostBackend enabled || true)" == true ]] || echo "Fleet is on, but hostBackend.enabled is not true"
      has "$out" Deployment langsmith-host-backend || echo "Fleet is on, but host-backend is not rendered"
      _values_notes "$dir/values/$_VALUES_OVERRIDES" set | grep -q 'set hostBackend.enabled' ||
        echo "the header does not record the hostBackend.enabled setting"
      ;;
    insights)
      has "$out" StatefulSet langsmith-clickhouse || echo "in-cluster ClickHouse: no StatefulSet rendered"
      [[ "$(value "$dir" clickhouse external enabled || true)" == false ]] || echo "in-cluster ClickHouse: clickhouse.external.enabled is not false"
      ;;
    clickhouse-external)
      ! has "$out" StatefulSet langsmith-clickhouse || echo "external ClickHouse: the chart still runs its StatefulSet"
      manifest "$out" Deployment langsmith-backend | grep -A5 'name: CLICKHOUSE_HOST$' | grep -q 'name: langsmith-clickhouse$' ||
        echo "external ClickHouse: the backend does not read CLICKHOUSE_HOST from the Secret langsmith-clickhouse"
      ;;
    standalone-polly|standalone-insights)
      grep -q "name: langsmith-${name#standalone-}-postgres\$" "$out" || echo "nothing reads the Secret langsmith-${name#standalone-}-postgres"
      ;;
    sandboxes)
      [[ "$(value "$dir" sandboxes juicefs existingSecretName || true)" == juicefs-csi-config ]] ||
        echo "sandboxes.juicefs.existingSecretName is not juicefs-csi-config"
      [[ "$(value "$dir" sandboxes sandboxHost serviceAccount annotations iam.gke.io/gcp-service-account || true)" == "$WI_SA" ]] ||
        echo "sandbox-host does not carry the Workload Identity annotation"
      [[ ! -f "$dir/values/langsmith-sandbox-values-overrides.yaml" ]] || echo "an in-cluster runtime wrote the sandbox runtime file"
      ;;
    sandboxes-external)
      [[ "$(value "$dir" sandboxes external enabled || true)" == true ]] || echo "sandboxes.external.enabled is not true"
      [[ "$(value "$dir" sandboxes serviceAuth secretKey || true)" == sandbox_service_auth_secret ]] ||
        echo "sandboxes.serviceAuth.secretKey is not sandbox_service_auth_secret"
      grep -q "endpoint: \"https://$want_host/api\"" "$dir/values/langsmith-sandbox-values-overrides.yaml" 2>/dev/null ||
        echo "the sandbox runtime file is missing or does not point at https://$want_host/api"
      ;;
    smithdb)
      [[ "$(value "$dir" smithdb resourceTier || true)" == medium ]] ||
        echo "smithdb.resourceTier is not medium, the tier of the smithdb_helm_values output"
      [[ "$(value "$dir" smithdb config objectStore bucket || true)" == values-test-smithdb ]] ||
        echo "smithdb.config.objectStore.bucket is not values-test-smithdb"
      [[ "$(value "$dir" smithdb serviceAccount annotations iam.gke.io/gcp-service-account || true)" == "$SMITHDB_SA" ]] ||
        echo "SmithDB does not carry its Workload Identity annotation"
      manifest "$out" Deployment langsmith-smithdb-query | grep -q 'name: cloud-sql-proxy' ||
        echo "SmithDB query has no Cloud SQL Auth Proxy sidecar"
      ;;
    sizing-production) expect_order "$dir" production ;;
    sizing-minimum) expect_order "$dir" minimum ;;
    sso)
      [[ "$(value "$dir" config oauth enabled || true)" == true ]] || echo "config.oauth.enabled is not true"
      [[ "$(value "$dir" config basicAuth enabled || true)" == false ]] || echo "config.basicAuth.enabled is not false"
      manifest "$out" Deployment langsmith-backend | grep -A4 'name: OAUTH_CLIENT_ID$' | grep -q 'name: langsmith-config$' ||
        echo "the backend does not read OAUTH_CLIENT_ID from the Secret langsmith-config"
      ;;
    in-cluster-db)
      [[ "$(value "$dir" postgres external enabled || true)" == false ]] || echo "postgres.external.enabled is not false"
      [[ -z "$(value "$dir" postgres external existingSecretName || true)" ]] || echo "postgres.external.existingSecretName is not empty"
      has "$out" StatefulSet langsmith-postgres || echo "in-cluster Postgres: no StatefulSet rendered"
      has "$out" StatefulSet langsmith-redis || echo "in-cluster Redis: no StatefulSet rendered"
      ;;
    all)
      expect_order "$dir" production
      [[ "$(value "$dir" smithdb resourceTier || true)" == medium ]] || echo "smithdb.resourceTier is not medium"
      [[ "$(value "$dir" config oauth enabled || true)" == true ]] || echo "config.oauth.enabled is not true"
      ;;
  esac
}

failures=0
report() {
  local label="$1"
  shift
  if (( $# )); then
    echo "FAIL: $label"
    printf '      %s\n' "$@"
    failures=$((failures + 1))
  else
    echo "PASS: $label"
  fi
}

# ── The cases ─────────────────────────────────────────────────────────────────
for name in $CASES; do
  dir="$TEST_TMP/case-$name"
  make_case "$name" "$dir"
  problems=()
  if ! run_init "$dir"; then
    problems+=("init-values.sh failed:")
    while IFS= read -r line; do problems+=("  $line"); done < <(tail -n 15 "$dir/init.log")
    report "$name" "${problems[@]}"
    continue
  fi
  written=$(cd "$dir/values" && LC_ALL=C ls)
  want="$_VALUES_BASE"$'\n'"$_VALUES_OVERRIDES"
  [[ "$name" != sandboxes-external ]] || want="langsmith-sandbox-values-overrides.yaml"$'\n'"$want"
  [[ "$written" == "$(LC_ALL=C sort <<< "$want")" ]] || problems+=("helm/values holds ${written//$'\n'/, }")
  ! grep -qF "$SECRET_MARK" "$dir/values/$_VALUES_BASE" "$dir/values/$_VALUES_OVERRIDES" ||
    problems+=("a secret reached a values file")
  out="$dir/render.yaml"
  if ! render "$dir" "$out"; then
    problems+=("the chart rejected the two files: $(head -1 "$out.err")")
    report "$name" "${problems[@]}"
    continue
  fi
  same_values "$dir" || problems+=("the two files do not give the values of their sources layered one by one")
  deploy_checks "$dir" 2> "$dir/check.err" || problems+=("deploy.sh's checks stop: $(head -1 "$dir/check.err")")
  mkdir -p "$dir/first"
  cp "$dir/values/$_VALUES_BASE" "$dir/values/$_VALUES_OVERRIDES" "$dir/first/"
  if ! run_init "$dir"; then
    problems+=("a second run of init-values.sh failed: $(tail -n 1 "$dir/init.log")")
  elif ! cmp -s "$dir/first/$_VALUES_OVERRIDES" "$dir/values/$_VALUES_OVERRIDES" \
    || ! cmp -s "$dir/first/$_VALUES_BASE" "$dir/values/$_VALUES_BASE"; then
    problems+=("a second run wrote different files")
  fi
  while IFS= read -r msg; do
    [[ -z "$msg" ]] || problems+=("$msg")
  done < <(check_case "$name" "$dir" "$out")
  report "$name" ${problems[@]+"${problems[@]}"}
done

# ── langsmith-values-local.yaml, hand edits, inputs and the 0.17 layout ───────
dir="$TEST_TMP/edits"
make_case sizing-production "$dir"
printf 'enable_fleet = true\n' | cat - "$dir/infra/terraform.tfvars" > "$dir/tfvars" && mv "$dir/tfvars" "$dir/infra/terraform.tfvars"
problems=()
run_init "$dir" || problems+=("init-values.sh failed: $(tail -n 1 "$dir/init.log")")
printf 'backend:\n  autoscaling:\n    hpa:\n      minReplicas: 7\nhostBackend:\n  enabled: false\n' > "$dir/values/$_VALUES_LOCAL"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after the local file was added")
grep -q "$_VALUES_LOCAL was added" "$dir/check.err" || problems+=("the checks do not name the added local file")
run_init "$dir" || problems+=("init-values.sh failed with a local file: $(tail -n 1 "$dir/init.log")")
[[ "$(value "$dir" backend autoscaling hpa minReplicas || true)" == 7 ]] ||
  problems+=("the local file does not win over the sizing profile")
[[ "$(value "$dir" hostBackend enabled || true)" == true ]] || problems+=("the local file turned off host-backend while Fleet is on")
deploy_checks "$dir" 2> "$dir/check.err" || problems+=("deploy.sh's checks stop after init-values.sh merged the local file")
cp "$dir/values/$_VALUES_OVERRIDES" "$dir/kept.yaml"
run_init "$dir" || problems+=("init-values.sh failed on a re-run: $(tail -n 1 "$dir/init.log")")
cmp -s "$dir/kept.yaml" "$dir/values/$_VALUES_OVERRIDES" || problems+=("a re-run with the local file wrote different bytes")
report "langsmith-values-local.yaml is merged last, survives a re-run, and cannot turn off host-backend under Fleet" ${problems[@]+"${problems[@]}"}

problems=()
printf 'extraKey: by-hand\n' >> "$dir/values/$_VALUES_OVERRIDES"
cp "$dir/values/$_VALUES_OVERRIDES" "$dir/edited.yaml"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass on a hand-edited file")
grep -q 'was edited after make init-values wrote it' "$dir/check.err" || problems+=("the checks do not say the file was edited")
run_init "$dir" && problems+=("init-values.sh overwrote a hand-edited file")
grep -q '^ *+extraKey: by-hand$' "$dir/init.log" || problems+=("init-values.sh does not print the hand edit")
cmp -s "$dir/edited.yaml" "$dir/values/$_VALUES_OVERRIDES" || problems+=("init-values.sh changed the hand-edited file")
report "a hand edit stops init-values.sh and deploy.sh, and is printed, not lost" ${problems[@]+"${problems[@]}"}

problems=()
rm -f "$dir/values/$_VALUES_OVERRIDES"
run_init "$dir" || problems+=("init-values.sh failed: $(tail -n 1 "$dir/init.log")")
printf 'enable_polly = true\nenable_deployments = true\n' | cat - "$dir/infra/terraform.tfvars" > "$dir/tfvars" && mv "$dir/tfvars" "$dir/infra/terraform.tfvars"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after a terraform.tfvars change")
grep -q 'terraform.tfvars has enable_polly = "true"' "$dir/check.err" || problems+=("the checks do not name enable_polly")
report "a terraform.tfvars change after make init-values stops deploy.sh" ${problems[@]+"${problems[@]}"}

problems=()
dir="$TEST_TMP/domain"
make_case default "$dir"
run_init "$dir" || problems+=("init-values.sh failed: $(tail -n 1 "$dir/init.log")")
printf 'other.example.com' > "$dir/infra/outputs/langsmith_domain"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after the langsmith_domain output changed")
grep -q 'Terraform now resolves langsmith_domain to "other.example.com"' "$dir/check.err" ||
  problems+=("the checks do not name langsmith_domain")
run_init "$dir" || problems+=("init-values.sh failed after the domain changed: $(tail -n 1 "$dir/init.log")")
[[ "$(value "$dir" config hostname || true)" == other.example.com ]] ||
  problems+=("a re-run does not replace the hostname with the new langsmith_domain")
report "a langsmith_domain change after make init-values stops deploy.sh, and a re-run takes it" ${problems[@]+"${problems[@]}"}

# deploy.sh rewrites the hostname of an IP-based install when the Gateway IP
# changed. The file stays sealed, its inputs stay the same, and a later run of
# make init-values keeps the new address.
problems=()
dir="$TEST_TMP/gateway-ip"
make_case ip "$dir"
run_init "$dir" || problems+=("init-values.sh failed: $(tail -n 1 "$dir/init.log")")
_values_set_strings "$dir/values/$_VALUES_OVERRIDES" "config.hostname=34.0.0.20" \
  "config.deployment.url=https://34.0.0.20" 2> "$dir/set.err" || problems+=("_values_set_strings failed: $(head -1 "$dir/set.err")")
[[ "$(value "$dir" config hostname || true)" == 34.0.0.20 ]] || problems+=("the hostname is not the new Gateway IP")
[[ "$(value "$dir" config deployment url || true)" == https://34.0.0.20 ]] || problems+=("config.deployment.url is not the new Gateway IP")
deploy_checks "$dir" 2> "$dir/check.err" || problems+=("deploy.sh's checks stop after the Gateway IP refresh: $(head -1 "$dir/check.err")")
run_init "$dir" || problems+=("init-values.sh failed after the refresh: $(tail -n 1 "$dir/init.log")")
[[ "$(value "$dir" config hostname || true)" == 34.0.0.20 ]] || problems+=("a re-run of init-values.sh lost the refreshed Gateway IP")
report "the Gateway IP refresh keeps the file sealed and current" ${problems[@]+"${problems[@]}"}

problems=()
dir="$TEST_TMP/legacy"
make_case deployments "$dir"
printf 'config:\n  hostname: "langsmith.example.com"\n  apiKeySalt: "%s"\n' "$SECRET_MARK" > "$dir/values/values-overrides.yaml"
cp "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml" "$dir/values/"
printf 'backend: {}\n' > "$dir/values/langsmith-values-sizing-production.yaml"
cp "$EXAMPLES_DIR/$_VALUES_BASE" "$dir/values/values.yaml"
run_init "$dir" && problems+=("init-values.sh ran with 0.17 files in helm/values")
grep -q 'holds values files from the 0.17 layout' "$dir/init.log" || problems+=("init-values.sh does not name the 0.17 layout")
grep -q 'values-overrides.yaml .*written by make init-values on 0.17' "$dir/init.log" ||
  problems+=("the message does not mark the 0.17 overrides file")
grep -q 'values-overrides.yaml can hold plaintext secrets' "$dir/init.log" ||
  problems+=("the message does not warn that the 0.17 overrides file can hold secrets")
grep -q 'langsmith-values-agent-deploys.yaml .*same as examples/langsmith-values-agent-deploys.yaml' "$dir/init.log" ||
  problems+=("the message does not mark the unchanged agent-deploys copy")
grep -q 'langsmith-values-sizing-production.yaml .*differs from examples/langsmith-values-sizing-production.yaml' "$dir/init.log" ||
  problems+=("the message does not mark the changed sizing copy")
! grep -qF "$SECRET_MARK" "$dir/init.log" || problems+=("the message prints a value from the 0.17 file")
[[ ! -f "$dir/values/$_VALUES_OVERRIDES" ]] || problems+=("init-values.sh wrote the overrides file anyway")
deploy_checks "$dir" 2> /dev/null && problems+=("deploy.sh's checks pass with 0.17 files in helm/values")
report "files from the 0.17 layout stop init-values.sh and deploy.sh" ${problems[@]+"${problems[@]}"}

# deploy.sh hands Helm the two values files and no other: no values file in
# VALUES_ARGS or in the helm upgrade of the LangSmith release besides them.
problems=()
awk '
  /VALUES_ARGS\+?=\(/ { a = 1 }
  /helm upgrade --install "\$RELEASE_NAME"/ { u = 1 }
  a || u { print }
  a && /\)/ { a = 0 }
  u && !/\\$/ { u = 0 }
' "$SCRIPT_DIR/deploy.sh" > "$TEST_TMP/deploy-values-args"
found=$(grep -oE -- '(^|[[:space:](])(-f|--values|--set-file)[ =]"?[^ )]*' "$TEST_TMP/deploy-values-args" | sed -E 's/^[[:space:](]//') || true
[[ "$(grep -c . <<< "$found")" == 2 ]] ||
  problems+=("deploy.sh passes these values files to the LangSmith release: ${found//$'\n'/, }; want only the two files")
report "deploy.sh applies only the two values files" ${problems[@]+"${problems[@]}"}

# ── The example files ─────────────────────────────────────────────────────────
problems=()
for profile in minimum dev production production-large; do
  [[ -f "$EXAMPLES_DIR/langsmith-values-sizing-$profile.yaml" ]] ||
    problems+=("sizing_profile = $profile has no examples/langsmith-values-sizing-$profile.yaml")
done
report "each sizing_profile has its example" ${problems[@]+"${problems[@]}"}

if (( failures )); then
  echo "$failures values check(s) failed"
  exit 1
fi
