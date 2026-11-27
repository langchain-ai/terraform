#!/usr/bin/env bash
# Runs init-values.sh for each case below and checks the two values files it
# writes against the LangSmith chart. No cluster and no AWS calls: init-values.sh
# runs for real, with stub terraform, kubectl and aws commands that answer from a
# fixture terraform.tfvars and fixture Terraform outputs.
#
# Each case checks the settings its flags control, and also that:
#   - init-values.sh writes langsmith-values.yaml and langsmith-values-overrides.yaml,
#     and the chart accepts the two as deploy.sh applies them;
#   - the two files give Helm the same values as their sources layered one by one;
#   - no secret reaches either file, and blob storage is on with the Terraform bucket;
#   - a second run writes the same bytes, and the checks of deploy.sh pass.
# Further checks cover langsmith-values-local.yaml, a hand edit, a terraform.tfvars
# change, the 0.17 layout, and the example files.
#
# Requires helm, and network access to fetch the chart unless LANGSMITH_CHART
# names a local chart directory or archive.
# Usage: bash modules/aws/helm/scripts/test-values.sh
#        CHART_VERSION=0.18.5 bash modules/aws/helm/scripts/test-values.sh
# Exit 0 pass, 1 a failing check, 2 the test could not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXAMPLES_DIR="$MODULE_DIR/helm/values/examples"
CHART_REPO="https://langchain-ai.github.io/helm"

# The scaler or replica count each sized service gets: the scale guide's medium
# reads, medium writes pattern. The compaction worker applies only with SmithDB on.
#   keda:MIN:MAX  a KEDA ScaledObject with that replica range, and no HPA
#   hpa:MIN:MAX   a chart HorizontalPodAutoscaler with that range, and no ScaledObject
#   fixed:N       no autoscaler; the Deployment runs N replicas
EXPECTED="langsmith-queue:keda:1:10 langsmith-ingest-queue:keda:3:6 langsmith-frontend:fixed:2 langsmith-backend:hpa:8:16"
COMPACTION_WORKER="keda:1:10"
# The small tier's per-replica requests in the chart's tier table, as
# workload:cpu:memory.
SMALL_TIER="query:4:8Gi ingestion:4:8Gi compaction:2:4Gi compaction-worker:8:16Gi cluster-manager:250m:256Mi"

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
helm show values "$chart" > "$TEST_TMP/chart-values.yaml"

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
dir=""
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
# The external ClickHouse Secret exists, and the ALB Ingress has no address yet.
# CLICKHOUSE_SECRET (present, missing, error) sets the answer for the ClickHouse
# Secret, and KUBECTL_LOG names a file that records each call.
cat > "$STUB_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
[[ -z "${KUBECTL_LOG:-}" ]] || echo "kubectl $*" >> "$KUBECTL_LOG"
case "$*" in
  "get secret langsmith-clickhouse "*)
    case "${CLICKHOUSE_SECRET:-present}" in
      present) exit 0 ;;
      missing) echo 'Error from server (NotFound): secrets "langsmith-clickhouse" not found' >&2; exit 1 ;;
      *) echo 'The connection to the server localhost:8080 was refused' >&2; exit 1 ;;
    esac ;;
  "get ingress "*) exit 0 ;;
esac
echo "values test: unexpected kubectl $*" >&2
exit 1
STUB
# The SSO parameters are in SSM.
cat > "$STUB_BIN/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ssm get-parameter "*) echo values-test; exit 0 ;;
esac
echo "values test: unexpected aws $*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/terraform" "$STUB_BIN/kubectl" "$STUB_BIN/aws"

# The secrets setup-env.sh exports. None of them may reach a values file.
SECRET_MARK="values-test-secret"
export TF_VAR_langsmith_agent_builder_encryption_key="$SECRET_MARK-fleet"
export TF_VAR_langsmith_polly_encryption_key="$SECRET_MARK-polly"
export TF_VAR_langsmith_insights_encryption_key="$SECRET_MARK-insights"
export TF_VAR_langsmith_engine_encryption_key="$SECRET_MARK-engine"
export TF_VAR_langsmith_engine_usage_signing_secret="$SECRET_MARK-engine-usage"
export TF_VAR_langsmith_api_key_salt="$SECRET_MARK-salt"
export TF_VAR_langsmith_jwt_secret="$SECRET_MARK-jwt"
export TF_VAR_sandbox_callback_signing_jwk="$SECRET_MARK-jwk"
export TF_VAR_sandbox_service_auth_secret="$SECRET_MARK-service-auth"
export LANGSMITH_LICENSE_KEY="$SECRET_MARK-license"
export LANGSMITH_ADMIN_PASSWORD="$SECRET_MARK-password"

