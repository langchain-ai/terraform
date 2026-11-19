#!/usr/bin/env bash
# Effective SmithDB values checks; no cloud access.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_smithdb-values.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR

# Verify the effective Helm values, including old local-SSD overrides and
# unrelated customer volumes. No application chart or cloud access is needed.
command -v helm >/dev/null || { echo "helm is required for SmithDB values tests" >&2; exit 2; }
mkdir -p "$TEST_DIR/chart/templates"
printf 'apiVersion: v2\nname: values-test\nversion: 0.1.0\n' > "$TEST_DIR/chart/Chart.yaml"
cat > "$TEST_DIR/chart/templates/values.yaml" <<'TEMPLATE'
{{ toJson (dict "apiVersion" "v1" "kind" "ConfigMap" "metadata" (dict "name" "values-test") "data" (dict "values" (toJson .Values.smithdb))) }}
TEMPLATE
cat > "$TEST_DIR/legacy.json" <<'VALUES'
{"smithdb":{
  "query":{"deployment":{
    "resources":{"requests":{"cpu":"99","memory":"99Gi","ephemeral-storage":"200Gi"}},
    "nodeSelector":{"kubernetes.azure.com/agentpool":"smithdb"},
    "tolerations":[{"key":"workload","operator":"Equal","value":"smithdb","effect":"NoSchedule"}],
    "volumes":[{"name":"local-ssd-storage","emptyDir":{}},{"name":"customer-config","configMap":{"name":"customer-config"}}],
    "volumeMounts":[{"name":"local-ssd-storage","mountPath":"/data"},{"name":"customer-config","mountPath":"/config"}]
  }},
  "compaction":{"deployment":{"resources":{"requests":{"cpu":"99"}}}},
  "compactionWorker":{"deployment":{
    "volumes":[{"name":"local-ssd-storage","emptyDir":{}}],
    "volumeMounts":[{"name":"local-ssd-storage","mountPath":"/tmp"}]
  }},
  "migration":{"job":{
    "parallelism":3,
    "nodeSelector":{"customer-pool":"migration"},
    "tolerations":[{"key":"customer-migration","operator":"Exists"}],
    "podSecurityContext":{"fsGroup":2000},
    "volumes":[{"name":"migration-scratch","emptyDir":{"sizeLimit":"100Gi"}}],
    "volumeMounts":[{"name":"migration-scratch","mountPath":"/tmp"}],
    "resources":{"requests":{"cpu":"12","ephemeral-storage":"100Gi"}}},
    "taskdb":{"postgres":{"auth":{"existingSecretName":"existing-taskdb"},"statefulSet":{"resources":{"requests":{"memory":"12Gi"}}}}}}
}}
VALUES
VALUES_ARGS=(-f "$TEST_DIR/legacy.json")
_sizing_profile=production
_smithdb_managed_values '[{"key":"langsmith-nodepool/smithdb","operator":"Equal","value":"true","effect":"NoSchedule"},{"key":"workload","operator":"Equal","value":"smithdb","effect":"NoSchedule"}]'
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq --slurpfile original "$TEST_DIR/legacy.json" -e '
  .resourceTier == "medium" and
  .query.deployment.nodeSelector == {"langsmith-nodepool/smithdb":"true"} and
  (.metastoreMigration.job.tolerations | any(.key == "workload" and .value == "smithdb")) and
  (.migration.taskdb.postgres.statefulSet.tolerations | any(.key == "workload" and .value == "smithdb")) and
  (.query.deployment.tolerations | any(.key == "workload" and .value == "smithdb")) and
  (.query.deployment.tolerations | any(.key == "langsmith-nodepool/smithdb" and .value == "true" and .effect == "NoSchedule")) and
  .query.deployment.resources == {} and .compaction.deployment.resources == {} and
  .compactionWorker.deployment.volumes == [] and
  .compactionWorker.deployment.volumeMounts == [{name:"cache",mountPath:"/tmp"}] and
  .query.deployment.volumes == [{name:"customer-config",configMap:{name:"customer-config"}}] and
  .query.deployment.volumeMounts == [{name:"cache",mountPath:"/data"},{name:"customer-config",mountPath:"/config"}] and
  .migration.job == $original[0].smithdb.migration.job and
  .migration.taskdb.postgres.statefulSet.resources.requests.memory == "12Gi" and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: Managed Disk cache clears legacy service overrides and preserves migration, TaskDB, and customer volumes"

VALUES_ARGS=(--set smithdb.enabled=true --set smithdb.resourceTier=large)
_sizing_profile=dev
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '.resourceTier == "large" and .query.deployment.resources == {} and .query.deployment.volumes == [] and (.migration | has("job") | not)' "$TEST_DIR/values.json" >/dev/null
echo "PASS: new Managed Disk deployments preserve an explicitly selected resource tier"

# Exercise the generated override after chart defaults and older customer values.
cat > "$TEST_DIR/chart/values.yaml" <<'VALUES'
smithdb:
  migration:
    job:
      resources:
        requests: {cpu: "8", memory: 32Gi, ephemeral-storage: 100Gi}
        limits: {cpu: "8", memory: 32Gi, ephemeral-storage: 100Gi}
VALUES
(
  export _smithdb_overrides="$TEST_DIR/generated.yaml"
  export SMITHDB_CACHE_STORAGE_CLASS=smithdb-cache-test
  export _langsmith_release_fullname=langsmith
  export SMITHDB_WI_CLIENT_ID=fixture-identity
  export SMITHDB_METASTORE_SECRET=fixture-metastore
  export SMITHDB_STORAGE_CONTAINER=fixture-container
  export SMITHDB_STORAGE_ACCOUNT=fixture-account
  export SMITHDB_STORAGE_BLOB_ENDPOINT=""
  export _smithdb_password_secret_key='"password"'
  export _smithdb_iam_auth_provider='""'
  export _smithdb_iam_username='""'
  export _smithdb_ingestion_enabled=true
  export _smithdb_migration_enabled=true
  export _smithdb_query_enabled=false
  sed -n '/^  cat > "\$_smithdb_overrides" <<SMITHDB_YAML$/,/^SMITHDB_YAML$/p' \
    "$SCRIPT_DIR/../../helm/scripts/init-values.sh" > "$TEST_DIR/generate.sh"
  source "$TEST_DIR/generate.sh"
)
# Capture the original chart/customer Job before applying generated overrides.
helm template values-test "$TEST_DIR/chart" -f "$TEST_DIR/legacy.json" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/original.json"
VALUES_ARGS=(-f "$TEST_DIR/legacy.json" -f "$TEST_DIR/generated.yaml")
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq --slurpfile original "$TEST_DIR/original.json" -e '
  (.migration.job | del(.labels)) == ($original[0].migration.job | del(.labels)) and
  .migration.job.labels == {"azure.workload.identity/use":"true"} and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: generated overrides preserve original chart and customer migration Job settings"
