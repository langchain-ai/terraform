#!/usr/bin/env bash
# Renders the LangSmith chart with the AWS example values, in deploy.sh's order,
# with SmithDB off and on, and checks the scaler or replica count each sized
# service gets, that SmithDB runs the small tier, that no service requests less
# than the chart's own default, and that the overrides init-values.sh generates
# give the ClickHouse writers the pattern's async-insert setting. No cluster and
# no AWS calls.
# Requires helm, and network access to fetch the chart unless LANGSMITH_CHART
# names a local chart directory or archive.
# Usage: bash modules/aws/helm/scripts/test-values.sh
#        CHART_VERSION=0.18.0-rc.70 bash modules/aws/helm/scripts/test-values.sh
# Exit 0 pass, 1 a failing check, 2 the test could not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$SCRIPT_DIR/../values/examples"
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
if ! chart_version=$(helm show chart "$chart" | awk '/^version:/ { print $2 }') || [[ -z "$chart_version" ]]; then
  echo "ERROR: $chart is not a readable chart" >&2
  exit 2
fi
echo "Chart: langsmith $chart_version (pin $version)"

# Stand-ins for the files init-values.sh generates from Terraform outputs.
cat > "$TEST_TMP/overrides.yaml" <<'EOF'
config:
  hostname: "https://langsmith.example.com"
  initialOrgAdminEmail: "admin@example.com"
  deployment:
    url: "https://langsmith.example.com"
  blobStorage:
    bucketName: "values-test-blob"
    awsRegion: "us-west-2"
    apiURL: "https://s3.us-west-2.amazonaws.com"
EOF
# The SmithDB overrides come from the heredoc in init-values.sh itself, so a change to the
# generated scheduling or cache values is rendered against the real chart here.
# The gates are a new install's defaults: ingestion and query on, migration off.
source "$SCRIPT_DIR/../../infra/scripts/_smithdb-transition.sh"
(
  export _smithdb_overrides="$TEST_TMP/smithdb-overrides.yaml"
  export SMITHDB_CACHE_STORAGE_CLASS=smithdb-cache
  export SMITHDB_BUCKET=values-test-smithdb
  export SMITHDB_IRSA_ROLE_ARN=arn:aws:iam::123456789012:role/values-test-smithdb
  export _region=us-west-2
  export _smithdb_metastore_use_ssl=true
  export _smithdb_ingestion_enabled=true
  export _smithdb_migration_enabled=false
  export _smithdb_query_enabled=true
  sed -n '/^  cat > "\$_smithdb_overrides" << SMITHDB_YAML$/,/^SMITHDB_YAML$/p' \
    "$SCRIPT_DIR/init-values.sh" > "$TEST_TMP/generate-smithdb.sh"
  [[ -s "$TEST_TMP/generate-smithdb.sh" ]] || { echo "ERROR: no SmithDB overrides block found in init-values.sh" >&2; exit 2; }
  source "$TEST_TMP/generate-smithdb.sh"
)

# deploy.sh turns Chat and Insights off with --set when their flags are off,
# because the chart enables both by default.
render() {
  local smithdb="$1" out="$2"
  local args=(-f "$EXAMPLES_DIR/langsmith-values.yaml" -f "$TEST_TMP/overrides.yaml")
  [[ "$smithdb" == off ]] || args+=(-f "$EXAMPLES_DIR/langsmith-values-smithdb.yaml" -f "$TEST_TMP/smithdb-overrides.yaml")
  args+=(--set polly.enabled=false --set insights.enabled=false)
  helm template langsmith "$chart" --namespace langsmith "${args[@]}" > "$out" 2> "$out.err"
}

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