# ── Fixtures ──────────────────────────────────────────────────────────────────
# Every case starts from these. An unset SmithDB query gate is confirmed against
# the live release, so the fixture sets it.
BASE_TFVARS='name_prefix = "values-test"
environment = "test"
region = "us-west-2"
tls_certificate_source = "acm"
langsmith_domain = "langsmith.example.com"
langsmith_admin_email = "admin@example.com"
smithdb_query_enabled = true'
# name=value; a name ending in .json answers terraform output -json.
BASE_OUTPUTS='bucket_name=values-test-blob
langsmith_irsa_role_arn=arn:aws:iam::123456789012:role/values-test
alb_dns_name=values-test-alb.us-west-2.elb.amazonaws.com
alb_scheme=internet-facing
acm_certificate_arn=arn:aws:acm:us-west-2:123456789012:certificate/values-test
enable_envoy_gateway=true
smithdb_object_store_bucket=values-test-smithdb
smithdb_irsa_role_arn=arn:aws:iam::123456789012:role/values-test-smithdb
smithdb_cache_storage_class_name=smithdb-cache
smithdb_cache_storage=network-disk
sandbox_juicefs_csi_config_secret_name=juicefs-csi-config
sandbox_juicefs_host_cache_dirs.json=["/mnt/juicefs-cache0"]
sandbox_cluster_name=values-test-sandbox
sandbox_irsa_role_arn=arn:aws:iam::123456789012:role/values-test-sandbox
sandbox_runtime_secret_name=langsmith-sandbox-runtime
sandbox_service_account_name=langsmith-sandbox-host
engine_irsa_role_arn=arn:aws:iam::123456789012:role/values-test-engine'
IRSA_ROLE="arn:aws:iam::123456789012:role/values-test"
ENGINE_ROLE="arn:aws:iam::123456789012:role/values-test-engine"

CASES="default smithdb-off deployments tls-none fleet polly insights clickhouse-external engine sandboxes sso telemetry local-ssd istio alb-ingress all"
# The external sandbox runtime and the unified SmithDB layout ship with chart 0.18,
# and deploy.sh refuses an external runtime on an earlier chart.
_chart_minor=$(awk -F. '{ print $1 * 1000 + $2 }' <<< "$chart_version")
if (( _chart_minor >= 18 )); then
  CASES="$CASES sandboxes-external"
fi
if grep -qE '^  topology:' "$TEST_TMP/chart-values.yaml"; then
  CASES="$CASES local-ssd-unified"
fi

# Prints the terraform.tfvars lines of a case. They go before BASE_TFVARS, and the
# parser reads the first line of a key, so they win.
case_tfvars() {
  case "$1" in
    smithdb-off) echo 'enable_smithdb = false' ;;
    deployments) echo 'enable_deployments = true' ;;
    tls-none) printf '%s\n' 'tls_certificate_source = "none"' 'enable_deployments = true' ;;
    fleet) echo 'enable_fleet = true' ;;
    polly) echo 'enable_polly = true' ;;
    insights) echo 'enable_insights = true' ;;
    clickhouse-external) printf '%s\n' 'enable_insights = true' 'clickhouse_source = "external"' ;;
    engine) printf '%s\n' 'enable_sandboxes = true' 'enable_engine = true' ;;
    sandboxes) echo 'enable_sandboxes = true' ;;
    sandboxes-external) printf '%s\n' 'enable_sandboxes = true' 'sandbox_runtime_source = "external"' ;;
    sso) echo 'enable_sso_oidc = true' ;;
    telemetry) echo 'enable_usage_telemetry = true' ;;
    local-ssd|local-ssd-unified) echo 'smithdb_cache_storage = "local-ssd"' ;;
    istio) printf '%s\n' 'enable_envoy_gateway = false' 'enable_istio_gateway = true' ;;
    alb-ingress) echo 'enable_envoy_gateway = false' ;;
    all) printf '%s\n' 'enable_deployments = true' 'enable_fleet = true' 'enable_polly = true' \
      'enable_insights = true' 'enable_sandboxes = true' 'enable_engine = true' \
      'enable_sso_oidc = true' 'enable_usage_telemetry = true' ;;
  esac
}

# Prints the Terraform outputs a case changes, as name=value.
case_outputs() {
  case "$1" in
    local-ssd|local-ssd-unified) echo 'smithdb_cache_storage=local-ssd' ;;
    istio) printf '%s\n' 'enable_envoy_gateway=false' 'enable_istio_gateway=true' ;;
    alb-ingress) echo 'enable_envoy_gateway=false' ;;
  esac
}

# Prints the langsmith-values-local.yaml of a case, if it has one.
case_local() {
  case "$1" in
    local-ssd-unified) printf 'smithdb:\n  topology: unified\n' ;;
  esac
}

