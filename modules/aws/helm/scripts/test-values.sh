#!/usr/bin/env bash
# Renders the LangSmith chart with the AWS example values, in deploy.sh's order,
# for every sizing profile with SmithDB off and on, and checks which scaler the
# queue services get. No cluster and no AWS calls.
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
default          fixed:1    fixed:3    hpa:1:10
minimum          fixed:1    fixed:1    hpa:1:10
dev              keda:1:5   keda:1:5   hpa:1:10
production       keda:3:10  keda:3:10  hpa:1:10
production-large keda:6:24  keda:6:24  hpa:4:10
"

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
cat > "$TEST_TMP/smithdb-overrides.yaml" <<'EOF'
smithdb:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/values-test-smithdb"
  config:
    objectStore:
      type: "s3"
      bucket: "values-test-smithdb"
      s3:
        region: "us-west-2"
        accessKeyIdSecretKey: ""
        secretAccessKeySecretKey: ""
    metastore:
      hostSecretKey: "smithdb_metastore_db_host"
      databaseSecretKey: "smithdb_metastore_db_name"
      usernameSecretKey: "smithdb_metastore_db_username"
      passwordSecretKey: "smithdb_metastore_db_password"
      port: "5432"
      useSsl: true
  metastoreMigration:
    useSsl: true
  langsmith:
    ingestion:
      enabled: false
    migration:
      enabled: false
    query:
      enabled: false
EOF

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
    elif [[ -n "$(manifest "$out" Deployment langsmith-smithdb-compaction-worker)" ]]; then
      problems+=("langsmith-smithdb-compaction-worker: rendered with SmithDB off")
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

if (( failures )); then
  echo "$failures values check(s) failed"
  exit 1
fi
