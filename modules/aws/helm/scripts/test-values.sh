#!/usr/bin/env bash
# Renders the LangSmith chart with the AWS example values, in deploy.sh's order,
# for every sizing profile with SmithDB off and on, and checks which scaler the
# queue services get and that SmithDB runs the small tier. No cluster and no AWS
# calls.
# Requires helm, and network access to fetch the chart unless LANGSMITH_CHART
# names a local chart directory or archive.
# Usage: bash modules/aws/helm/scripts/test-values.sh
#        CHART_VERSION=0.18.0-rc.70 bash modules/aws/helm/scripts/test-values.sh
# Exit 0 pass, 1 a failing check, 2 the test could not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$SCRIPT_DIR/../values/examples"
CHART_REPO="https://langchain-ai.github.io/helm"

# The scaler each service gets, per sizing profile. "default" loads no sizing
# file. The compaction worker column applies only with SmithDB on.
#   keda:MIN:MAX  a KEDA ScaledObject with that replica range, and no HPA
#   hpa:MIN:MAX   a chart HorizontalPodAutoscaler with that range, and no ScaledObject
#   fixed:N       no autoscaler; the Deployment runs N replicas
# Columns: profile, queue, ingest-queue, compaction worker.
EXPECTED="
default          keda:1:10  keda:3:6   keda:1:10
minimum          keda:1:2   keda:1:2   keda:1:10
dev              keda:1:5   keda:1:5   keda:1:10
production       keda:3:10  keda:3:10  keda:1:10
production-large keda:6:24  keda:6:24  keda:1:10
"
# The small tier's per-replica requests in the chart's tier table, as
# workload:cpu:memory. No sizing profile changes them.
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
  local profile="$1" smithdb="$2" out="$3"
  local args=(-f "$EXAMPLES_DIR/langsmith-values.yaml" -f "$TEST_TMP/overrides.yaml")
  [[ "$profile" == default ]] || args+=(-f "$EXAMPLES_DIR/langsmith-values-sizing-$profile.yaml")
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

# The CPU and memory of the first requests block that has a CPU: the container's,
# not the cache volume claim's, which requests only storage.
expect_requests() {
  local out="$1" name="$2" cpu="$3" memory="$4" got
  got=$(manifest "$out" Deployment "$name" | awk '
    /^ *$/ { next }
    /^ *requests:$/ { r = 1; ind = match($0, /[^ ]/); c = ""; m = ""; next }
    r && match($0, /[^ ]/) <= ind { if (c != "") { found = 1; exit } r = 0 }
    r && $1 == "cpu:" { c = $2; gsub(/"/, "", c) }
    r && $1 == "memory:" { m = $2; gsub(/"/, "", m) }
    END { if (c != "" && (found || r)) print c ":" m }
  ')
  [[ "$got" == "$cpu:$memory" ]] || { echo "$name: requests ${got:-none}, want $cpu:$memory (small tier)"; return 1; }
}

failures=0
while read -r profile queue ingest compaction; do
  [[ -n "$profile" ]] || continue
  for smithdb in off on; do
    out="$TEST_TMP/$profile-smithdb-$smithdb.yaml"
    label="$profile profile, SmithDB $smithdb"
    if ! render "$profile" "$smithdb" "$out"; then
      echo "FAIL: $label: the chart rejected the values"
      sed 's/^/      /' "$out.err"
      failures=$((failures + 1))
      continue
    fi
    problems=()
    msg=$(expect_scaler "$out" langsmith-queue "$queue") || problems+=("$msg")
    msg=$(expect_scaler "$out" langsmith-ingest-queue "$ingest") || problems+=("$msg")
    if [[ "$smithdb" == on ]]; then
      msg=$(expect_scaler "$out" langsmith-smithdb-compaction-worker "$compaction") || problems+=("$msg")
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
done <<< "$EXPECTED"

# Feature overlays load after the base values, and some after the sizing file,
# so a queue autoscaling key in one would override both without notice.
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
  case "${overlay##*/}" in langsmith-values-sizing-*) continue ;; esac
  found=$(key_paths "$overlay" \
    | grep -E '^(queue|ingestQueue)(\.|$)|^smithdb\.compactionWorker\.autoscaling(\.|$)' \
    | head -1) || true
  if [[ -n "$found" ]]; then
    echo "FAIL: ${overlay##*/} sets $found; only the base and sizing files may"
    overlay_failures=$((overlay_failures + 1))
  fi
done
if (( overlay_failures )); then
  failures=$((failures + overlay_failures))
else
  echo "PASS: no feature overlay sets queue, ingest-queue, or compaction-worker autoscaling"
fi

# SmithDB sizing is not part of the sizing profiles: the SmithDB overlay sets the
# tier once, and an operator changes it there with the node inputs.
tier_failures=0
for sizing in "$EXAMPLES_DIR"/langsmith-values-sizing-*.yaml; do
  found=$(key_paths "$sizing" | grep -E '^smithdb(\.|$)' | head -1) || true
  if [[ -n "$found" ]]; then
    echo "FAIL: ${sizing##*/} sets $found; SmithDB sizing belongs in langsmith-values-smithdb.yaml"
    tier_failures=$((tier_failures + 1))
  fi
done
if ! grep -qE '^  resourceTier: "?small"?$' "$EXAMPLES_DIR/langsmith-values-smithdb.yaml"; then
  echo "FAIL: langsmith-values-smithdb.yaml does not set smithdb.resourceTier: small"
  tier_failures=$((tier_failures + 1))
fi
if (( tier_failures )); then
  failures=$((failures + tier_failures))
else
  echo "PASS: no sizing profile sets SmithDB keys, and the SmithDB overlay sets the small tier"
fi

if (( failures )); then
  echo "$failures values check(s) failed"
  exit 1
fi
