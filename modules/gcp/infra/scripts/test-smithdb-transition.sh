#!/usr/bin/env bash
# Behavioral cleanup tests. All cloud/Kubernetes/Terraform commands are mocked.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_smithdb-transition.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
mkdir "$TEST_DIR/bin"
export PATH="$TEST_DIR/bin:$PATH"

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
    "volumes":[{"name":"local-ssd-storage","emptyDir":{}},{"name":"customer-config","configMap":{"name":"customer-config"}}],
    "volumeMounts":[{"name":"local-ssd-storage","mountPath":"/data"},{"name":"customer-config","mountPath":"/config"}]
  }},
  "compaction":{"deployment":{"resources":{"requests":{"cpu":"99"}}}},
  "compactionWorker":{"deployment":{"volumes":[{"name":"local-ssd-storage","emptyDir":{}}],"volumeMounts":[{"name":"local-ssd-storage","mountPath":"/data"}]}},
  "migration":{"job":{"parallelism":3,"resources":{"requests":{"cpu":"12","ephemeral-storage":"100Gi"}}},
    "taskdb":{"postgres":{"auth":{"existingSecretName":"existing-taskdb"},"statefulSet":{"resources":{"requests":{"memory":"12Gi"}}}}}}
}}
VALUES
VALUES_ARGS=(-f "$TEST_DIR/legacy.json")
VALUES_ARGS+=(--set smithdb.resourceTier=medium)
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '
  .resourceTier == "medium" and
  .query.deployment.resources == {} and .compaction.deployment.resources == {} and
  .query.deployment.volumes == [{name:"customer-config",configMap:{name:"customer-config"}}] and
  .query.deployment.volumeMounts == [{name:"cache",mountPath:"/data"},{name:"customer-config",mountPath:"/config"}] and
  .compactionWorker.deployment.volumes == [] and
  .compactionWorker.deployment.volumeMounts == [{name:"cache",mountPath:"/tmp"}] and
  .migration.job.parallelism == 3 and .migration.job.resources.requests.cpu == "12" and
  .migration.job.resources.requests["ephemeral-storage"] == "100Gi" and
  .migration.taskdb.postgres.statefulSet.resources.requests.memory == "12Gi" and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: network cache clears legacy service overrides and preserves migration, TaskDB, and customer volumes"

VALUES_ARGS=(--set smithdb.enabled=true --set smithdb.resourceTier=large)
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '.resourceTier == "large" and .query.deployment.resources == {} and .query.deployment.volumes == []' "$TEST_DIR/values.json" >/dev/null
echo "PASS: new network-cache deployments preserve an explicitly selected resource tier"

# Exercise the real generator in both cache modes, after older migration values.
cat > "$TEST_DIR/chart/values.yaml" <<'VALUES'
smithdb:
  migration:
    job:
      resources:
        requests: {cpu: "8", memory: 32Gi, ephemeral-storage: 100Gi}
        limits: {cpu: "8", memory: 32Gi, ephemeral-storage: 100Gi}
VALUES
sed -n '/^  # Migration scratch on network disk/,/^  echo "  ✔ Written /p' \
  "$SCRIPT_DIR/../../helm/scripts/init-values.sh" | sed '$d' > "$TEST_DIR/generate.sh"