# make_case <name> <dir>: writes the fixture of a case into <dir>.
make_case() {
  local name="$1" dir="$2" line local_values
  mkdir -p "$dir/infra/outputs" "$dir/values" "$dir/plan"
  { case_tfvars "$name"; printf '%s\n' "$BASE_TFVARS"; } > "$dir/infra/terraform.tfvars"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s' "${line#*=}" > "$dir/infra/outputs/${line%%=*}"
  done <<< "$(printf '%s\n' "$BASE_OUTPUTS"; case_outputs "$name")"
  local_values=$(case_local "$name")
  [[ -z "$local_values" ]] || printf '%s\n' "$local_values" > "$dir/values/$_VALUES_LOCAL"
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
  # shellcheck disable=SC2034  # _parse_tfvar and _read_applied_flag read it
  INFRA_DIR="$1/infra"
  PATH="$STUB_BIN:$PATH"
  _stop_if_nginx_applied || exit 1
  _values_check "$MODULE_DIR" "$1/values" || exit 1
  drift=$(_values_resolved_drift "$1/values/$_VALUES_OVERRIDES" \
    "enable_envoy_gateway=$(_read_applied_flag enable_envoy_gateway false)" \
    "enable_istio_gateway=$(_read_applied_flag enable_istio_gateway false)" \
    "enable_smithdb=$(_read_applied_flag enable_smithdb true)")
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
# Prints the manifest with this kind and metadata.name, or nothing. Read its
# output whole, with grep -q PATTERN <<< "$(manifest ...)": under pipefail, a pipe
# into grep -q fails when grep exits on the first match and awk gets SIGPIPE.
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

# Prints one key directly under spec of the manifest on stdin.
spec_field() {
  awk -v key="$1:" '
    /^spec:/ { s = 1; next }
    /^[^ ]/ { s = 0 }
    s && /^  [^ ]/ && $1 == key { v = $2; gsub(/"/, "", v); print v; exit }
  '
}

# Prints the value of an environment variable in a Deployment, or nothing.
env_value() {
  manifest "$1" Deployment "$2" | awk -v name="$3" '
    $1 == "-" && $2 == "name:" && $3 == name { want = 1; next }
    want && $1 == "value:" { v = $2; gsub(/"/, "", v); print v; exit }
    want && $1 == "-" { want = 0 }
  '
}

# Checks one service in one rendered release against its expected scaler.
expect_scaler() {
  local out="$1" name="$2" mode min max so hpa deploy got
  IFS=: read -r mode min max <<< "$3"
  so=$(manifest "$out" ScaledObject "$name")
  hpa=$(manifest "$out" HorizontalPodAutoscaler "$name")
  deploy=$(manifest "$out" Deployment "$name")
  [[ -n "$deploy" ]] || { echo "$name: no Deployment rendered"; return 1; }
  case "$mode" in
    keda)
      [[ -n "$so" && -z "$hpa" ]] || { echo "$name: want a ScaledObject and no HPA"; return 1; }
      got="$(spec_field minReplicaCount <<< "$so"):$(spec_field maxReplicaCount <<< "$so")"
      ;;
    hpa)
      [[ -n "$hpa" && -z "$so" ]] || { echo "$name: want an HPA and no ScaledObject"; return 1; }
      got="$(spec_field minReplicas <<< "$hpa"):$(spec_field maxReplicas <<< "$hpa")"
      ;;
    fixed)
      [[ -z "$so" && -z "$hpa" ]] || { echo "$name: want no autoscaler"; return 1; }
      got=$(spec_field replicas <<< "$deploy")
      [[ "$got" == "$min" ]] || { echo "$name: $got replicas, want $min"; return 1; }
      return 0
      ;;
    *) echo "$name: unknown expectation $3"; return 1 ;;
  esac
  [[ "$got" == "$min:$max" ]] || { echo "$name: $mode range $got, want $min:$max"; return 1; }
  # An autoscaler owns the replica count, so the chart must not pin one.
  [[ -z "$(spec_field replicas <<< "$deploy")" ]] || { echo "$name: Deployment pins replicas under $mode"; return 1; }
}

# The SmithDB workloads must run on the managed node group and nowhere else.
expect_pool() {
  local out="$1" kind="$2" name="$3" m
  m=$(manifest "$out" "$kind" "$name")
  [[ -n "$m" ]] || { echo "$name: no $kind rendered"; return 1; }
  grep -q 'langsmith-nodepool/smithdb: "\?true"\?' <<< "$m" || { echo "$name: no nodeSelector for the SmithDB node group"; return 1; }
  grep -q 'key: "\?langsmith-nodepool/smithdb"\?' <<< "$m" || { echo "$name: no toleration for the SmithDB node group"; return 1; }
}

# Blob storage is on for the API and queue services, with the test bucket. Chart 0.17
# sets these variables only when config.blobStorage.enabled is true.
expect_blob_storage() {
  local out="$1" bucket="$2" name got
  for name in langsmith-backend langsmith-platform-backend langsmith-queue langsmith-ingest-queue; do
    has "$out" Deployment "$name" || { echo "$name: no Deployment rendered"; return 1; }
    got=$(env_value "$out" "$name" FF_BLOB_STORAGE_ENABLED)
    [[ "$got" == true ]] || { echo "$name: FF_BLOB_STORAGE_ENABLED ${got:-unset}, want true"; return 1; }
    got=$(env_value "$out" "$name" S3_BUCKET_NAME)
    [[ "$got" == "$bucket" ]] || { echo "$name: S3_BUCKET_NAME ${got:-unset}, want $bucket"; return 1; }
  done
}

# Each cache volume claim uses the generated StorageClass.
expect_cache_class() {
  local out="$1" name="$2" want="$3"
  grep -q "storageClassName: \"\?$want\"\?" <<< "$(manifest "$out" Deployment "$name")" ||
    { echo "$name: cache volume does not use StorageClass $want"; return 1; }
}

# The CPU and memory of a Deployment's first requests block that has a CPU: the
# container's, not the cache volume claim's, which requests only storage.
first_requests() {
  manifest "$1" Deployment "$2" | awk '
    /^ *$/ { next }
    /^ *requests:$/ { r = 1; ind = match($0, /[^ ]/); c = ""; m = ""; next }
    r && match($0, /[^ ]/) <= ind { if (c != "") { found = 1; exit } r = 0 }
    r && $1 == "cpu:" { c = $2; gsub(/"/, "", c) }
    r && $1 == "memory:" { m = $2; gsub(/"/, "", m) }
    END { if (c != "" && (found || r)) print c ":" m }
  '
}

expect_requests() {
  local out="$1" name="$2" cpu="$3" memory="$4" source="${5:-small tier}" got
  got=$(first_requests "$out" "$name")
  [[ "$got" == "$cpu:$memory" ]] || { echo "$name: requests ${got:-none}, want $cpu:$memory ($source)"; return 1; }
}

# A local-ssd cache: an emptyDir of the tier's cache size, no volume claim, and an
# ephemeral-storage request and limit of the same size.
expect_local_cache() {
  local out="$1" name="$2" size="$3" m
  m=$(manifest "$out" Deployment "$name")
  [[ -n "$m" ]] || { echo "$name: no Deployment rendered"; return 1; }
  grep -q "sizeLimit: \"\?$size\"\?" <<< "$m" || { echo "$name: no emptyDir cache of $size"; return 1; }
  ! grep -q 'volumeClaimTemplate' <<< "$m" || { echo "$name: the cache still claims an EBS volume"; return 1; }
  (( $(grep -c "ephemeral-storage: \"\?$size\"\?" <<< "$m") >= 2 )) ||
    { echo "$name: no ephemeral-storage request and limit of $size"; return 1; }
}

# The service account of a Deployment carries this IRSA role.
expect_role() {
  local out="$1" name="$2" role="$3"
  grep -qF "eks.amazonaws.com/role-arn: $role" <<< "$(manifest "$out" ServiceAccount "$name")" ||
    { echo "$name: service account does not carry the role $role"; return 1; }
}

# An add-on uses the shared RDS and ElastiCache: the chart creates neither of its
# in-cluster StatefulSets and reads both of its Secrets.
expect_shared_storage() {
  local out="$1" addon="$2" store
  for store in postgres redis; do
    ! has "$out" StatefulSet "langsmith-standalone-$addon-$store" ||
      { echo "the chart still creates the in-cluster StatefulSet langsmith-standalone-$addon-$store"; return 1; }
    local secret="langsmith-$addon-$store"
    [[ "$addon" != insights ]] || secret="langsmith-insights-$store"
    grep -q "name: $secret\$" "$out" || { echo "nothing reads the Secret $secret"; return 1; }
  done
}

# ── Checks for each case ──────────────────────────────────────────────────────
# check_case <name> <dir> <out>: prints one line for each problem.
check_case() {
  local name="$1" dir="$2" out="$3" spec workload cpu memory msg want_tls want_host="https://langsmith.example.com"
  [[ "$name" != tls-none ]] || want_host="http://langsmith.example.com"
  [[ "$(value "$dir" config hostname || true)" == "$want_host" ]] || echo "config.hostname is not $want_host"
  expect_blob_storage "$out" values-test-blob || true
  for spec in polly:polly insights:insights fleet:fleet; do
    if [[ " $(case_tfvars "$name" | tr '\n' ' ')" == *" enable_${spec%%:*} = true "* ]]; then
      has "$out" Deployment "langsmith-standalone-${spec#*:}-api-server" || echo "${spec%%:*} is on, but its api-server is not rendered"
    elif [[ "$name" != engine || "$spec" != insights:insights ]]; then
      ! has "$out" Deployment "langsmith-standalone-${spec#*:}-api-server" || echo "${spec%%:*} is off, but its api-server is rendered"
    fi
  done

  case "$name" in
    default|smithdb-off)
      for spec in $EXPECTED; do
        expect_scaler "$out" "${spec%%:*}" "${spec#*:}" || true
      done
      [[ "$(env_value "$out" langsmith-backend REDIS_RUNS_EXPIRY_SECONDS)" == 3600 ]] ||
        echo "langsmith-backend: REDIS_RUNS_EXPIRY_SECONDS is not 3600"
      for workload in langsmith-backend langsmith-platform-backend langsmith-queue langsmith-ingest-queue; do
        [[ "$(env_value "$out" "$workload" CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT)" == 0 ]] ||
          echo "$workload: CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT is not 0"
      done
      has "$out" HTTPRoute langsmith || echo "no HTTPRoute for the Envoy Gateway"
      if [[ "$name" == default ]]; then
        expect_scaler "$out" langsmith-smithdb-compaction-worker "$COMPACTION_WORKER" || true
        for workload in query ingestion compaction-worker compaction cluster-manager; do
          expect_pool "$out" Deployment "langsmith-smithdb-$workload" || true
        done
        expect_pool "$out" Job langsmith-smithdb-metastore-migration || true
        for workload in query ingestion compaction-worker; do
          expect_cache_class "$out" "langsmith-smithdb-$workload" smithdb-cache || true
        done
        for spec in $SMALL_TIER; do
          IFS=: read -r workload cpu memory <<< "$spec"
          expect_requests "$out" "langsmith-smithdb-$workload" "$cpu" "$memory" || true
        done
      else
        ! has "$out" Deployment langsmith-smithdb-compaction-worker || echo "SmithDB is off, but its compaction worker is rendered"
        ! grep -q 'langsmith-nodepool/smithdb' "$out" || echo "SmithDB is off, but its node group appears"
      fi
      ;;
    deployments|tls-none)
      for workload in host-backend listener operator; do
        has "$out" Deployment "langsmith-$workload" || echo "langsmith-$workload: no Deployment rendered"
      done
      want_tls=true
      [[ "$name" != tls-none ]] || want_tls=false
      [[ "$(value "$dir" config deployment tlsEnabled || true)" == "$want_tls" ]] ||
        echo "config.deployment.tlsEnabled is not $want_tls"
      ;;
    fleet)
      has "$out" Deployment langsmith-host-backend || echo "Fleet is on, but host-backend is not rendered"
      expect_role "$out" langsmith-standalone-fleet-api-server "$IRSA_ROLE" || true
      expect_shared_storage "$out" fleet || true
      ;;
    polly)
      expect_role "$out" langsmith-standalone-polly-api-server "$IRSA_ROLE" || true
      expect_shared_storage "$out" polly || true
      ;;
    insights)
      expect_requests "$out" langsmith-standalone-insights-api-server 2 4Gi "init-values.sh" || true
      expect_requests "$out" langsmith-standalone-insights-queue 1 2Gi "init-values.sh" || true
      expect_shared_storage "$out" insights || true
      has "$out" StatefulSet langsmith-clickhouse || echo "in-cluster ClickHouse: no StatefulSet rendered"
      ;;
    clickhouse-external)
      ! has "$out" StatefulSet langsmith-clickhouse || echo "external ClickHouse: the chart still runs its StatefulSet"
      grep -q 'name: langsmith-clickhouse$' <<< "$(manifest "$out" Deployment langsmith-backend | grep -A5 'name: CLICKHOUSE_HOST$')" ||
        echo "external ClickHouse: the backend does not read CLICKHOUSE_HOST from the Secret langsmith-clickhouse"
      ;;
    engine)
      [[ "$(value "$dir" engine enabled || true)" == true ]] || echo "engine.enabled is not true"
      expect_role "$out" langsmith-standalone-insights-api-server "$ENGINE_ROLE" || true
      expect_shared_storage "$out" insights || true
      ;;
    sandboxes)
      [[ "$(value "$dir" sandboxes juicefs existingSecretName || true)" == juicefs-csi-config ]] ||
        echo "sandboxes.juicefs.existingSecretName is not juicefs-csi-config"
      grep -q '/mnt/juicefs-cache0' "$out" || echo "the sandbox-host cache directory is not rendered"
      [[ ! -f "$dir/values/langsmith-sandbox-values-overrides.yaml" ]] || echo "an in-cluster runtime wrote the sandbox runtime file"
      ;;
    sandboxes-external)
      [[ "$(value "$dir" sandboxes external enabled || true)" == true ]] || echo "sandboxes.external.enabled is not true"
      [[ "$(value "$dir" sandboxes serviceAuth secretKey || true)" == sandbox_service_auth_secret ]] ||
        echo "sandboxes.serviceAuth.secretKey is not sandbox_service_auth_secret"
      ! grep -q '/mnt/juicefs-cache0' "$out" || echo "an external runtime still renders sandbox-host in this release"
      grep -q 'endpoint: "https://langsmith.example.com/api"' "$dir/values/langsmith-sandbox-values-overrides.yaml" 2>/dev/null ||
        echo "the sandbox runtime file is missing or does not point at https://langsmith.example.com/api"
      ;;
    sso)
      [[ "$(value "$dir" config oauth enabled || true)" == true ]] || echo "config.oauth.enabled is not true"
      [[ "$(value "$dir" config basicAuth enabled || true)" == false ]] || echo "config.basicAuth.enabled is not false"
      grep -q 'BASIC_AUTH_ENABLED: "false"' "$out" || echo "the chart still enables basic auth"
      ;;
    telemetry)
      [[ "$(env_value "$out" langsmith-backend PHONE_HOME_USAGE_REPORTING_ENABLED)" == true ]] ||
        echo "langsmith-backend: PHONE_HOME_USAGE_REPORTING_ENABLED is not true"
      ;;
    local-ssd)
      expect_local_cache "$out" langsmith-smithdb-query 200Gi || true
      expect_local_cache "$out" langsmith-smithdb-ingestion 100Gi || true
      expect_local_cache "$out" langsmith-smithdb-compaction-worker 100Gi || true
      ;;
    local-ssd-unified)
      expect_local_cache "$out" langsmith-smithdb 100Gi || true
      ;;
    istio)
      grep -q '^kind: VirtualService' "$out" || echo "Istio: no VirtualService rendered"
      ! grep -q '^kind: HTTPRoute' "$out" || echo "Istio: an HTTPRoute is still rendered"
      ;;
    alb-ingress)
      msg=$(manifest "$out" Ingress langsmith-ingress)
      [[ -n "$msg" ]] || echo "ALB: no Ingress rendered"
      grep -q 'alb.ingress.kubernetes.io/scheme: "\?internet-facing"\?' <<< "$msg" || echo "ALB: no scheme annotation"
      grep -q 'alb.ingress.kubernetes.io/group.name: "\?values-test-test"\?' <<< "$msg" || echo "ALB: no group.name annotation"
      grep -q 'alb.ingress.kubernetes.io/certificate-arn: "\?arn:aws:acm:' <<< "$msg" || echo "ALB: no certificate-arn annotation"
      ;;
    all)
      for spec in fleet polly insights; do
        expect_shared_storage "$out" "$spec" || true
      done
      expect_role "$out" langsmith-standalone-insights-api-server "$ENGINE_ROLE" || true
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
  [[ -z "$(case_local "$name")" ]] || want="$want"$'\n'"$_VALUES_LOCAL"
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

