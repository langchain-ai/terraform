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
  "compactionWorker":{"deployment":{
    "volumes":[{"name":"local-ssd-storage","emptyDir":{}}],
    "volumeMounts":[{"name":"local-ssd-storage","mountPath":"/data"}]
  }},
  "compaction":{"deployment":{"resources":{"requests":{"cpu":"99"}}}},
  "migration":{"job":{"parallelism":3,"resources":{"requests":{"cpu":"12","ephemeral-storage":"100Gi"}}},
    "taskdb":{"postgres":{"auth":{"existingSecretName":"existing-taskdb"},"statefulSet":{"resources":{"requests":{"memory":"12Gi"}}}}}}
}}
VALUES
VALUES_ARGS=(-f "$TEST_DIR/legacy.json")
_sizing_profile=production
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
echo "PASS: EBS clears legacy service overrides and preserves migration, TaskDB, and customer volumes"

VALUES_ARGS=(--set smithdb.enabled=true --set smithdb.resourceTier=large)
_sizing_profile=dev
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '.resourceTier == "large" and .query.deployment.resources == {} and .query.deployment.volumes == []' "$TEST_DIR/values.json" >/dev/null
echo "PASS: new EBS deployments preserve an explicitly selected resource tier"

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
  export SMITHDB_BUCKET=fixture-bucket
  export SMITHDB_IRSA_ROLE_ARN=fixture-role
  export _region=us-east-2
  export _smithdb_metastore_use_ssl=true
  export _smithdb_ingestion_enabled=true
  export _smithdb_migration_enabled=true
  export _smithdb_query_enabled=false
  sed -n '/^  cat > "\$_smithdb_overrides" << SMITHDB_YAML$/,/^SMITHDB_YAML$/p' \
    "$SCRIPT_DIR/../../helm/scripts/init-values.sh" > "$TEST_DIR/generate.sh"
  source "$TEST_DIR/generate.sh"
)
VALUES_ARGS=(-f "$TEST_DIR/legacy.json" -f "$TEST_DIR/generated.yaml")
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '
  .migration.job.volumes == [{name:"cache",ephemeral:{volumeClaimTemplate:{spec:{
    accessModes:["ReadWriteOnce"],storageClassName:.cache.storageClassName,
    resources:{requests:{storage:"100Gi"}}}}}}] and
  .migration.job.volumeMounts == [{name:"cache",mountPath:"/tmp"}] and
  .migration.job.podSecurityContext.fsGroup == 1001 and
  (.migration.job.resources.requests | has("ephemeral-storage") | not) and
  (.migration.job.resources.limits | has("ephemeral-storage") | not) and
  .migration.job.resources.requests.cpu == "12" and
  .migration.job.resources.requests.memory == "32Gi" and
  .migration.job.parallelism == 3 and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: generated migration EBS scratch replaces node storage and preserves CPU, memory, parallelism, and TaskDB"

jq -n '{items: ([range(0;5) | {
  kind:"Deployment", metadata:{name:("langsmith-smithdb-" + tostring), generation:2},
  spec:{replicas:1, template:{spec:{nodeSelector:{"langsmith-nodepool/smithdb":"true"},
    volumes:[{name:"cache", ephemeral:{volumeClaimTemplate:{spec:{storageClassName:"smithdb-cache-test"}}}}]}}},
  status:{observedGeneration:2, updatedReplicas:1, readyReplicas:1}
}] + [{kind:"StatefulSet", metadata:{name:"langsmith-smithdb-taskdb", generation:2},
  spec:{replicas:1, template:{spec:{nodeSelector:{"langsmith-nodepool/smithdb":"true"}}}},
  status:{observedGeneration:2, updatedReplicas:1, readyReplicas:1, currentRevision:"new", updateRevision:"new"}}])}' > "$TEST_DIR/workloads.json"
printf '%s\n' '{"items":[]}' > "$TEST_DIR/empty.json"
printf '%s\n' '{"items":[{"metadata":{"name":"old-node","labels":{"karpenter.sh/nodepool":"smithdb-instance-store"}},"spec":{"providerID":"aws:///us-east-2a/i-0123456789abcdef0"}}]}' > "$TEST_DIR/nodes.json"
printf '%s\n' '{"items":[{"metadata":{"name":"old-claim","labels":{"karpenter.sh/nodepool":"smithdb-instance-store"}},"status":{"providerID":"aws:///us-east-2a/i-0123456789abcdef0"}}]}' > "$TEST_DIR/claims.json"
printf '%s\n' '{"items":[{"metadata":{"name":"smithdb-instance-store"}},{"metadata":{"name":"smithdb-compute"}}]}' > "$TEST_DIR/pools.json"