terraform() {
  case "$*" in
    *"output -raw smithdb_cache_storage") echo "$CACHE_MODE" ;;
    *"output -raw smithdb_cache_storage_class_name") echo smithdb-cache-test ;;
    *) return 2 ;;
  esac
}
for CACHE_MODE in network-disk local-ssd; do
  export INFRA_DIR="$TEST_DIR"
  export _smithdb_overrides_file="$TEST_DIR/$CACHE_MODE-generated.yaml"
  printf 'smithdb:\n  enabled: true\n' > "$_smithdb_overrides_file"
  source "$TEST_DIR/generate.sh"
  VALUES_ARGS=(-f "$TEST_DIR/legacy.json" -f "$_smithdb_overrides_file")
  if [[ "$CACHE_MODE" == network-disk ]]; then _smithdb_managed_values; fi
  helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
    sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
  jq -e '.migration.job.parallelism == 3 and .migration.job.resources.requests.cpu == "12" and
    .migration.job.resources.requests.memory == "32Gi" and
    .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"' "$TEST_DIR/values.json" >/dev/null
  if [[ "$CACHE_MODE" == network-disk ]]; then
    jq -e '
      .migration.job.volumes == [{name:"cache",ephemeral:{volumeClaimTemplate:{spec:{
        accessModes:["ReadWriteOnce"],storageClassName:.cache.storageClassName,
        resources:{requests:{storage:"100Gi"}}}}}}] and
      .migration.job.volumeMounts == [{name:"cache",mountPath:"/tmp"}] and
      .migration.job.podSecurityContext.fsGroup == 1001 and
      (.migration.job.resources.requests | has("ephemeral-storage") | not) and
      (.migration.job.resources.limits | has("ephemeral-storage") | not)
    ' "$TEST_DIR/values.json" >/dev/null
  else
    jq -e '.migration.job.volumes == null and .migration.job.resources.requests["ephemeral-storage"] == "100Gi"' "$TEST_DIR/values.json" >/dev/null
  fi
  echo "PASS: generated migration $CACHE_MODE scratch preserves CPU, memory, parallelism, and TaskDB"
done
unset -f terraform

jq -n '{items: ([range(0;5) | {
  kind:"Deployment", metadata:{name:("langsmith-smithdb-" + tostring), generation:2},
  spec:{replicas:1, template:{spec:{nodeSelector:{"langsmith-nodepool/smithdb":"true"},
    volumes:[{name:"cache", ephemeral:{volumeClaimTemplate:{spec:{storageClassName:"smithdb-cache-test"}}}}]}}},
  status:{observedGeneration:2, updatedReplicas:1, readyReplicas:1}
}] + [{kind:"StatefulSet", metadata:{name:"langsmith-smithdb-taskdb", generation:2},
  spec:{replicas:1, template:{spec:{nodeSelector:{"langsmith-nodepool/smithdb":"true"}}}},
  status:{observedGeneration:2, updatedReplicas:1, readyReplicas:1, currentRevision:"new", updateRevision:"new"}}])}' > "$TEST_DIR/workloads.json"
printf '%s\n' '{"items":[]}' > "$TEST_DIR/empty.json"
cat > "$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "kubectl $*" >> "$TEST_DIR/events"
case "$1 $2" in
  'get jobs,deployments')
    if [[ "$CASE" == migration ]]; then
      echo '{"items":[{"kind":"Job","metadata":{"name":"langsmith-smithdb-migration"},"spec":{"template":{"spec":{"nodeSelector":{"smithdb-local/instance-store":"true"}}}}}]}'
    else cat "$TEST_DIR/empty.json"; fi ;;
  'get deployments,statefulsets')
    case "$CASE" in
      unhealthy) jq '.items[0].status.updatedReplicas=0' "$TEST_DIR/workloads.json" ;;
      taskdb) jq '.items[-1].status.currentRevision="old"' "$TEST_DIR/workloads.json" ;;
      cache) jq '.items[0].spec.template.spec.volumes=[{name:"cache",emptyDir:{}}]' "$TEST_DIR/workloads.json" ;;
      api_failure) exit 1 ;;
      unrelated_cache) jq '.items += [{kind:"Deployment",metadata:{name:"customer-addon"},spec:{template:{spec:{volumes:[{name:"cache",emptyDir:{}}]}}}}]' "$TEST_DIR/workloads.json" ;;
      *) cat "$TEST_DIR/workloads.json" ;;
    esac ;;
  'get nodes') echo '{"items":[{"metadata":{"name":"old-node","labels":{"smithdb-local/compute":"true"}}}]}' ;;
  'get pods')
    if [[ "$CASE" == old_pod ]]; then
      echo '{"items":[{"metadata":{"name":"taskdb"},"spec":{"nodeName":"old-node"},"status":{"phase":"Running"}}]}'
    else cat "$TEST_DIR/empty.json"; fi ;;
  *) echo "Unexpected kubectl call: $*" >&2; exit 2 ;;
