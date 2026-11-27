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
  "migration":{"job":{"parallelism":3,"resources":{"requests":{"cpu":"12","ephemeral-storage":"100Gi"}},
    "nodeSelector":{"customer-pool":"migration"},
    "tolerations":[{"key":"customer-pool","operator":"Equal","value":"migration","effect":"NoSchedule"}],
    "volumes":[{"name":"scratch","emptyDir":{}}],
    "volumeMounts":[{"name":"scratch","mountPath":"/tmp"}],"podSecurityContext":{"fsGroup":1001}},
    "taskdb":{"postgres":{"auth":{"existingSecretName":"existing-taskdb"},"statefulSet":{"resources":{"requests":{"memory":"12Gi"}}}}}}
}}
VALUES
VALUES_ARGS=(-f "$TEST_DIR/legacy.json")
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e --slurpfile before "$TEST_DIR/legacy.json" '
  .resourceTier == "small" and
  .query.deployment.resources == {} and .compaction.deployment.resources == {} and
  .query.deployment.volumes == [{name:"customer-config",configMap:{name:"customer-config"}}] and
  .query.deployment.volumeMounts == [{name:"cache",mountPath:"/data"},{name:"customer-config",mountPath:"/config"}] and
  .compactionWorker.deployment.volumes == [] and
  .compactionWorker.deployment.volumeMounts == [{name:"cache",mountPath:"/tmp"}] and
  .migration.job == $before[0].smithdb.migration.job and
  .migration.taskdb.postgres.statefulSet.resources.requests.memory == "12Gi" and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
[[ "$SMITHDB_RESOURCE_TIER" == small ]] || { echo "FAIL: the resolved tier is $SMITHDB_RESOURCE_TIER, want small"; exit 1; }
echo "PASS: EBS clears legacy service overrides, uses the small tier when no values file sets one, and preserves migration, TaskDB, and customer volumes"

VALUES_ARGS=(--set smithdb.enabled=true --set smithdb.resourceTier=large)
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '.resourceTier == "large" and .query.deployment.resources == {} and .query.deployment.volumes == [] and .unified == null' "$TEST_DIR/values.json" >/dev/null
[[ "$SMITHDB_RESOURCE_TIER" == large ]] || { echo "FAIL: the resolved tier is $SMITHDB_RESOURCE_TIER, want large"; exit 1; }
echo "PASS: new EBS deployments preserve an explicitly selected resource tier"

# The local-ssd cache replaces each cache volume with an emptyDir of the tier's cache
# size, and sets requests equal to limits with ephemeral-storage, as the chart needs.
VALUES_ARGS=(-f "$TEST_DIR/legacy.json" --set smithdb.resourceTier=medium)
_smithdb_managed_values local-ssd
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e '
  def res($cpu; $mem; $disk): {cpu: $cpu, memory: $mem, "ephemeral-storage": $disk} as $r | {requests: $r, limits: $r};
  def cache($size): {name: "cache", emptyDir: {sizeLimit: $size}};
  .resourceTier == "medium" and
  .query.deployment.resources == res("28"; "48Gi"; "200Gi") and
  .statsQuery.deployment.resources == res("28"; "48Gi"; "200Gi") and
  .ingestion.deployment.resources == res("16"; "32Gi"; "100Gi") and
  .compactionWorker.deployment.resources == res("16"; "32Gi"; "100Gi") and
  .unified.deployment.resources == res("16"; "64Gi"; "300Gi") and
  .compaction.deployment.resources == {} and .clusterManager.deployment.resources == {} and
  .query.deployment.volumes == [{name: "customer-config", configMap: {name: "customer-config"}}, cache("200Gi")] and
  .query.deployment.volumeMounts == [{name: "cache", mountPath: "/data"}, {name: "customer-config", mountPath: "/config"}] and
  .compactionWorker.deployment.volumes == [cache("100Gi")] and
  .compactionWorker.deployment.volumeMounts == [{name: "cache", mountPath: "/tmp"}] and
  .unified.deployment.volumes == [cache("300Gi")] and .unified.deployment.volumeMounts == null