# Prints one key directly under spec of the manifest on stdin.
spec_field() {
  awk -v key="$1:" '
    /^spec:/ { s = 1; next }
    /^[^ ]/ { s = 0 }
    s && /^  [^ ]/ && $1 == key { v = $2; gsub(/"/, "", v); print v; exit }
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
  ! grep -q 'smithdb-local/' <<< "$m" || { echo "$name: still pinned to an old Karpenter pool"; return 1; }
}

# Each cache volume claim uses the generated StorageClass.
expect_cache_class() {
  local out="$1" name="$2" want="$3"
  manifest "$out" Deployment "$name" | grep -q "storageClassName: \"\?$want\"\?" ||
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
  local out="$1" name="$2" cpu="$3" memory="$4" got
  got=$(first_requests "$out" "$name")
  [[ "$got" == "$cpu:$memory" ]] || { echo "$name: requests ${got:-none}, want $cpu:$memory (small tier)"; return 1; }
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

failures=0
for smithdb in off on; do
  out="$TEST_TMP/smithdb-$smithdb.yaml"
  label="SmithDB $smithdb"
  if ! render "$smithdb" "$out"; then
    echo "FAIL: $label: the chart rejected the values"
    sed 's/^/      /' "$out.err"
    failures=$((failures + 1))
    continue
  fi
  problems=()
  for spec in $EXPECTED; do
    msg=$(expect_scaler "$out" "${spec%%:*}" "${spec#*:}") || problems+=("$msg")
  done
  manifest "$out" Deployment langsmith-backend | grep -A1 'name: REDIS_RUNS_EXPIRY_SECONDS$' | grep -q 'value: "3600"' ||
    problems+=("langsmith-backend: REDIS_RUNS_EXPIRY_SECONDS is not 3600")
  if [[ "$smithdb" == on ]]; then
    msg=$(expect_scaler "$out" langsmith-smithdb-compaction-worker "$COMPACTION_WORKER") || problems+=("$msg")
    for workload in query ingestion compaction-worker compaction cluster-manager; do
      msg=$(expect_pool "$out" Deployment "langsmith-smithdb-$workload") || problems+=("$msg")
    done
    msg=$(expect_pool "$out" Job langsmith-smithdb-metastore-migration) || problems+=("$msg")
    for workload in query ingestion compaction-worker; do
      msg=$(expect_cache_class "$out" "langsmith-smithdb-$workload" smithdb-cache) || problems+=("$msg")
    done
    for spec in $SMALL_TIER; do
      IFS=: read -r workload cpu memory <<< "$spec"
      msg=$(expect_requests "$out" "langsmith-smithdb-$workload" "$cpu" "$memory") || problems+=("$msg")
    done
  else
    [[ -z "$(manifest "$out" Deployment langsmith-smithdb-compaction-worker)" ]] ||
      problems+=("langsmith-smithdb-compaction-worker: rendered with SmithDB off")
    ! grep -q 'langsmith-nodepool/smithdb' "$out" ||
      problems+=("the SmithDB node group appears in the values with SmithDB off")
  fi
  if (( ${#problems[@]} )); then
    echo "FAIL: $label"
    printf '      %s\n' "${problems[@]}"
    failures=$((failures + 1))
  else
    echo "PASS: $label"
  fi
done

# smithdb_cache_storage = "local-ssd", with the values deploy.sh adds for the small
# tier. The chart needs an ephemeral-storage limit for an emptyDir cache, so a
# missing one fails the render. From chart 0.18 the unified layout is checked too.
local_args=(-f "$EXAMPLES_DIR/langsmith-values.yaml" -f "$TEST_TMP/overrides.yaml"
  -f "$EXAMPLES_DIR/langsmith-values-smithdb.yaml" -f "$TEST_TMP/smithdb-overrides.yaml"
  --set polly.enabled=false --set insights.enabled=false)
local_specs="cluster:langsmith-smithdb-query:200Gi cluster:langsmith-smithdb-ingestion:100Gi cluster:langsmith-smithdb-compaction-worker:100Gi"
helm show values "$chart" > "$TEST_TMP/chart-values.yaml"
if grep -qE '^  topology:' "$TEST_TMP/chart-values.yaml"; then
  local_specs="$local_specs unified:langsmith-smithdb:100Gi"
fi
for topology in cluster unified; do
  [[ " $local_specs" == *" $topology:"* ]] || continue
  VALUES_ARGS=("${local_args[@]}")
  [[ "$topology" == cluster ]] || VALUES_ARGS+=(--set smithdb.topology=unified)
  _smithdb_managed_values local-ssd
  out="$TEST_TMP/smithdb-local-ssd-$topology.yaml"
  problems=()
  if ! helm template langsmith "$chart" --namespace langsmith "${VALUES_ARGS[@]}" > "$out" 2> "$out.err"; then
    problems+=("the chart rejected the values: $(head -1 "$out.err")")
  else
    for spec in $local_specs; do
      IFS=: read -r layout name size <<< "$spec"
      [[ "$layout" == "$topology" ]] || continue
      msg=$(expect_local_cache "$out" "$name" "$size") || problems+=("$msg")
    done
  fi
  if (( ${#problems[@]} )); then
    echo "FAIL: local-ssd cache, $topology layout"
    printf '      %s\n' "${problems[@]}"
    failures=$((failures + 1))
  else
    echo "PASS: local-ssd cache, $topology layout"
  fi
done

# Feature overlays load after the base values, so a sizing key in one would
# override the base values without notice.
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
overlay_failures=0
for overlay in "$EXAMPLES_DIR"/langsmith-values-*.yaml; do
  found=$(key_paths "$overlay" \
    | grep -E '^(queue|ingestQueue)(\.|$)|^(frontend|backend)\.(deployment\.replicas|autoscaling)(\.|$)|^smithdb\.compactionWorker\.autoscaling(\.|$)' \
    | head -1) || true
  if [[ -n "$found" ]]; then
    echo "FAIL: ${overlay##*/} sets $found; only langsmith-values.yaml may"
    overlay_failures=$((overlay_failures + 1))
  fi
done
if (( overlay_failures )); then
  failures=$((failures + overlay_failures))
else
  echo "PASS: no feature overlay sets the replicas or autoscaling of a sized service"
fi

# The SmithDB overlay sets the tier once, and an operator changes it there with
# the node inputs.
if grep -qE '^  resourceTier: "?small"?$' "$EXAMPLES_DIR/langsmith-values-smithdb.yaml"; then
  echo "PASS: the SmithDB overlay sets the small tier"
else
  echo "FAIL: langsmith-values-smithdb.yaml does not set smithdb.resourceTier: small"
  failures=$((failures + 1))
fi

# From 0.18 Fleet, Chat and Insights run only on the shared RDS and ElastiCache.
# Render the three overlays with deploy.sh's storage values: the chart must
# accept them, create none of its in-cluster add-on StatefulSets, and read each
# add-on's two Secrets from Terraform.
source "$SCRIPT_DIR/_addon-storage.sh"
VALUES_ARGS=(-f "$EXAMPLES_DIR/langsmith-values.yaml" -f "$TEST_TMP/overrides.yaml"
  -f "$EXAMPLES_DIR/langsmith-values-insights.yaml" -f "$EXAMPLES_DIR/langsmith-values-polly.yaml"
  -f "$EXAMPLES_DIR/langsmith-values-fleet.yaml"
  --set polly.enabled=true --set insights.enabled=true --set hostBackend.enabled=true
  --set fleet.encryptionKey=values-test --set polly.encryptionKey=values-test
  --set insights.encryptionKey=values-test)
_addon_storage_values true true true
out="$TEST_TMP/addon-storage.yaml"
problems=()
if ! helm template langsmith "$chart" --namespace langsmith "${VALUES_ARGS[@]}" > "$out" 2> "$out.err"; then
  problems+=("the chart rejected the values: $(head -1 "$out.err")")
else
  for addon in fleet polly insights; do
    for store in postgres redis; do
      [[ -z "$(manifest "$out" StatefulSet "langsmith-standalone-$addon-$store")" ]] \
        || problems+=("the chart still creates the in-cluster StatefulSet langsmith-standalone-$addon-$store")
      grep -q "name: langsmith-$addon-$store\$" "$out" \
        || problems+=("nothing reads the Secret langsmith-$addon-$store")
    done
  done
fi
if (( ${#problems[@]} )); then
  echo "FAIL: Fleet, Chat and Insights use the shared RDS and ElastiCache"
  printf '      %s\n' "${problems[@]}"
  failures=$((failures + 1))
else
  echo "PASS: Fleet, Chat and Insights use the shared RDS and ElastiCache"
fi

# No service may request less than the chart's own default (the 0.17 production
# profile ran platform-backend, ace-backend, listener and operator below it).
# Render every feature with the example values, and again with only the
# base values, which set no requests, and the switches that turn the features on;
# then compare each Deployment's requests. A Deployment the chart gives no
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
features=(--set config.deployment.enabled=true --set hostBackend.enabled=true
  --set listener.enabled=true --set operator.enabled=true --set fleet.enabled=true
  --set fleetToolServer.enabled=true --set fleetTriggerServer.enabled=true
  --set polly.enabled=true --set insights.enabled=true
  --set fleet.encryptionKey=values-test --set polly.encryptionKey=values-test
  --set insights.encryptionKey=values-test)
VALUES_ARGS=(-f "$EXAMPLES_DIR/langsmith-values.yaml" -f "$TEST_TMP/overrides.yaml"
  -f "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml" -f "$EXAMPLES_DIR/langsmith-values-insights.yaml"
  -f "$EXAMPLES_DIR/langsmith-values-polly.yaml" -f "$EXAMPLES_DIR/langsmith-values-fleet.yaml"
  "${features[@]}")
_addon_storage_values true true true
ours="$TEST_TMP/floor-ours.yaml"
chart_only="$TEST_TMP/floor-chart.yaml"
problems=()
compared=0
found=$(key_paths "$EXAMPLES_DIR/langsmith-values.yaml" | grep -E '\.resources(\.|$)' | head -1) || true
[[ -z "$found" ]] || problems+=("langsmith-values.yaml sets $found; the base values keep the chart's requests")
if ! helm template langsmith "$chart" --namespace langsmith "${VALUES_ARGS[@]}" > "$ours" 2> "$ours.err"; then
  problems+=("the chart rejected these values: $(head -1 "$ours.err")")
elif ! helm template langsmith "$chart" --namespace langsmith -f "$EXAMPLES_DIR/langsmith-values.yaml" \
    -f "$TEST_TMP/overrides.yaml" "${features[@]}" > "$chart_only" 2> "$chart_only.err"; then
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
if (( ${#problems[@]} )); then
  echo "FAIL: no service requests less than the chart default"
  printf '      %s\n' "${problems[@]}"
  failures=$((failures + 1))
else
  echo "PASS: no service requests less than the chart default ($compared Deployments)"
fi

# The pattern's CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT lives in the generated
# overrides, because commonEnv is a list and a list in a later values file replaces
# an earlier one. Generate that file from the heredoc in init-values.sh itself,
# render it, and check that each service that writes to ClickHouse gets the
# variable. An example values file that set commonEnv would replace the list.
(
  export OUT_FILE="$TEST_TMP/generated-overrides.yaml"
  export _protocol=https HOSTNAME=langsmith.example.com ADMIN_EMAIL=admin@example.com
  export BUCKET_NAME=values-test-blob _region=us-west-2
  export IRSA_ROLE_ARN=arn:aws:iam::123456789012:role/values-test
  export _enable_usage_telemetry=false _sandbox_config_block="" _routing_block="" _standalone_block=""
  sed -n '/^cat > "\$OUT_FILE" << YAML$/,/^YAML$/p' \
    "$SCRIPT_DIR/init-values.sh" > "$TEST_TMP/generate-overrides.sh"
  [[ -s "$TEST_TMP/generate-overrides.sh" ]] || { echo "ERROR: no overrides block found in init-values.sh" >&2; exit 2; }
  source "$TEST_TMP/generate-overrides.sh"
)
out="$TEST_TMP/generated-overrides-render.yaml"
problems=()
for values in "$EXAMPLES_DIR"/langsmith-values*.yaml; do
  found=$(key_paths "$values" | grep -E '^commonEnv$' | head -1) || true
  [[ -z "$found" ]] || problems+=("${values##*/} sets commonEnv, which would replace the generated list")
done
if ! helm template langsmith "$chart" --namespace langsmith -f "$EXAMPLES_DIR/langsmith-values.yaml" \
    -f "$TEST_TMP/generated-overrides.yaml" --set polly.enabled=false --set insights.enabled=false \
    > "$out" 2> "$out.err"; then
  problems+=("the chart rejected the generated overrides: $(head -1 "$out.err")")
else
  for name in langsmith-backend langsmith-platform-backend langsmith-queue langsmith-ingest-queue; do
    got=$(manifest "$out" Deployment "$name" | grep -A1 'name: CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT$' |
      grep -c 'value: "0"') || true
    (( got > 0 )) || problems+=("$name: CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT is not 0")
  done
fi
if (( ${#problems[@]} )); then
  echo "FAIL: the generated overrides give the ClickHouse writers CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT=0"
  printf '      %s\n' "${problems[@]}"
  failures=$((failures + 1))
else
  echo "PASS: the generated overrides give the ClickHouse writers CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT=0"
fi

if (( failures )); then
  echo "$failures values check(s) failed"
  exit 1
fi