esac
MOCK
cat > "$TEST_DIR/bin/gcloud" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "gcloud $*" >> "$TEST_DIR/events"
MOCK
cat > "$TEST_DIR/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "terraform $*" >> "$TEST_DIR/events"
case "$2" in
  show) cat "$TEST_DIR/plan.json" ;;
  plan|apply) : ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/"*
for CASE in unhealthy taskdb cache migration api_failure old_pod unrelated_cache healthy; do
  export CASE
  if _smithdb_transition_ready langsmith langsmith smithdb-cache-test > "$TEST_DIR/log" 2>&1; then
    [[ "$CASE" == healthy || "$CASE" == unrelated_cache ]] || { echo "FAIL: accepted $CASE"; exit 1; }
  else
    [[ "$CASE" != healthy && "$CASE" != unrelated_cache ]] || { cat "$TEST_DIR/log"; exit 1; }
  fi
  echo "PASS: transition $CASE"
done
jq -n '{variables:{enable_smithdb:{value:true}, smithdb_transition_mode:{value:false}, region:{value:"us-central1"}, project_id:{value:"fixture"}, langsmith_namespace:{value:"langsmith"}, langsmith_release_name:{value:"langsmith"}},
 planned_values:{outputs:{cluster_name:{value:"test-gke"},smithdb_cache_storage:{value:"network-disk"},smithdb_cache_storage_class_name:{value:"smithdb-cache-test"}}},
 resource_changes:[{type:"google_container_node_pool",name:"instance_store",change:{actions:["delete"],after:null}}]}' > "$TEST_DIR/plan.json"
for CASE in unhealthy migration healthy; do
  export CASE
  : > "$TEST_DIR/events"
  if bash "$SCRIPT_DIR/apply.sh" -auto-approve > "$TEST_DIR/log" 2>&1; then
    [[ "$CASE" == healthy ]] || { echo "FAIL: apply accepted $CASE"; exit 1; }
    grep -q 'terraform .* apply' "$TEST_DIR/events"
  else
    [[ "$CASE" != healthy ]] || { cat "$TEST_DIR/log"; exit 1; }
    ! grep -q 'terraform .* apply' "$TEST_DIR/events" || { echo "FAIL: apply ran after $CASE"; exit 1; }
  fi
  echo "PASS: apply $CASE"
done
# Existing explicit local-SSD pool rotations are not a transition cleanup.
jq '.planned_values.outputs.smithdb_cache_storage.value="local-ssd" | .resource_changes[0].change={actions:["delete","create"],after:{name:"cache-pool"}}' "$TEST_DIR/plan.json" > "$TEST_DIR/replacement.json"
mv "$TEST_DIR/replacement.json" "$TEST_DIR/plan.json"
export CASE=unhealthy
: > "$TEST_DIR/events"
bash "$SCRIPT_DIR/apply.sh" -auto-approve > "$TEST_DIR/log" 2>&1
grep -q 'terraform .* apply' "$TEST_DIR/events"
! grep -q 'kubectl' "$TEST_DIR/events"
echo "PASS: local-SSD pool replacement keeps the native Terraform behavior"

: > "$TEST_DIR/events"
bash "$SCRIPT_DIR/apply.sh" -parallelism=3 -lock-timeout 2m "$TEST_DIR/saved-plan" > "$TEST_DIR/log" 2>&1
grep -q "terraform .* apply -parallelism=3 -lock-timeout 2m $TEST_DIR/saved-plan" "$TEST_DIR/events"
! grep -q 'terraform .* plan ' "$TEST_DIR/events"
echo "PASS: saved-plan apply preserves runtime execution options"
