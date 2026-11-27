#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Runs init-values.sh for each case below and checks the two values files it
# writes against the LangSmith chart. No cluster and no Azure calls: init-values.sh
# runs for real, with stub terraform, kubectl and az commands that answer from a
# fixture terraform.tfvars and fixture Terraform outputs.
#
# Each case checks the settings its flags control, and also that:
#   - init-values.sh writes langsmith-values.yaml and langsmith-values-overrides.yaml,
#     and the chart accepts the two as deploy.sh applies them;
#   - the two files give Helm the same values as their sources layered one by one;
#   - no secret reaches either file;
#   - a second run writes the same bytes, and the checks of deploy.sh pass.
# Further checks cover langsmith-values-local.yaml, a hand edit, a terraform.tfvars
# change, a Terraform output change, the 0.17 layout, and the sizing examples.
#
# Requires helm, and network access to fetch the chart unless LANGSMITH_CHART
# names a local chart directory or archive.
# Usage: bash modules/azure/helm/scripts/test-values.sh
#        CHART_VERSION=0.18.5 bash modules/azure/helm/scripts/test-values.sh
# Exit 0 pass, 1 a failing check, 2 the test could not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXAMPLES_DIR="$MODULE_DIR/helm/values/examples"
CHART_REPO="https://langchain-ai.github.io/helm"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is not installed" >&2; exit 2; }
REAL_HELM=$(command -v helm)

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
helm show values "$chart" > "$TEST_TMP/chart-values.yaml"

# _parse_tfvar reads $INFRA_DIR/terraform.tfvars; each case sets INFRA_DIR.
INFRA_DIR="$TEST_TMP/no-case"
source "$MODULE_DIR/infra/scripts/_common.sh"
# shellcheck source=_values.sh
source "$SCRIPT_DIR/_values.sh"

# ── Stub commands ─────────────────────────────────────────────────────────────
STUB_BIN="$TEST_TMP/bin"
mkdir -p "$STUB_BIN"
# terraform [-chdir=<infra>] output -raw|-json <name> answers from <infra>/outputs/
# (the working directory without -chdir) and fails, as an empty state does, for
# a missing output or any other command.
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
# init-values.sh reaches the cluster only for an external ClickHouse Secret that
# Terraform does not own, which no case uses.
cat > "$STUB_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "values test: unexpected kubectl $*" >&2
exit 1
STUB
# The SSO client secrets are in Key Vault.
cat > "$STUB_BIN/az" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "keyvault secret show "*) echo values-test; exit 0 ;;
esac
echo "values test: unexpected az $*" >&2
exit 1
STUB
# init-values.sh reads the chart's images block from the Helm repository when a
# mirror is set. The chart under test answers instead, and nothing touches the
# Helm repository configuration.
cat > "$STUB_BIN/helm" <<STUB
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "repo add"|"repo update") exit 0 ;;
  "show values")
    if [[ "\${3:-}" == langchain/langsmith ]]; then
      exec "$REAL_HELM" show values "$chart"
    fi
    ;;
esac
exec "$REAL_HELM" "\$@"
STUB
chmod +x "$STUB_BIN/terraform" "$STUB_BIN/kubectl" "$STUB_BIN/az" "$STUB_BIN/helm"

# The secrets setup-env.sh writes. None of them may reach a values file.
SECRET_MARK="values-test-secret"
SECRETS_TFVARS="langsmith_license_key = \"$SECRET_MARK-license\"
postgres_admin_password = \"$SECRET_MARK-postgres\"
smithdb_metastore_admin_password = \"$SECRET_MARK-smithdb\"
clickhouse_password = \"$SECRET_MARK-clickhouse\""
export TF_VAR_langsmith_license_key="$SECRET_MARK-license"
export TF_VAR_postgres_admin_password="$SECRET_MARK-postgres"
export LANGSMITH_LICENSE_KEY="$SECRET_MARK-license"
export LANGSMITH_ADMIN_PASSWORD="$SECRET_MARK-password"