# ── langsmith-values-local.yaml, hand edits, terraform.tfvars and the 0.17 layout ──
dir="$TEST_TMP/edits"
make_case default "$dir"
problems=()
run_init "$dir" || problems+=("init-values.sh failed: $(tail -n 1 "$dir/init.log")")
printf 'frontend:\n  deployment:\n    replicas: 3\npolly:\n  enabled: true\n' > "$dir/values/$_VALUES_LOCAL"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after the local file was added")
grep -q "$_VALUES_LOCAL was added" "$dir/check.err" || problems+=("the checks do not name the added local file")
run_init "$dir" || problems+=("init-values.sh failed with a local file: $(tail -n 1 "$dir/init.log")")
[[ "$(value "$dir" frontend deployment replicas || true)" == 3 ]] || problems+=("a key in the local file does not win")
[[ "$(value "$dir" polly enabled || true)" == false ]] || problems+=("the local file turned on Chat, which terraform.tfvars has off")
deploy_checks "$dir" 2> "$dir/check.err" || problems+=("deploy.sh's checks stop after init-values.sh merged the local file")
cp "$dir/values/$_VALUES_OVERRIDES" "$dir/kept.yaml"
run_init "$dir" || problems+=("init-values.sh failed on a re-run: $(tail -n 1 "$dir/init.log")")
cmp -s "$dir/kept.yaml" "$dir/values/$_VALUES_OVERRIDES" || problems+=("a re-run with the local file wrote different bytes")
report "langsmith-values-local.yaml is merged last, survives a re-run, and cannot turn a feature on" ${problems[@]+"${problems[@]}"}

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
printf 'enable_polly = true\n' | cat - "$dir/infra/terraform.tfvars" > "$dir/tfvars" && mv "$dir/tfvars" "$dir/infra/terraform.tfvars"
deploy_checks "$dir" 2> "$dir/check.err" && problems+=("deploy.sh's checks pass after a terraform.tfvars change")
grep -q 'terraform.tfvars has enable_polly = "true"' "$dir/check.err" || problems+=("the checks do not name enable_polly")
report "a terraform.tfvars change after make init-values stops deploy.sh" ${problems[@]+"${problems[@]}"}