cat > "$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "kubectl $*" >> "$TEST_DIR/events"
case "$1 $2" in
  'get jobs,deployments')
    if [[ "$CASE" == completed ]]; then
      echo '{"items":[{"kind":"Job","metadata":{"name":"langsmith-smithdb-migration"},"spec":{"template":{"spec":{}}},"status":{"conditions":[{"type":"Complete","status":"True"}]}}]}'
    elif [[ "$CASE" == migration ]]; then
      echo '{"items":[{"kind":"Job","metadata":{"name":"langsmith-smithdb-migration"},"spec":{"template":{"spec":{"nodeSelector":{"smithdb-local/instance-store":"true"}}}}}]}'
    else cat "$TEST_DIR/empty.json"; fi ;;
  'get deployments,statefulsets')
    case "$CASE" in
      unhealthy) jq '.items[0].status.updatedReplicas=0' "$TEST_DIR/workloads.json" ;;
      taskdb) jq '.items[-1].status.currentRevision="old"' "$TEST_DIR/workloads.json" ;;
      cache) jq '.items[0].spec.template.spec.volumes=[{name:"cache",emptyDir:{}}]' "$TEST_DIR/workloads.json" ;;
      api_failure) exit 1 ;;
      *) cat "$TEST_DIR/workloads.json" ;;
    esac ;;
  'get nodepools')
    if [[ "$CASE" == other_pool ]]; then
      echo '{"items":[{"metadata":{"name":"unrelated"}}]}'
    else cat "$TEST_DIR/pools.json"; fi ;;
  'get nodeclaims')
    if [[ -f "$TEST_DIR/deleted" || "$CASE" == retry ]]; then cat "$TEST_DIR/empty.json"; else cat "$TEST_DIR/claims.json"; fi ;;
  'get nodes')
    if [[ -f "$TEST_DIR/deleted" || "$CASE" == retry ]]; then cat "$TEST_DIR/empty.json"; else cat "$TEST_DIR/nodes.json"; fi ;;
  'get pods')
    if [[ "$CASE" == old_pod ]]; then
      echo '{"items":[{"metadata":{"name":"taskdb"},"spec":{"nodeName":"old-node"},"status":{"phase":"Running"}}]}'
    else cat "$TEST_DIR/empty.json"; fi ;;
  'delete nodepool') touch "$TEST_DIR/deleted" ;;
  'wait --for=delete') : ;;
  *) echo "Unexpected kubectl call: $*" >&2; exit 2 ;;
esac
MOCK
cat > "$TEST_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "aws $*" >> "$TEST_DIR/events"
if [[ "$1 $2" == 'ec2 wait' && "$CASE" == termination ]]; then exit 1; fi
if [[ "$1 $2" == 'ec2 wait' ]]; then touch "$TEST_DIR/waited"; fi
if [[ "$1 $2" == 'ec2 describe-instances' && "$CASE" == retry && ! -f "$TEST_DIR/waited" ]]; then echo i-0123456789abcdef0; fi
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

for CASE in unhealthy taskdb cache migration api_failure other_pool old_pod termination healthy; do
  export CASE
  rm -f "$TEST_DIR/deleted" "$TEST_DIR/waited"
  : > "$TEST_DIR/events"
  if _smithdb_cleanup langsmith langsmith us-east-2 smithdb-cache-test test-eks > "$TEST_DIR/log" 2>&1; then
    [[ "$CASE" == healthy ]] || { echo "FAIL: cleanup accepted $CASE"; exit 1; }
    grep -q 'aws ec2 wait instance-terminated' "$TEST_DIR/events"
  else
    [[ "$CASE" != healthy ]] || { cat "$TEST_DIR/log"; exit 1; }
    if [[ "$CASE" != termination ]]; then
      ! grep -q 'kubectl delete' "$TEST_DIR/events" || { echo "FAIL: cleanup deleted nodes for $CASE"; exit 1; }
    fi
  fi
  echo "PASS: cleanup $CASE"
done

export CASE=retry
rm -f "$TEST_DIR/deleted" "$TEST_DIR/waited"
: > "$TEST_DIR/events"
_smithdb_cleanup langsmith langsmith us-east-2 smithdb-cache-test test-eks > "$TEST_DIR/log" 2>&1
grep -q 'aws ec2 wait instance-terminated.*i-0123456789abcdef0' "$TEST_DIR/events"
echo "PASS: retry waits for EC2 even after Kubernetes objects disappear"

export CASE=completed
_smithdb_check_migration langsmith langsmith false
if _smithdb_check_migration langsmith langsmith true > "$TEST_DIR/log" 2>&1; then
  echo "FAIL: changing a completed legacy Job template was allowed"; exit 1
fi
echo "PASS: completed legacy Job can be removed but cannot be mutated"

# Test the user entry point: a failed live check must prevent Terraform from
# applying the controller-removal plan; a successful cleanup must finish first.
jq -n '{variables:{enable_smithdb:{value:true}, smithdb_transition_mode:{value:false},
    region:{value:"us-east-2"}, langsmith_namespace:{value:"langsmith"}, langsmith_release_name:{value:"langsmith"}},
  planned_values:{outputs:{cluster_name:{value:"test-eks"}, smithdb_cache_storage_class_name:{value:"smithdb-cache-test"}}},
  resource_changes:[{address:"module.eks.module.eks_blueprints_addons.module.karpenter.helm_release.this[0]",
    change:{actions:["delete"]}}]}' > "$TEST_DIR/plan.json"
for CASE in unhealthy termination healthy; do
  export CASE
  rm -f "$TEST_DIR/deleted" "$TEST_DIR/waited"
  : > "$TEST_DIR/events"
  if bash "$SCRIPT_DIR/apply.sh" -auto-approve > "$TEST_DIR/log" 2>&1; then
    [[ "$CASE" == healthy ]] || { echo "FAIL: apply accepted $CASE"; exit 1; }
    awk '/aws ec2 wait/ { waited=1 } /terraform .* apply/ { if (!waited) exit 1; applied=1 } END { if (!applied) exit 1 }' "$TEST_DIR/events"
  else
    [[ "$CASE" != healthy ]] || { cat "$TEST_DIR/log"; exit 1; }
    ! grep -q 'terraform .* apply' "$TEST_DIR/events" || { echo "FAIL: apply ran after $CASE"; exit 1; }
  fi
  echo "PASS: apply $CASE"
done