# ── Fixtures ──────────────────────────────────────────────────────────────────
BASE_TFVARS='name_prefix = "values-test"
environment = "test"
location = "eastus"
tls_certificate_source = "letsencrypt"
langsmith_domain = "langsmith.example.com"
postgres_source = "external"
redis_source = "external"'
# name=value; a name ending in .json answers terraform output -json.
WI_CLIENT_ID="00000000-0000-0000-0000-00000000000a"
SMITHDB_CLIENT_ID="00000000-0000-0000-0000-00000000000b"
SANDBOX_CLIENT_ID="00000000-0000-0000-0000-00000000000c"
JUICEFS_DIGEST="0123456789abcdef0123456789abcdef"
BASE_OUTPUTS="storage_account_name=valuestestblob
storage_container_name=langsmith
storage_account_k8s_managed_identity_client_id=$WI_CLIENT_ID
langsmith_admin_email=admin@example.com
langsmith_namespace=langsmith
aks_cluster_name=values-test-aks
keyvault_name=values-test-kv
redis_cluster_enabled=false
clickhouse_cluster.json=\"replicated\"
smithdb_storage_account_name=valuestestsmithdb
smithdb_storage_container_name=smithdb
smithdb_workload_identity_client_id=$SMITHDB_CLIENT_ID
smithdb_metastore_secret_name=smithdb-metastore
smithdb_metastore_auth_mode=password
smithdb_cache_storage_class_name=smithdb-premium-v2
sandbox_host_workload_identity_client_id=$SANDBOX_CLIENT_ID
sandbox_juicefs_secret_name=juicefs-csi-config
sandbox_host_min_replicas=1
sandbox_host_max_replicas=3
sandbox_juicefs_redis_config_digest=$JUICEFS_DIGEST
sandbox_cluster_name=values-test-sandbox
sandbox_service_account_name=langsmith-sandbox-host
sandbox_runtime_secret_name=langsmith-sandbox-runtime"
# terraform output -raw smithdb_helm_values, as yamlencode writes it.
SMITHDB_HELM_VALUES='"smithdb":
  "resourceTier": "medium"'

CASES="default deployments tls-none agent-builder fleet insights polly clickhouse-external llm-gateway sandboxes smithdb sizing-minimum sizing-production istio istio-addon agic none sso mirror redis-cluster all"
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
    fleet) printf '%s\n' 'enable_deployments = true' 'enable_fleet = true' ;;
    insights) echo 'enable_insights = true' ;;
    polly) printf '%s\n' 'enable_deployments = true' 'enable_polly = true' ;;
    clickhouse-external) printf '%s\n' 'enable_insights = true' 'clickhouse_source = "external"' ;;
    llm-gateway) printf '%s\n' 'enable_llm_gateway = true' 'enable_gateway_pii_redaction = true' ;;
    sandboxes) echo 'enable_sandboxes = true' ;;
    sandboxes-external) printf '%s\n' 'enable_sandboxes = true' 'sandbox_runtime_source = "external"' ;;
    smithdb) printf '%s\n' 'enable_smithdb = true' 'smithdb_ingestion_enabled = true' 'smithdb_query_enabled = true' ;;
    sizing-minimum) printf '%s\n' 'sizing_profile = "minimum"' 'enable_deployments = true' ;;
    sizing-production) printf '%s\n' 'sizing_profile = "production"' 'enable_deployments = true' ;;
    istio|istio-addon|agic|none) echo "ingress_controller = \"$1\"" ;;
    sso) echo 'enable_sso_oidc = true' ;;
    mirror) printf '%s\n' 'enable_deployments = true' 'langsmith_image_registry = "nexus.example.com"' \
      'langsmith_image_pull_secret_name = "nexus-pull"' ;;
    all) printf '%s\n' 'sizing_profile = "production"' 'enable_deployments = true' 'enable_fleet = true' \
      'enable_insights = true' 'enable_polly = true' 'enable_llm_gateway = true' \
      'enable_gateway_pii_redaction = true' 'enable_sandboxes = true' 'enable_smithdb = true' \
      'smithdb_ingestion_enabled = true' 'smithdb_query_enabled = true' 'enable_sso_oidc = true' ;;
  esac
}

# Prints the Terraform outputs a case changes, as name=value.
case_outputs() {
  case "$1" in
    clickhouse-external) echo 'clickhouse_secret_name=langsmith-clickhouse' ;;
    redis-cluster) echo 'redis_cluster_enabled=true' ;;
  esac
}