problems=()
dir="$TEST_TMP/legacy"
make_case default "$dir"
cp "$EXAMPLES_DIR/langsmith-values-fleet.yaml" "$dir/values/"
printf 'backend: {}\n' > "$dir/values/langsmith-values-sizing-production.yaml"
cp "$EXAMPLES_DIR/$_VALUES_BASE" "$dir/values/"
run_init "$dir" && problems+=("init-values.sh ran with 0.17 files in helm/values")
grep -q 'holds values files from the 0.17 layout' "$dir/init.log" || problems+=("init-values.sh does not name the 0.17 layout")
grep -q 'langsmith-values-fleet.yaml .*same as examples/langsmith-values-fleet.yaml' "$dir/init.log" ||
  problems+=("the message does not mark the unchanged Fleet copy")
grep -q 'langsmith-values-sizing-production.yaml .*no example of this name' "$dir/init.log" ||
  problems+=("the message does not list the 0.17 sizing file")
! grep -qE "^ *$_VALUES_BASE +(same as|differs|no example|written by)" "$dir/init.log" ||
  problems+=("an unchanged copy of the base values is listed")
[[ ! -f "$dir/values/$_VALUES_OVERRIDES" ]] || problems+=("init-values.sh wrote the overrides file anyway")
deploy_checks "$dir" 2> /dev/null && problems+=("deploy.sh's checks pass with 0.17 files in helm/values")
report "files from the 0.17 layout stop init-values.sh and deploy.sh" ${problems[@]+"${problems[@]}"}