' "$TEST_DIR/values.json" >/dev/null || { echo "FAIL: the local-ssd cache values are wrong"; jq . "$TEST_DIR/values.json"; exit 1; }
[[ "$SMITHDB_RESOURCE_TIER" == medium ]] || { echo "FAIL: the resolved tier is $SMITHDB_RESOURCE_TIER, want medium"; exit 1; }
echo "PASS: the local-ssd cache writes emptyDir caches with the tier's resources, and keeps customer volumes"

VALUES_ARGS=(--set smithdb.resourceTier=xlarge)
if _smithdb_managed_values local-ssd 2> "$TEST_DIR/tier.err"; then
  echo "FAIL: the local-ssd cache accepted a tier with no sizes"; exit 1
fi
grep -q 'no sizes for smithdb.resourceTier "xlarge"' "$TEST_DIR/tier.err"
echo "PASS: the local-ssd cache stops on a tier it has no sizes for"

# deploy.sh uses the local-ssd cache only when terraform.tfvars and the applied
# node group both have it. An empty value is a state or tfvars without the setting.
for spec in local-ssd:local-ssd:local-ssd local-ssd:network-disk:network-disk \
    network-disk:local-ssd:network-disk :local-ssd:network-disk ::network-disk; do
  IFS=: read -r applied wanted want <<< "$spec"
  got=$(_smithdb_cache_mode "$applied" "$wanted" 2>/dev/null)
  [[ "$got" == "$want" ]] || { echo "FAIL: the cache mode for output '$applied' and tfvars '$wanted' is $got, want $want"; exit 1; }
done
_smithdb_cache_mode network-disk local-ssd 2>&1 >/dev/null | grep -q 'stay on EBS until make apply'
_smithdb_cache_mode local-ssd network-disk 2>&1 >/dev/null | grep -q 'Run make apply next'
if _smithdb_cache_mode nvme local-ssd > /dev/null 2>&1; then echo "FAIL: an unknown cache output was accepted"; exit 1; fi
echo "PASS: the local-ssd cache needs both terraform.tfvars and the applied node group"

# Exercise the generated override after chart defaults and older customer values.
cat > "$TEST_DIR/chart/values.yaml" <<'VALUES'
smithdb:
  migration:
    job:
      resources:
        requests: {cpu: "8", memory: 32Gi, ephemeral-storage: 100Gi}
        limits: {cpu: "8", memory: 32Gi, ephemeral-storage: 100Gi}
VALUES
helm template values-test "$TEST_DIR/chart" -f "$TEST_DIR/legacy.json" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/before.json"
(
  export _smithdb_overrides="$TEST_DIR/generated.yaml"
  export SMITHDB_CACHE_STORAGE_CLASS=smithdb-cache-test
  export SMITHDB_BUCKET=fixture-bucket
  export SMITHDB_IRSA_ROLE_ARN=fixture-role
  export _region=us-east-2
  export _smithdb_metastore_use_ssl=true
  export _smithdb_ingestion_enabled=true
  export _smithdb_query_enabled=false
  sed -n '/^  cat > "\$_smithdb_overrides" << SMITHDB_YAML$/,/^SMITHDB_YAML$/p' \
    "$SCRIPT_DIR/../../helm/scripts/init-values.sh" > "$TEST_DIR/generate.sh"
  source "$TEST_DIR/generate.sh"
)
VALUES_ARGS=(-f "$TEST_DIR/legacy.json" -f "$TEST_DIR/generated.yaml")
_smithdb_managed_values
helm template values-test "$TEST_DIR/chart" "${VALUES_ARGS[@]}" |
  sed '/^#/d; /^---$/d' | jq -er '.data.values' > "$TEST_DIR/values.json"
jq -e --slurpfile before "$TEST_DIR/before.json" '
  .cache.storageClassName == "smithdb-cache-test" and
  .migration.job == $before[0].migration.job and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: generated service cache settings preserve the migration Job and TaskDB settings"

# The generated overrides put every SmithDB service, the metastore migration Job on
# the managed node group. migration.job is not touched here.
jq -e '
  def pool: {"langsmith-nodepool/smithdb": "true"};
  def tol: [{key:"langsmith-nodepool/smithdb", operator:"Equal", value:"true", effect:"NoSchedule"}];
  ([.query.deployment, .mutations.deployment, .runRules.deployment, .statsQuery.deployment,
    .ingestion.deployment, .compactionWorker.deployment, .compaction.deployment,
    .clusterManager.deployment, .metastoreMigration.job]
   | all(.[]; .nodeSelector == pool and .tolerations == tol))
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: generated overrides schedule SmithDB on the managed pool"