# make_case <name> <dir>: writes the fixture of a case into <dir>.
make_case() {
  local name="$1" dir="$2" line
  mkdir -p "$dir/infra/outputs" "$dir/values" "$dir/plan"
  { case_tfvars "$name"; printf '%s\n' "$BASE_TFVARS"; } > "$dir/infra/terraform.tfvars"
  printf '%s\n' "$SECRETS_TFVARS" > "$dir/infra/secrets.auto.tfvars"
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
    LANGSMITH_VALUES_PLAN_DIR="$1/plan" \
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
  # shellcheck disable=SC2034  # _parse_tfvar and _tf_out read it
  INFRA_DIR="$1/infra"
  PATH="$STUB_BIN:$PATH"
  if [[ -f "$1/values/values-overrides.yaml" ]]; then
    _stop_if_values_layout_from_old_default "$1/values/values-overrides.yaml" || exit 1
  fi
  _values_check "$MODULE_DIR" "$1/values" || exit 1
  resolved=("clickhouse_cluster=$(_clickhouse_cluster_resolved || true)")
  if [[ "$(_parse_tfvar enable_sandboxes || true)" == "true" \
    && "$(_parse_tfvar sandbox_runtime_source || echo in-cluster)" != "external" ]]; then
    resolved+=("sandbox_juicefs_redis_config_digest=$(_tf_out sandbox_juicefs_redis_config_digest || true)")
  fi
  drift=$(_values_resolved_drift "$1/values/$_VALUES_OVERRIDES" "${resolved[@]}")
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

# The ServiceAccount carries the Workload Identity client ID.
expect_identity() {
  local out="$1" name="$2" client_id="$3"
  manifest "$out" ServiceAccount "$name" | grep -qF "azure.workload.identity/client-id: $client_id" ||
    { echo "$name: the ServiceAccount does not carry the client ID $client_id"; return 1; }
}

# The Ingress of the release uses this class, or none when <class> is empty.
expect_ingress_class() {
  local out="$1" class="$2" m
  m=$(manifest "$out" Ingress langsmith-ingress)
  [[ -n "$m" ]] || { echo "no Ingress rendered"; return 1; }
  if [[ -n "$class" ]]; then
    grep -q "ingressClassName: \"\?$class\"\?$" <<< "$m" || { echo "the Ingress does not use the class $class"; return 1; }
  else
    ! grep -qE 'ingressClassName: *"?[^" ]' <<< "$m" || { echo "the Ingress names a class"; return 1; }
  fi
}

# The sizing profile merges after the feature examples: each hostBackend setting
# that both the agent-deploys example and the profile set comes from the profile.
expect_profile_wins() {
  local dir="$1" profile="$2" path want got
  for path in "deployment resources requests cpu" "deployment resources requests memory" "autoscaling hpa enabled"; do
    # shellcheck disable=SC2086 # one key per word
    want=$(_values_get "$EXAMPLES_DIR/langsmith-values-sizing-$profile.yaml" -- hostBackend $path) || continue
    # shellcheck disable=SC2086
    got=$(value "$dir" hostBackend $path || true)
    [[ "$got" == "$want" ]] || echo "hostBackend.${path// /.} is $got, and the $profile profile sets $want"
  done
}

# ── Checks for each case ──────────────────────────────────────────────────────
# check_case <name> <dir> <out>: prints one line for each problem.
check_case() {
  local name="$1" dir="$2" out="$3" spec want_url="https://langsmith.example.com" tfvars templates
  tfvars=" $(case_tfvars "$name" | tr '\n' ' ')"
  [[ "$name" != tls-none ]] || want_url="http://langsmith.example.com"
  [[ "$(value "$dir" config hostname || true)" == langsmith.example.com ]] || echo "config.hostname is not langsmith.example.com"
  [[ "$(value "$dir" config existingSecretName || true)" == langsmith-config-secret ]] ||
    echo "config.existingSecretName is not langsmith-config-secret"
  [[ "$(value "$dir" config blobStorage azureStorageAccountName || true)" == valuestestblob ]] ||
    echo "config.blobStorage.azureStorageAccountName is not valuestestblob"
  expect_identity "$out" langsmith-platform-backend "$WI_CLIENT_ID" || true
  for spec in polly:polly insights:insights fleet:fleet; do
    if [[ "$tfvars" == *" enable_${spec%%:*} = true "* ]]; then
      has "$out" Deployment "langsmith-standalone-${spec#*:}-api-server" || echo "${spec%%:*} is on, but its api-server is not rendered"
    else
      ! has "$out" Deployment "langsmith-standalone-${spec#*:}-api-server" || echo "${spec%%:*} is off, but its api-server is rendered"
    fi
  done
  if [[ "$tfvars" == *" enable_deployments = true "* ]]; then
    for spec in host-backend listener operator; do
      has "$out" Deployment "langsmith-$spec" || echo "langsmith-$spec: no Deployment rendered"
    done
    [[ "$(value "$dir" config deployment url || true)" == "$want_url" ]] || echo "config.deployment.url is not $want_url"
  fi

  case "$name" in
    default)
      has "$out" HTTPRoute langsmith || echo "Envoy Gateway: no HTTPRoute rendered"
      ! has "$out" Ingress langsmith-ingress || echo "Envoy Gateway: an Ingress is still rendered"
      has "$out" StatefulSet langsmith-clickhouse || echo "in-cluster ClickHouse: no StatefulSet rendered"
      ! has "$out" Deployment langsmith-host-backend || echo "Deployments are off, but host-backend is rendered"
      [[ "$(value "$dir" redis external clusterSafeMode || true)" == true ]] || echo "redis.external.clusterSafeMode is not true"
      ;;
    deployments|tls-none)
      [[ "$(value "$dir" config deployment tlsEnabled || true)" == "$([[ "$name" == tls-none ]] && echo false || echo true)" ]] ||
        echo "config.deployment.tlsEnabled does not follow tls_certificate_source"
      ;;
    agent-builder)
      [[ "$(value "$dir" config agentBuilder enabled || true)" == true ]] || echo "config.agentBuilder.enabled is not true"
      ;;
    fleet)
      [[ "$(value "$dir" config agentBuilder enabled || true)" == false ]] || echo "Fleet is on, but config.agentBuilder.enabled is not false"
      grep -q 'name: langsmith-fleet-postgres$' "$out" || echo "nothing reads the Secret langsmith-fleet-postgres"
      ;;
    clickhouse-external)
      ! has "$out" StatefulSet langsmith-clickhouse || echo "external ClickHouse: the chart still runs its StatefulSet"
      manifest "$out" Deployment langsmith-backend | grep -A5 'name: CLICKHOUSE_HOST$' | grep -q 'name: langsmith-clickhouse$' ||
        echo "external ClickHouse: the backend does not read CLICKHOUSE_HOST from the Secret langsmith-clickhouse"
      [[ "$(value "$dir" clickhouse external cluster || true)" == replicated ]] || echo "clickhouse.external.cluster is not replicated"
      ;;
    llm-gateway)
      [[ "$(value "$dir" agentGateway enabled || true)" == true ]] || echo "agentGateway.enabled is not true"
      [[ "$(value "$dir" presidioAnalyzer enabled || true)" == true ]] || echo "presidioAnalyzer.enabled is not true"
      [[ "$(value "$dir" agentGateway serviceAccount annotations azure.workload.identity/client-id || true)" == "$WI_CLIENT_ID" ]] ||
        echo "the LLM Gateway does not carry the Workload Identity client ID"
      ;;
    sandboxes)
      [[ "$(value "$dir" sandboxes juicefs existingSecretName || true)" == juicefs-csi-config ]] ||
        echo "sandboxes.juicefs.existingSecretName is not juicefs-csi-config"
      [[ "$(value "$dir" sandboxes sandboxHost deployment podAnnotations checksum/juicefs-redis || true)" == "$JUICEFS_DIGEST" ]] ||
        echo "the sandbox-host pods do not carry the JuiceFS Redis digest"
      grep -q "checksum/juicefs-redis: \"\?$JUICEFS_DIGEST\"\?" "$out" || echo "the JuiceFS Redis digest is not rendered"
      [[ ! -f "$dir/values/langsmith-sandbox-values-overrides.yaml" ]] || echo "an in-cluster runtime wrote the sandbox runtime file"
      ;;
    sandboxes-external)
      [[ "$(value "$dir" sandboxes external enabled || true)" == true ]] || echo "sandboxes.external.enabled is not true"
      [[ "$(value "$dir" sandboxes serviceAuth secretKey || true)" == sandbox_service_auth_secret ]] ||
        echo "sandboxes.serviceAuth.secretKey is not sandbox_service_auth_secret"
      grep -q 'endpoint: "https://langsmith.example.com/api"' "$dir/values/langsmith-sandbox-values-overrides.yaml" 2>/dev/null ||
        echo "the sandbox runtime file is missing or does not point at https://langsmith.example.com/api"
      ;;
    smithdb)
      [[ "$(value "$dir" smithdb resourceTier || true)" == medium ]] ||
        echo "smithdb.resourceTier is not medium, the tier of the smithdb_helm_values output"
      [[ "$(value "$dir" smithdb config objectStore bucket || true)" == smithdb ]] || echo "smithdb.config.objectStore.bucket is not smithdb"
      [[ "$(value "$dir" smithdb cache storageClassName || true)" == smithdb-premium-v2 ]] ||
        echo "smithdb.cache.storageClassName is not smithdb-premium-v2"
      [[ "$(value "$dir" smithdb serviceAccount annotations azure.workload.identity/client-id || true)" == "$SMITHDB_CLIENT_ID" ]] ||
        echo "SmithDB does not carry its Workload Identity client ID"
      ;;
    sizing-minimum) expect_profile_wins "$dir" minimum ;;
    sizing-production) expect_profile_wins "$dir" production ;;
    istio) expect_ingress_class "$out" istio || true ;;
    istio-addon)
      ! has "$out" Ingress langsmith-ingress || echo "istio-addon: an Ingress is still rendered"
      grep -q '^kind: VirtualService' "$out" || echo "istio-addon: no VirtualService rendered"
      ;;
    agic)
      expect_ingress_class "$out" azure-application-gateway || true
      manifest "$out" Ingress langsmith-ingress | grep -q 'cert-manager.io/cluster-issuer: "\?letsencrypt-prod"\?' ||
        echo "agic: the Ingress has no cert-manager issuer"
      ;;
    none) expect_ingress_class "$out" "" || true ;;
    sso)
      [[ "$(value "$dir" config oauth enabled || true)" == true ]] || echo "config.oauth.enabled is not true"
      [[ "$(value "$dir" config basicAuth enabled || true)" == false ]] || echo "config.basicAuth.enabled is not false"
      ;;
    mirror)
      [[ "$(value "$dir" images backendImage repository || true)" == nexus.example.com/langchain/langsmith-backend ]] ||
        echo "images.backendImage.repository does not point at the mirror"
      grep -q 'image: "\?nexus.example.com/langchain/langsmith-backend:' "$out" || echo "the backend image is not pulled from the mirror"
      templates=false
      grep -qE '^  deploymentRedisImage:' "$TEST_TMP/chart-values.yaml" || templates=true
      [[ "$(_values_resolved "$dir/values/$_VALUES_OVERRIDES" deployment_templates)" == "$templates" ]] ||
        echo "the header does not record deployment_templates = $templates for this chart"
      if [[ "$templates" == true ]]; then
        value "$dir" operator templates redis | grep -q 'image: nexus.example.com/redis:7$' ||
          echo "the per-deployment Redis template does not pull from the mirror"
      elif value "$dir" operator templates redis >/dev/null; then
        echo "a per-deployment Redis template is written for a chart that reads the images block"
      fi
      ;;
    redis-cluster)
      [[ "$(value "$dir" redis external cluster enabled || true)" == true ]] || echo "redis.external.cluster.enabled is not true"
      ;;
    all)
      expect_profile_wins "$dir" production
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
make_case sizing-minimum "$dir"
problems=()
run_init "$dir" || problems+=("init-values.sh failed: $(tail -n 1 "$dir/init.log")")
printf 'frontend:\n  deployment:\n    replicas: 3\nhostBackend:\n  deployment:\n    resources:\n      requests:\n        cpu: "750m"\n' \
  > "$dir/values/$_VALUES_LOCAL"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after the local file was added")