# External ClickHouse: the details are asked for on the first run only, and a
# kubectl failure is not a missing Secret.
problems=()
dir="$TEST_TMP/clickhouse-secret"
make_case clickhouse-external "$dir"
(export CLICKHOUSE_SECRET=missing; run_init "$dir") && problems+=("a first run without a terminal passed while kubectl reports NotFound")
grep -q 'has no Secret langsmith-clickhouse' "$dir/init.log" || problems+=("the NotFound stop does not name the Secret")
(export CLICKHOUSE_SECRET=error; run_init "$dir") && problems+=("a first run passed while kubectl could not reach the cluster")
grep -q 'kubectl could not check namespace langsmith for the Secret langsmith-clickhouse' "$dir/init.log" ||
  problems+=("the kubectl failure is not reported as one")
grep -q 'The connection to the server' "$dir/init.log" || problems+=("the stop does not print kubectl's message")
! grep -q 'ClickHouse host' "$dir/init.log" || problems+=("a kubectl failure led to the prompt")
[[ -z "$(ls -A "$dir/values")" ]] || problems+=("a stopped first run wrote values files")
run_init "$dir" || problems+=("a first run with the Secret in place failed: $(tail -n 1 "$dir/init.log")")
(export CLICKHOUSE_SECRET=error KUBECTL_LOG="$dir/kubectl.log"; run_init "$dir") ||
  problems+=("a re-run needs the cluster: $(tail -n 1 "$dir/init.log")")