# A langsmith-values-smithdb.yaml from an older release pins the Karpenter pools, and Helm would
# merge those keys with the new one. init-values.sh replaces such a copy first.
cat > "$TEST_DIR/legacy-smithdb.yaml" <<'LEGACY'
smithdb:
  enabled: true
  query:
    deployment:
      nodeSelector:
        smithdb-local/instance-store: "true"
      tolerations:
        - key: smithdb-local/instance-store
          operator: Equal
          value: "true"
          effect: NoSchedule
  compaction:
    deployment:
      nodeSelector:
        smithdb-local/compute: "true"
LEGACY
printf 'smithdb:\n  enabled: true\n' > "$TEST_DIR/example-smithdb.yaml"
render_pools() { helm template values-test "$TEST_DIR/chart" "$@" | sed '/^#/d; /^---$/d' | jq -er '.data.values'; }
render_pools -f "$TEST_DIR/legacy-smithdb.yaml" -f "$TEST_DIR/generated.yaml" > "$TEST_DIR/stale.json"
jq -e '.query.deployment.nodeSelector["smithdb-local/instance-store"] == "true"' "$TEST_DIR/stale.json" >/dev/null ||
  { echo "FAIL: the old pool selector no longer merges, so the refresh below may be unnecessary"; exit 1; }
_smithdb_refresh_legacy_overlay "$TEST_DIR/legacy-smithdb.yaml" "$TEST_DIR/example-smithdb.yaml"
[[ -f "$TEST_DIR/legacy-smithdb.legacy.yaml" ]] && grep -q 'smithdb-local/instance-store' "$TEST_DIR/legacy-smithdb.legacy.yaml"
if _smithdb_refresh_legacy_overlay "$TEST_DIR/legacy-smithdb.yaml" "$TEST_DIR/example-smithdb.yaml"; then
  echo "FAIL: a current overlay was replaced"; exit 1
fi
render_pools -f "$TEST_DIR/legacy-smithdb.yaml" -f "$TEST_DIR/generated.yaml" > "$TEST_DIR/fresh.json"
jq -e '
  def pool: {"langsmith-nodepool/smithdb": "true"};
  .query.deployment.nodeSelector == pool and .compaction.deployment.nodeSelector == pool
' "$TEST_DIR/fresh.json" >/dev/null
echo "PASS: an overlay that pins the old Karpenter pools is replaced, and only the managed pool remains"

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
  'get deployments,statefulsets')
    case "$CASE" in
      unhealthy) jq '.items[0].status.updatedReplicas=0' "$TEST_DIR/workloads.json" ;;
      taskdb) jq '.items[-1].status.currentRevision="old"' "$TEST_DIR/workloads.json" ;;
      cache) jq '.items[0].spec.template.spec.volumes=[{name:"cache",emptyDir:{}}]' "$TEST_DIR/workloads.json" ;;
      host_cache) jq '.items[0].spec.template.spec.volumes=[{name:"cache",hostPath:{path:"/mnt"}}]' "$TEST_DIR/workloads.json" ;;
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
      echo '{"items":[{"metadata":{"name":"migration-job","ownerReferences":[{"kind":"Job"}]},"spec":{"nodeName":"old-node"},"status":{"phase":"Running"}}]}'
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
  state) : ;;  # upgrade-guard.sh: an empty state list passes
  *) exit 2 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/"*

for CASE in unhealthy taskdb cache api_failure other_pool old_pod termination healthy; do
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