grep -q "$_VALUES_LOCAL was added" "$dir/check.err" || problems+=("the checks do not name the added local file")
run_init "$dir" || problems+=("init-values.sh failed with a local file: $(tail -n 1 "$dir/init.log")")
[[ "$(value "$dir" frontend deployment replicas || true)" == 3 ]] || problems+=("a key in the local file does not win")
[[ "$(value "$dir" hostBackend deployment resources requests cpu || true)" == 750m ]] ||
  problems+=("the local file does not win over the sizing profile")
deploy_checks "$dir" 2> "$dir/check.err" || problems+=("deploy.sh's checks stop after init-values.sh merged the local file")
cp "$dir/values/$_VALUES_OVERRIDES" "$dir/kept.yaml"
run_init "$dir" || problems+=("init-values.sh failed on a re-run: $(tail -n 1 "$dir/init.log")")
cmp -s "$dir/kept.yaml" "$dir/values/$_VALUES_OVERRIDES" || problems+=("a re-run with the local file wrote different bytes")
report "langsmith-values-local.yaml is merged last, wins over the sizing profile, and survives a re-run" ${problems[@]+"${problems[@]}"}

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
printf 'sizing_profile = "production"\n' | cat - "$dir/infra/terraform.tfvars" > "$dir/tfvars" && mv "$dir/tfvars" "$dir/infra/terraform.tfvars"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after a terraform.tfvars change")
grep -q 'terraform.tfvars has sizing_profile = "production"' "$dir/check.err" || problems+=("the checks do not name sizing_profile")
report "a terraform.tfvars change after make init-values stops deploy.sh" ${problems[@]+"${problems[@]}"}