! grep -q 'get secret' "$dir/kubectl.log" 2>/dev/null || problems+=("a re-run looked up the Secret")
report "external ClickHouse: a first run stops on NotFound and on a kubectl failure, without asking, and a re-run needs no cluster" ${problems[@]+"${problems[@]}"}

problems=()
dir="$TEST_TMP/clickhouse-local"
make_case clickhouse-external "$dir"
printf 'clickhouse:\n  external:\n    existingSecretName: my-clickhouse\n' > "$dir/values/$_VALUES_LOCAL"
(export CLICKHOUSE_SECRET=error KUBECTL_LOG="$dir/kubectl.log"; run_init "$dir") ||
  problems+=("init-values.sh failed with a Secret named in the local file: $(tail -n 1 "$dir/init.log")")
! grep -q 'get secret' "$dir/kubectl.log" 2>/dev/null || problems+=("init-values.sh looked up langsmith-clickhouse although the local file names another Secret")
[[ "$(value "$dir" clickhouse external existingSecretName || true)" == my-clickhouse ]] ||
  problems+=("the values do not read the Secret that the local file names")
report "external ClickHouse: a Secret named in langsmith-values-local.yaml needs no cluster" ${problems[@]+"${problems[@]}"}

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

# deploy.sh checks the ClickHouse Secret after it points kubectl at this cluster
# and before the Helm upgrade of the LangSmith release.
problems=()
order=$(awk -v kube='_use_cluster_kubeconfig "$_cluster_name"' '
  index($0, kube) == 1 && !k { k = NR }
  /^_values_clickhouse_secret_check / && !c { c = NR }
  /helm upgrade --install "\$RELEASE_NAME"/ && !u { u = NR }
  END { print (k && c > k && u > c) ? "ok" : "kubeconfig " k ", check " c ", upgrade " u }
' "$SCRIPT_DIR/deploy.sh")
[[ "$order" == ok ]] || problems+=("the lines are out of order: $order")
report "deploy.sh checks the ClickHouse Secret in this cluster before the Helm upgrade" ${problems[@]+"${problems[@]}"}

# ── The example files ─────────────────────────────────────────────────────────
# The base values set the sizing, and the feature overlays merge after them, so a
# sizing key in an overlay would override the base values without notice.
key_paths() {
  awk '
    /^[[:space:]]*(#|$)/ || /^[[:space:]]*-/ { next }
    {
      match($0, /^ */); d = int(RLENGTH / 2)
      k = $1; sub(/:.*/, "", k); path[d] = k
      p = path[0]; for (i = 1; i <= d; i++) p = p "." path[i]
      print p
    }
  ' "$1"
}
problems=()
for overlay in "$EXAMPLES_DIR"/langsmith-values-*.yaml; do
  found=$(key_paths "$overlay" \
    | grep -E '^(queue|ingestQueue)(\.|$)|^(frontend|backend)\.(deployment\.replicas|autoscaling)(\.|$)|^smithdb\.compactionWorker\.autoscaling(\.|$)' \
    | head -1) || true
  [[ -z "$found" ]] || problems+=("${overlay##*/} sets $found; only langsmith-values.yaml may")
done
report "no feature overlay sets the replicas or autoscaling of a sized service" ${problems[@]+"${problems[@]}"}

if grep -qE '^  resourceTier: "?small"?$' "$EXAMPLES_DIR/langsmith-values-smithdb.yaml"; then
  report "the SmithDB overlay sets the small tier"
else
  report "the SmithDB overlay sets the small tier" "langsmith-values-smithdb.yaml does not set smithdb.resourceTier: small"
fi

# commonEnv is a list, and a list in a later values file replaces an earlier one,
# so an example that set it would drop the list that init-values.sh writes.
problems=()
for values in "$EXAMPLES_DIR"/langsmith-values*.yaml; do
  found=$(key_paths "$values" | grep -E '^commonEnv$' | head -1) || true
  [[ -z "$found" ]] || problems+=("${values##*/} sets commonEnv, which would replace the generated list")
done
report "no example file sets commonEnv" ${problems[@]+"${problems[@]}"}

# No service may request less than the chart's own default (the 0.17 production
# profile ran platform-backend, ace-backend, listener and operator below it).
# Compare each Deployment of the case with every feature on against a render of
# the base values, which set no requests, and the switches that turn on
# Deployments, Fleet, Chat and Insights. A Deployment the chart gives no
# requests, such as the add-on agents, has no floor.
quantity() {
  awk -v q="$1" 'BEGIN {
    n = q + 0; u = q; sub(/^[0-9.]+/, "", u)
    f["m"] = 0.001; f[""] = 1; f["Ki"] = 1 / 1024; f["Mi"] = 1; f["Gi"] = 1024
    f["k"] = 1000 / 1048576; f["M"] = 1e6 / 1048576; f["G"] = 1e9 / 1048576
    if (!(u in f)) exit 1
    printf "%.6f\n", n * f[u]
  }'
}
at_least() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}
problems=()
compared=0
ours="$TEST_TMP/case-all/render.yaml"
chart_only="$TEST_TMP/floor-chart.yaml"
found=$(key_paths "$EXAMPLES_DIR/$_VALUES_BASE" | grep -E '\.resources(\.|$)' | head -1) || true
[[ -z "$found" ]] || problems+=("$_VALUES_BASE sets $found; the base values keep the chart's requests")
if [[ ! -s "$ours" ]]; then
  problems+=("the case with every feature on did not render")