# With the local-ssd cache, emptyDir caches pass, and so do the EBS caches that
# stay until the new nodes run. Any other cache volume stops the cleanup.
for spec in cache:pass healthy:pass host_cache:refuse; do
  IFS=: read -r CASE want <<< "$spec"
  export CASE
  rm -f "$TEST_DIR/deleted" "$TEST_DIR/waited"
  : > "$TEST_DIR/events"
  if _smithdb_cleanup langsmith langsmith us-east-2 smithdb-cache-test test-eks local-ssd > "$TEST_DIR/log" 2>&1; then
    [[ "$want" == pass ]] || { echo "FAIL: local-ssd cleanup accepted $CASE"; exit 1; }
  else
    if [[ "$want" == pass ]] || ! grep -q 'or an emptyDir on the local SSD' "$TEST_DIR/log"; then
      echo "FAIL: local-ssd cleanup refused $CASE"; cat "$TEST_DIR/log"; exit 1
    fi
    ! grep -q 'kubectl delete' "$TEST_DIR/events" || { echo "FAIL: cleanup deleted nodes for $CASE"; exit 1; }
  fi
  echo "PASS: local-ssd cleanup $CASE: $want"
done

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

# apply.sh passes the planned cache mode, so a local-ssd plan accepts emptyDir caches.
jq '.planned_values.outputs.smithdb_cache_storage = {value: "local-ssd"}' "$TEST_DIR/plan.json" > "$TEST_DIR/plan-local.json"
mv "$TEST_DIR/plan-local.json" "$TEST_DIR/plan.json"
export CASE=cache
rm -f "$TEST_DIR/deleted" "$TEST_DIR/waited"
: > "$TEST_DIR/events"
bash "$SCRIPT_DIR/apply.sh" -auto-approve > "$TEST_DIR/log" 2>&1 || { cat "$TEST_DIR/log"; echo "FAIL: a local-ssd apply refused emptyDir caches"; exit 1; }
grep -q 'terraform .* apply' "$TEST_DIR/events"
echo "PASS: apply passes the local-ssd cache mode to the cleanup"

# init-values.sh must not switch a release that serves reads from ClickHouse to SmithDB
# queries. The fake helm is on PATH only inside the subshell, so the real helm above is
# untouched. A refusal must name its reason.
mkdir "$TEST_DIR/helm-bin"
cat > "$TEST_DIR/helm-bin/helm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  list)
    [[ "$CASE" != list_failure ]] || exit 1
    [[ "$CASE" == new_install ]] || echo langsmith ;;
  get)
    case "$CASE" in
      on_smithdb) echo '{"smithdb":{"langsmith":{"query":{"enabled":true}}}}' ;;
      staged) echo '{"smithdb":{"enabled":true,"langsmith":{"query":{"enabled":false}}}}' ;;
      *) echo '{"clickhouse":{"external":{"enabled":false}}}' ;;
    esac ;;
  *) echo "Unexpected helm call: $*" >&2; exit 2 ;;
esac
MOCK
chmod +x "$TEST_DIR/helm-bin/helm"
for CASE in new_install on_smithdb staged without_smithdb list_failure; do
  export CASE
  case "$CASE" in
    new_install|on_smithdb) want="" ;;
    list_failure) want="could not list the Helm releases" ;;
    *) want="serves reads from ClickHouse" ;;
  esac
  if (PATH="$TEST_DIR/helm-bin:$PATH" _smithdb_query_cutover_check langsmith langsmith) 2> "$TEST_DIR/query.err"; then
    [[ -z "$want" ]] || { echo "FAIL: query cutover accepted $CASE"; exit 1; }
  elif [[ -z "$want" ]] || ! grep -qF "$want" "$TEST_DIR/query.err"; then
    echo "FAIL: query cutover refused $CASE"; cat "$TEST_DIR/query.err"; exit 1
  fi
  echo "PASS: query cutover $CASE"
done

# deploy.sh stops when the tier's largest pod fits no SmithDB node. The fake kubectl
# is on PATH only inside the subshell, and reports approximate EKS allocatable values
# for each instance type. An unknown tier is left to the chart, without a node lookup.
# The m6a and c6a nodes have a 100 GiB boot disk; the m6id nodes report the RAID0
# instance store as ephemeral-storage.
mkdir "$TEST_DIR/tier-bin"
cat > "$TEST_DIR/tier-bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
node() { printf '{"items":[{"status":{"allocatable":{"cpu":"%s","memory":"%s","ephemeral-storage":"%s"}}}]}\n' "$1" "$2" "$3"; }
case "$NODES" in
  m6a.4xlarge) node 15890m 60612856Ki 95491281146 ;;
  m6a.8xlarge) node 31850m 126495224Ki 95491281146 ;;
  m6a.16xlarge) node 63770m 256000000Ki 95491281146 ;;
  c6a.16xlarge) node 63770m 125000000Ki 95491281146 ;;
  m6id.4xlarge) node 15890m 60612856Ki 805306368Ki ;;
  m6id.8xlarge) node 31850m 126495224Ki 1610612736Ki ;;
  m6id.16xlarge) node 63770m 256000000Ki 3221225472Ki ;;
  none) echo '{"items":[]}' ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_DIR/tier-bin/kubectl"