problems=()
dir="$TEST_TMP/outputs"
make_case sandboxes "$dir"
run_init "$dir" || problems+=("init-values.sh failed: $(tail -n 1 "$dir/init.log")")
printf '"other"' > "$dir/infra/outputs/clickhouse_cluster.json"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after the clickhouse_cluster output changed")
grep -q 'Terraform now resolves clickhouse_cluster to "other"' "$dir/check.err" || problems+=("the checks do not name clickhouse_cluster")
printf '"replicated"' > "$dir/infra/outputs/clickhouse_cluster.json"
printf 'fedcba9876543210' > "$dir/infra/outputs/sandbox_juicefs_redis_config_digest"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after the JuiceFS Redis digest changed")
grep -q 'Terraform now resolves sandbox_juicefs_redis_config_digest to "fedcba9876543210"' "$dir/check.err" ||
  problems+=("the checks do not name the JuiceFS Redis digest")
report "a Terraform output change after make init-values stops deploy.sh" ${problems[@]+"${problems[@]}"}

problems=()
dir="$TEST_TMP/legacy"
make_case deployments "$dir"
printf 'config:\n  hostname: "langsmith.example.com"\nimages:\n  registry: ""\n' > "$dir/values/values-overrides.yaml"
cp "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml" "$dir/values/"
printf 'backend: {}\n' > "$dir/values/langsmith-values-sizing-production.yaml"
cp "$EXAMPLES_DIR/$_VALUES_BASE" "$dir/values/values.yaml"
run_init "$dir" && problems+=("init-values.sh ran with 0.17 files in helm/values")
grep -q 'holds values files from the 0.17 layout' "$dir/init.log" || problems+=("init-values.sh does not name the 0.17 layout")
grep -q 'values-overrides.yaml .*written by make init-values on 0.17' "$dir/init.log" ||
  problems+=("the message does not mark the 0.17 overrides file")