elif ! helm template langsmith "$chart" --namespace langsmith -f "$EXAMPLES_DIR/$_VALUES_BASE" \
    --set config.hostname=https://langsmith.example.com --set config.initialOrgAdminEmail=admin@example.com \
    --set config.deployment.enabled=true \
    --set hostBackend.enabled=true --set listener.enabled=true --set operator.enabled=true \
    --set fleet.enabled=true --set fleetToolServer.enabled=true --set fleetTriggerServer.enabled=true \
    --set polly.enabled=true --set insights.enabled=true \
    > "$chart_only" 2> "$chart_only.err"; then
  problems+=("the chart rejected its own defaults: $(head -1 "$chart_only.err")")
else
  while read -r name; do
    floor=$(first_requests "$chart_only" "$name")
    [[ -n "$floor" ]] || continue
    got=$(first_requests "$ours" "$name")
    [[ -n "$got" ]] || { problems+=("$name: no requests, chart default ${floor/:/ CPU, }"); continue; }
    compared=$((compared + 1))
    for i in 1 2; do
      want_q=$(cut -d: -f$i <<< "$floor"); got_q=$(cut -d: -f$i <<< "$got")
      if ! w=$(quantity "$want_q") || ! g=$(quantity "$got_q"); then
        problems+=("$name: cannot read the quantity $got_q or $want_q")
      elif ! at_least "$g" "$w"; then
        problems+=("$name: requests ${got/:/ CPU, }, below the chart default ${floor/:/ CPU, }")
      fi
    done
  done < <(awk '/^kind: Deployment/ { d = 1; next } /^---/ { d = 0 }
    d && /^  name:/ { n = $2; gsub(/"/, "", n); print n; d = 0 }' "$chart_only")
  (( compared )) || problems+=("no Deployment had chart default requests to compare")
fi
report "no service requests less than the chart default ($compared Deployments)" ${problems[@]+"${problems[@]}"}

if (( failures )); then
  echo "$failures values check(s) failed"
  exit 1
fi
