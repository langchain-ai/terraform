#!/usr/bin/env bash
# Effective values and migration scheduling checks; no cloud access.
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
  "migration":{"job":{"parallelism":3,"resources":{"requests":{"cpu":"12","ephemeral-storage":"100Gi"}}},
    "taskdb":{"postgres":{"auth":{"existingSecretName":"existing-taskdb"},"statefulSet":{"resources":{"requests":{"memory":"12Gi"}}}}}}
}}
VALUES
VALUES_ARGS=(-f "$TEST_DIR/legacy.json")
_sizing_profile=production
_smithdb_managed_values '[{"key":"langsmith-nodepool/smithdb","operator":"Equal","value":"true","effect":"NoSchedule"},{"key":"workload","operator":"Equal","value":"smithdb","effect":"NoSchedule"}]'
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '
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
  .migration.job.parallelism == 3 and .migration.job.resources.requests.cpu == "12" and
  .migration.job.resources.requests["ephemeral-storage"] == "100Gi" and
  .migration.taskdb.postgres.statefulSet.resources.requests.memory == "12Gi" and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: Managed Disk cache clears legacy service overrides and preserves migration, TaskDB, and customer volumes"

VALUES_ARGS=(--set smithdb.enabled=true --set smithdb.resourceTier=large)
_sizing_profile=dev
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '.resourceTier == "large" and .query.deployment.resources == {} and .query.deployment.volumes == []' "$TEST_DIR/values.json" >/dev/null
echo "PASS: new Managed Disk deployments preserve an explicitly selected resource tier"

kubectl() { printf '%s\n' "$WORKLOADS"; }
WORKLOADS='{"items":[{"kind":"Job","metadata":{"name":"langsmith-smithdb-migration"},"spec":{"template":{"spec":{"nodeSelector":{"old-pool":"true"}}}}}]}'
if _smithdb_check_migration langsmith langsmith true > "$TEST_DIR/log" 2>&1; then
  echo "FAIL: active legacy migration Job was allowed to change pools"; exit 1
fi
echo "PASS: active legacy migration Job blocks scheduling changes"
WORKLOADS=$(jq '.items[0].status.conditions=[{type:"Complete",status:"True"}]' <<< "$WORKLOADS")
if _smithdb_check_migration langsmith langsmith true > "$TEST_DIR/log" 2>&1; then
  echo "FAIL: completed legacy migration Job was allowed to mutate"; exit 1
fi
_smithdb_check_migration langsmith langsmith false
echo "PASS: completed legacy migration Job can be removed without mutating its template"
WORKLOADS=$(jq '.items[0].spec.template.spec.nodeSelector={"langsmith-nodepool/smithdb":"true"} | del(.items[0].status)' <<< "$WORKLOADS")
_smithdb_check_migration langsmith langsmith true
echo "PASS: migration Job already on the dedicated pool is unchanged"