grep -q 'langsmith-values-agent-deploys.yaml .*same as examples/langsmith-values-agent-deploys.yaml' "$dir/init.log" ||
  problems+=("the message does not mark the unchanged agent-deploys copy")
grep -q 'langsmith-values-sizing-production.yaml .*differs from examples/langsmith-values-sizing-production.yaml' "$dir/init.log" ||
  problems+=("the message does not mark the changed sizing copy")
grep -q 'values.yaml .*no example of this name' "$dir/init.log" || problems+=("the message does not list the 0.17 base values")
[[ ! -f "$dir/values/$_VALUES_OVERRIDES" ]] || problems+=("init-values.sh wrote the overrides file anyway")
deploy_checks "$dir" 2> /dev/null && problems+=("deploy.sh's checks pass with 0.17 files in helm/values")
report "files from the 0.17 layout stop init-values.sh and deploy.sh" ${problems[@]+"${problems[@]}"}

# A 0.17 overrides file written while langsmith_image_registry_keeps_source_host
# defaulted to true, with the key still unset: that stop comes first, because the
# new file would change the mirror layout.
problems=()
dir="$TEST_TMP/old-default"
make_case mirror "$dir"
printf 'images:\n  registry: "nexus.example.com"\n' > "$dir/values/values-overrides.yaml"
run_init "$dir" && problems+=("init-values.sh ran with a 0.17 file from the host-kept mirror layout")
grep -q 'host-kept mirror layout' "$dir/init.log" || problems+=("init-values.sh does not name the host-kept mirror layout")
! grep -q 'holds values files from the 0.17 layout' "$dir/init.log" || problems+=("the 0.17 layout stop came first")
report "a 0.17 file from the host-kept mirror layout stops init-values.sh first" ${problems[@]+"${problems[@]}"}

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
