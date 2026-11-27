#!/usr/bin/env bash
# Behavioral tests for the SmithDB helpers. All Kubernetes commands are mocked.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_smithdb.sh"
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
_sizing_profile=production
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
_sizing_profile=dev
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
jq -e --slurpfile before "$TEST_DIR/before.json" '
  .cache.storageClassName == "smithdb-cache-test" and
  .migration.job == $before[0].migration.job and
  .migration.taskdb.postgres.auth.existingSecretName == "existing-taskdb"
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: generated service cache settings preserve the migration Job and TaskDB settings"

# The generated overrides put every SmithDB service, the metastore migration Job and TaskDB on
# the managed node group. migration.job is not touched here.
jq -e '
  def pool: {"langsmith-nodepool/smithdb": "true"};
  def tol: [{key:"langsmith-nodepool/smithdb", operator:"Equal", value:"true", effect:"NoSchedule"}];
  ([.query.deployment, .mutations.deployment, .runRules.deployment, .statsQuery.deployment,
    .ingestion.deployment, .compactionWorker.deployment, .compaction.deployment,
    .clusterManager.deployment, .metastoreMigration.job,
    .migration.taskdb.postgres.statefulSet]
   | all(.[]; .nodeSelector == pool and .tolerations == tol))
' "$TEST_DIR/values.json" >/dev/null
echo "PASS: generated overrides schedule SmithDB and TaskDB on the managed pool"

# Migration pods request 100Gi of ephemeral storage, so a small boot disk stops the script
# instead of leaving the pods Pending.
for gb in 100 149; do
  if _smithdb_migration_disk_check "$gb" 2>"$TEST_DIR/disk.err"; then echo "FAIL: a ${gb} GiB boot disk was accepted"; exit 1; fi
done
grep -q "smithdb_node_root_volume_size_gb to at least 150" "$TEST_DIR/disk.err"
for gb in 150 400 not-a-number; do
  _smithdb_migration_disk_check "$gb" 2>/dev/null || { echo "FAIL: '$gb' was rejected"; exit 1; }
done
_smithdb_migration_disk_check 100 local-ssd || { echo "FAIL: the boot disk was checked with the local-ssd cache"; exit 1; }
echo "PASS: migration stops on a boot disk under 150 GiB and accepts 150 GiB or more, or any size with the local-ssd cache"

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

# A tier left in an earlier sizing file must be the deployed one, because the SmithDB
# overlay loads after it and wins. Only the top-level smithdb block counts.
printf 'queue:\n  autoscaling: {}\nsmithdb:\n  resourceTier: "medium"  # copied earlier\n' > "$TEST_DIR/sizing-medium.yaml"
printf 'smithdb:\n  query:\n    autoscaling:\n      hpa:\n        minReplicas: 1\n' > "$TEST_DIR/sizing-no-tier.yaml"
printf 'polly:\n  resourceTier: large\n' > "$TEST_DIR/sizing-other-key.yaml"
_smithdb_sizing_tier_check "$TEST_DIR/sizing-medium.yaml" medium
_smithdb_sizing_tier_check "$TEST_DIR/sizing-no-tier.yaml" small
_smithdb_sizing_tier_check "$TEST_DIR/sizing-other-key.yaml" small
_smithdb_sizing_tier_check "" small
_smithdb_sizing_tier_check "$TEST_DIR/no-such-file.yaml" small
if _smithdb_sizing_tier_check "$TEST_DIR/sizing-medium.yaml" small 2> "$TEST_DIR/sizing.err"; then
  echo "FAIL: a sizing-file tier that the SmithDB overlay replaces was accepted"; exit 1
fi
grep -q 'sizing-medium.yaml sets smithdb.resourceTier: medium' "$TEST_DIR/sizing.err"
echo "PASS: a sizing-file tier other than the deployed one stops the deploy, and a matching or absent one does not"