for spec in small:m6a.4xlarge:pass medium:m6a.4xlarge:refuse medium:m6a.8xlarge:pass \
    large:m6a.8xlarge:refuse large:m6a.16xlarge:pass large:c6a.16xlarge:refuse \
    small:none:refuse small:failure:refuse custom:failure:pass; do
  IFS=: read -r tier NODES want <<< "$spec"
  export NODES
  if (PATH="$TEST_DIR/tier-bin:$PATH" _smithdb_tier_fits "$tier") 2> "$TEST_DIR/tier.err"; then
    [[ "$want" == pass ]] || { echo "FAIL: the $tier tier was accepted on $NODES"; exit 1; }
  elif [[ "$want" == pass ]] || ! grep -qE 'needs a SmithDB node|could not list the SmithDB nodes' "$TEST_DIR/tier.err"; then
    echo "FAIL: the $tier tier was refused on $NODES"; cat "$TEST_DIR/tier.err"; exit 1
  fi
  echo "PASS: tier check, $tier on $NODES: $want"
done

# With the local-ssd cache, the tier's largest cache must also fit the node's
# allocatable ephemeral-storage, which a boot disk alone does not give.
for spec in small:m6id.4xlarge:pass small:m6a.4xlarge:refuse medium:m6id.8xlarge:pass \
    medium:m6id.4xlarge:refuse large:m6id.16xlarge:pass large:m6a.16xlarge:refuse; do
  IFS=: read -r tier NODES want <<< "$spec"
  export NODES
  if (PATH="$TEST_DIR/tier-bin:$PATH" _smithdb_tier_fits "$tier" local-ssd) 2> "$TEST_DIR/tier.err"; then
    [[ "$want" == pass ]] || { echo "FAIL: the local-ssd $tier tier was accepted on $NODES"; exit 1; }
  elif [[ "$want" == pass ]] || ! grep -q 'GiB of ephemeral-storage allocatable' "$TEST_DIR/tier.err"; then
    echo "FAIL: the local-ssd $tier tier was refused on $NODES"; cat "$TEST_DIR/tier.err"; exit 1
  fi
  echo "PASS: local-ssd tier check, $tier on $NODES: $want"
done

# A tier set in the base values must be the deployed one, because the SmithDB
# overlay loads after them and wins. Only the top-level smithdb block counts.
printf 'queue:\n  autoscaling: {}\nsmithdb:\n  resourceTier: "medium"  # moved from a sizing file\n' > "$TEST_DIR/base-medium.yaml"
printf 'smithdb:\n  query:\n    autoscaling:\n      hpa:\n        minReplicas: 1\n' > "$TEST_DIR/base-no-tier.yaml"
printf 'polly:\n  resourceTier: large\n' > "$TEST_DIR/base-other-key.yaml"
_smithdb_base_tier_check "$TEST_DIR/base-medium.yaml" medium
_smithdb_base_tier_check "$TEST_DIR/base-no-tier.yaml" small
_smithdb_base_tier_check "$TEST_DIR/base-other-key.yaml" small
_smithdb_base_tier_check "$TEST_DIR/no-such-file.yaml" small
if _smithdb_base_tier_check "$TEST_DIR/base-medium.yaml" small 2> "$TEST_DIR/base.err"; then
  echo "FAIL: a base-values tier that the SmithDB overlay replaces was accepted"; exit 1
fi
grep -q 'base-medium.yaml sets smithdb.resourceTier: medium' "$TEST_DIR/base.err"
echo "PASS: a base-values tier other than the deployed one stops the deploy, and a matching or absent one does not"
