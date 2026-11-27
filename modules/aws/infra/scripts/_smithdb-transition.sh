#!/usr/bin/env bash

# The node selector and tolerations that put a SmithDB workload on its managed
# node group, as YAML for init-values.sh to write under the matching `smithdb:`
# key. <indent> is the column the nodeSelector key starts in.
_smithdb_pool_scheduling() {
  local indent="$1"
  printf '%snodeSelector:\n' "$indent"
  printf '%s  langsmith-nodepool/smithdb: "true"\n' "$indent"
  printf '%stolerations:\n' "$indent"
  printf '%s  - key: langsmith-nodepool/smithdb\n' "$indent"
  printf '%s    operator: Equal\n' "$indent"
  printf '%s    value: "true"\n' "$indent"
  printf '%s    effect: NoSchedule\n' "$indent"
}

# A langsmith-values-smithdb.yaml copied from an older release pins the Karpenter
# pools (smithdb-local/instance-store, smithdb-local/compute). Helm merges node
# selectors across values files, and a null does not remove a key that only an
# earlier file sets, so those keys would sit next to the managed-pool key and no
# node would match. Replace such a copy with the current example and keep the old
# one beside it. Returns 1 when the file needs no replacing.
_smithdb_refresh_legacy_overlay() {
  local file="$1" example="$2"
  grep -q 'smithdb-local/' "$file" 2>/dev/null || return 1
  cp "$file" "${file%.yaml}.legacy.yaml" && cp "$example" "$file"
}

# Switching SmithDB query on for a release that serves reads from ClickHouse
# hides that release's traces in the UI until they are migrated. Returns 0 for a
# new install (no release yet) or a release that already queries SmithDB, and 1,
# with the reason, otherwise. A failed lookup returns 1.
_smithdb_query_cutover_check() {
  local release="$1" namespace="$2" found live
  found=$(helm list -a -n "$namespace" --filter "^${release}\$" -q) || {
    echo "ERROR: could not list the Helm releases in $namespace, so the SmithDB query check cannot run." >&2
    echo "       Check cluster access (make kubeconfig), or set smithdb_query_enabled = true in terraform.tfvars for a new install." >&2
    return 1
  }
  [[ -n "$found" ]] || return 0
  live=$(helm get values "$release" -n "$namespace" --all -o json |
    jq -r '.smithdb.langsmith.query.enabled // false') || live=""
  [[ "$live" == "true" ]] && return 0
  echo "ERROR: release $release serves reads from ClickHouse, and these values would switch them to SmithDB." >&2
  echo "       The UI would stop showing its existing traces until they are migrated." >&2
  echo "       Set smithdb_query_enabled = false in terraform.tfvars (enable_smithdb = false keeps SmithDB off)," >&2
  echo "       or set it to true to confirm, then run make apply and make init-values." >&2
  echo "       See SMITHDB.md, \"Upgrading from 0.17\"." >&2
  return 1
}

# Node scheduling comes from the generated overrides (see _smithdb_pool_scheduling).
# --set-json replaces a map, whereas another YAML overlay merges it, so the legacy
# service resources are cleared here: the chart tier controls EBS workloads, while
# migration and TaskDB keep their own sizing. The tier is smithdb.resourceTier from
# the values files (langsmith-values-smithdb.yaml sets small), and small when none
# does. The resolved tier is left in SMITHDB_RESOURCE_TIER for _smithdb_tier_fits.
# <cache_storage> is the mode from _smithdb_cache_mode, network-disk by default.
_smithdb_managed_values() {
  local cache_storage="${1:-network-disk}" path values setting tier=small
  for path in query mutations runRules statsQuery ingestion compactionWorker compaction clusterManager; do
    VALUES_ARGS+=(--set-json "smithdb.$path.deployment.resources={}")
  done
  values=$(_smithdb_cache_values "$tier" "${VALUES_ARGS[@]}" --set-string "cacheStorage=$cache_storage") || return 1
  # deploy.sh reads the tier after this returns.
  # shellcheck disable=SC2034
  SMITHDB_RESOURCE_TIER=$(jq -er '."smithdb.resourceTier"' <<< "$values") || return 1
  while IFS= read -r setting; do
    VALUES_ARGS+=(--set-json "$setting")
  done < <(jq -r 'to_entries[] | "\(.key)=\(.value | tojson)"' <<< "$values")
}

# Prints the cache mode for this deploy. <applied> is the smithdb_cache_storage
# output and <wanted> the terraform.tfvars value; either may be empty. The local-ssd
# cache needs nodes that have the RAID0 array, so it is used only when both say
# local-ssd. That makes make deploy, make apply, make deploy safe for a switch in
# either direction.
_smithdb_cache_mode() {
  local applied="${1:-network-disk}" wanted="${2:-network-disk}"
  case "$applied" in
    network-disk|local-ssd) ;;
    *) echo "ERROR: unknown smithdb_cache_storage output \"$applied\"." >&2; return 1 ;;
  esac
  if [[ "$applied" == local-ssd && "$wanted" == local-ssd ]]; then
    echo local-ssd
    return 0
  fi
  if [[ "$wanted" == local-ssd ]]; then
    echo "NOTE: the SmithDB caches stay on EBS until make apply adds the local SSD. Then run make deploy again." >&2
  elif [[ "$applied" == local-ssd ]]; then
    echo "NOTE: the SmithDB caches move to EBS now. Run make apply next to roll the SmithDB nodes." >&2
  fi
  echo network-disk
}

# The tier comes from the Helm values and the node size from Terraform, so only a
# deploy can compare them. Each size is the tier's largest pod in the chart's tier
# table, over both layouts (cluster, and from chart 0.18 unified), so the check
# holds for either smithdb.topology. With the local-ssd cache, the largest cache
# must also fit the node's allocatable ephemeral-storage. Returns 1, with the
# reason, when no SmithDB node can hold that pod.
_smithdb_tier_fits() {
  local tier="$1" cache_storage="${2:-network-disk}" cpu mem disk=0 nodes need
  case "$tier" in
    small) cpu=8 mem=16 ;;
    medium) cpu=28 mem=64 ;;
    large) cpu=56 mem=150 ;;
    *) return 0 ;;
  esac
  if [[ "$cache_storage" == "local-ssd" ]]; then
    case "$tier" in
      small) disk=200 ;;
      medium) disk=300 ;;
      large) disk=1000 ;;
    esac
  fi
  nodes=$(kubectl get nodes -l langsmith-nodepool/smithdb=true -o json) || {
    echo "ERROR: could not list the SmithDB nodes, so the SmithDB tier check cannot run." >&2
    return 1
  }
  jq -e --argjson cpu "$cpu" --argjson mem "$mem" --argjson disk "$disk" '
    def cores: if endswith("m") then (rtrimstr("m") | tonumber / 1000) else tonumber end;
    def gib: if endswith("Ki") then (rtrimstr("Ki") | tonumber / 1048576)
      elif endswith("Mi") then (rtrimstr("Mi") | tonumber / 1024)
      elif endswith("Gi") then (rtrimstr("Gi") | tonumber)
      else (tonumber / 1073741824) end;
    any(.items[]; (.status.allocatable.cpu | cores) >= $cpu and (.status.allocatable.memory | gib) >= $mem and
      ($disk == 0 or ((.status.allocatable["ephemeral-storage"] // "0") | gib) >= $disk))
  ' <<< "$nodes" >/dev/null && return 0
  need="$cpu vCPU and $mem GiB"
  [[ "$disk" == 0 ]] || need="$cpu vCPU, $mem GiB, and $disk GiB of ephemeral-storage"
  echo "ERROR: smithdb.resourceTier $tier needs a SmithDB node with $need allocatable, and node-group-smithdb has none." >&2
  echo "       Set smithdb_node_instance_type for that tier in terraform.tfvars and run make apply," >&2
  echo "       or set a smaller tier in langsmith-values-smithdb.yaml. See SMITHDB.md, \"Scaling up\"." >&2
  return 1
}

# langsmith-values.yaml loads before langsmith-values-smithdb.yaml, so a tier set in
# it, such as one moved there from a 0.17 sizing file, would be replaced without
# notice. Returns 1, with the fix, when the file sets a tier other than the deployed one.
_smithdb_base_tier_check() {
  local file="$1" deployed="$2" tier
  [[ -f "$file" ]] || return 0
  tier=$(awk '
    /^[^ #]/ { s = ($1 == "smithdb:") }
    s && /^  resourceTier:/ { v = $2; gsub(/["\047]/, "", v); print v; exit }
  ' "$file")
  [[ -z "$tier" || "$tier" == "$deployed" ]] && return 0
  echo "ERROR: ${file##*/} sets smithdb.resourceTier: $tier, but langsmith-values-smithdb.yaml loads after it, so the release would run the $deployed tier." >&2
  echo "       Set the tier in langsmith-values-smithdb.yaml and remove it from ${file##*/}. See SMITHDB.md, \"Scaling up\"." >&2
  return 1
}

# Use Helm's YAML merge to replace only cache overrides, preserving unrelated
# volumes and mounts. This also handles existing values files during transition.
# The network-disk cache drops every cache volume, so the chart generates its gp3
# claim. The local-ssd cache (--set-string cacheStorage=local-ssd) replaces it with
# an emptyDir named cache and sets the tier's CPU and memory with a matching
# ephemeral-storage, which the chart needs for an emptyDir cache.
_smithdb_cache_values() (
  set -euo pipefail
  local chart tier="$1"
  shift
  chart=$(mktemp -d)
  trap 'rm -rf "$chart"' EXIT
  mkdir "$chart/templates"
  printf 'apiVersion: v2\nname: smithdb-cache\nversion: 0.1.0\n' > "$chart/Chart.yaml"
  cat > "$chart/templates/values.yaml" <<'TEMPLATE'
{{- $tier := default .Values.fallbackTier .Values.smithdb.resourceTier -}}
{{- $settings := dict "smithdb.resourceTier" $tier -}}
{{- $localSsd := eq (default "network-disk" .Values.cacheStorage) "local-ssd" -}}
{{- /* CPU, memory, and cache per replica of the disk-using components, copied
       from the chart's tier table (the same in chart 0.17.61 and 0.18.1). The
       dedicated query services use the query sizes. */ -}}
{{- $sizes := dict
  "small" (dict
    "query" (list "4" "8Gi" "200Gi")
    "ingestion" (list "4" "8Gi" "100Gi")
    "compactionWorker" (list "8" "16Gi" "100Gi")
    "unified" (list "4" "16Gi" "100Gi"))
  "medium" (dict
    "query" (list "28" "48Gi" "200Gi")
    "ingestion" (list "16" "32Gi" "100Gi")
    "compactionWorker" (list "16" "32Gi" "100Gi")
    "unified" (list "16" "64Gi" "300Gi"))
  "large" (dict
    "query" (list "28" "50Gi" "1000Gi")
    "ingestion" (list "56" "150Gi" "1000Gi")
    "compactionWorker" (list "28" "50Gi" "300Gi")
    "unified" (list "32" "128Gi" "1000Gi")) -}}
{{- if and $localSsd (not (hasKey $sizes $tier)) -}}
  {{- fail (printf "the local-ssd cache has no sizes for smithdb.resourceTier %q" $tier) -}}
{{- end -}}
{{- $components := list "query" "mutations" "runRules" "statsQuery" "ingestion" "compactionWorker" -}}
{{- if $localSsd -}}
  {{- $components = append $components "unified" -}}
{{- end -}}
{{- range $name := $components -}}
  {{- $deployment := default (dict) (dig $name "deployment" (dict) $.Values.smithdb) -}}
  {{- $volumes := list -}}
  {{- range $deployment.volumes -}}
    {{- if not (has .name (list "cache" "local-ssd-storage")) -}}
      {{- $volumes = append $volumes . -}}
    {{- end -}}
  {{- end -}}
  {{- if $localSsd -}}
    {{- $size := index (index $sizes $tier) (ternary "query" $name (has $name (list "mutations" "runRules" "statsQuery"))) -}}
    {{- $volumes = append $volumes (dict "name" "cache" "emptyDir" (dict "sizeLimit" (index $size 2))) -}}
    {{- $resources := dict "cpu" (index $size 0) "memory" (index $size 1) "ephemeral-storage" (index $size 2) -}}
    {{- $_ := set $settings (printf "smithdb.%s.deployment.resources" $name) (dict "requests" $resources "limits" $resources) -}}
  {{- end -}}
  {{- $_ := set $settings (printf "smithdb.%s.deployment.volumes" $name) $volumes -}}
  {{- /* The unified pod mounts the cache twice (/data and /tmp), so its mounts stay as the chart sets them. */ -}}
  {{- if ne $name "unified" -}}
    {{- with $deployment.volumeMounts -}}
      {{- range . -}}
        {{- if has .name (list "cache" "local-ssd-storage") -}}
          {{- $_ := set . "name" "cache" -}}
          {{- $_ := set . "mountPath" (ternary "/tmp" "/data" (eq $name "compactionWorker")) -}}
        {{- end -}}
      {{- end -}}
      {{- $_ := set $settings (printf "smithdb.%s.deployment.volumeMounts" $name) . -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toJson (dict "apiVersion" "v1" "kind" "ConfigMap" "metadata" (dict "name" "smithdb-cache") "data" (dict "values" (toJson $settings))) -}}
TEMPLATE
  helm template smithdb-cache "$chart" "$@" --set-string "fallbackTier=$tier" |
    sed '/^#/d; /^---$/d' | jq -er '.data.values'
)

_smithdb_old_instances() {
  aws ec2 describe-instances --region "$2" --filters \
    "Name=tag:kubernetes.io/cluster/$1,Values=owned" \
    "Name=tag:karpenter.sh/nodepool,Values=smithdb-instance-store,smithdb-compute" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# <cache_storage> is the planned smithdb_cache_storage output, network-disk by default.
_smithdb_cleanup() {
  local namespace="$1" release="$2" region="$3" cache_class="$4" cluster="$5" cache_storage="${6:-network-disk}"
  local workloads nodes claims pods pools node_names claim_names instance_ids ec2_ids
  workloads=$(kubectl get deployments,statefulsets -n "$namespace" -l "app.kubernetes.io/instance=$release" -o json) || return 1
  # Check the complete rollout, including TaskDB. A ready old replica alone
  # does not prove that the updated pod template can schedule.
  if ! jq -e '[.items[] | select(
      (.metadata.name | contains("smithdb")) or
      .spec.template.spec.nodeSelector["langsmith-nodepool/smithdb"] == "true" or
      .spec.template.spec.nodeSelector["smithdb-local/instance-store"] != null or
      .spec.template.spec.nodeSelector["smithdb-local/compute"] != null
    )] | length >= 5 and all(.[];
      .spec.template.spec.nodeSelector["langsmith-nodepool/smithdb"] == "true" and
      .spec.template.spec.nodeSelector["smithdb-local/instance-store"] == null and
      .spec.template.spec.nodeSelector["smithdb-local/compute"] == null and
      (.status.observedGeneration // 0) >= .metadata.generation and
      (.status.updatedReplicas // 0) == (.spec.replicas // 1) and
      (.status.readyReplicas // 0) == (.spec.replicas // 1) and
      (if .kind == "StatefulSet" then .status.currentRevision == .status.updateRevision else true end)
    )' <<< "$workloads" >/dev/null; then
    echo "ERROR: SmithDB or TaskDB is not ready on the managed node group." >&2
    echo "Set smithdb_transition_mode = true, make apply, make init-values, then make deploy." >&2
    return 1
  fi
  # With local-ssd, the caches stay on EBS until the nodes that have the RAID0
  # array run, so both kinds pass.
  if ! jq -e --arg sc "$cache_class" --arg mode "$cache_storage" '[.items[] |
      select(.spec.template.spec.nodeSelector["langsmith-nodepool/smithdb"] == "true") |
      .spec.template.spec.volumes[]? | select(.name == "cache")] |
      length > 0 and all(.[]; .ephemeral.volumeClaimTemplate.spec.storageClassName == $sc or
        ($mode == "local-ssd" and .emptyDir != null))' <<< "$workloads" >/dev/null; then
    if [[ "$cache_storage" == "local-ssd" ]]; then
      echo "ERROR: SmithDB caches must use the generated EBS StorageClass or an emptyDir on the local SSD." >&2
    else
      echo "ERROR: SmithDB caches must use the generated EBS StorageClass." >&2
    fi
    echo "Run make deploy to apply the tier resources and caches." >&2
    return 1
  fi

  pools=$(kubectl get nodepools -o json) || return 1
  claims=$(kubectl get nodeclaims -o json) || return 1
  nodes=$(kubectl get nodes -l karpenter.sh/nodepool -o json) || return 1
  pods=$(kubectl get pods -A -o json) || return 1
  # This module owns Karpenter. Other pools/claims must not lose their controller.
  if ! jq -e '[.items[].metadata.name | select(. != "smithdb-instance-store" and . != "smithdb-compute")] | length == 0' <<< "$pools" >/dev/null ||
     ! jq -e 'all(.items[]; .metadata.labels["karpenter.sh/nodepool"] == "smithdb-instance-store" or .metadata.labels["karpenter.sh/nodepool"] == "smithdb-compute")' <<< "$claims" >/dev/null ||
     ! jq -e 'all(.items[]; .metadata.labels["karpenter.sh/nodepool"] == "smithdb-instance-store" or .metadata.labels["karpenter.sh/nodepool"] == "smithdb-compute")' <<< "$nodes" >/dev/null; then
    echo "ERROR: other Karpenter pools or nodes remain. Keep transition mode enabled." >&2
    return 1
  fi
  if ! jq -e --argjson nodes "$nodes" '[.items[] |
      select(.spec.nodeName as $node | any($nodes.items[]; .metadata.name == $node)) |
      select(.status.phase != "Succeeded" and .status.phase != "Failed") |
      select(any(.metadata.ownerReferences[]?; .kind == "DaemonSet") | not)
    ] | length == 0' <<< "$pods" >/dev/null; then
    echo "ERROR: application pods still use Karpenter nodes. Move them before cleanup." >&2
    return 1
  fi
  # Capture EC2 IDs before Karpenter removes the Kubernetes objects. Waiting on
  # Kubernetes alone can leave terminating instances behind without a controller.
  instance_ids=$(jq -nr --argjson nodes "$nodes" --argjson claims "$claims" '
    [$nodes.items[].spec.providerID, $claims.items[].status.providerID] |
    map(select(. != null) | split("/")[-1]) | unique | .[]') || return 1
  # A previous attempt may have lost its Kubernetes objects before the EC2
  # waiter failed. Rediscover those instances so retries still wait for them.
  ec2_ids=$(_smithdb_old_instances "$cluster" "$region") || return 1
  instance_ids=$(printf '%s\n%s\n' "$instance_ids" "$ec2_ids" | tr '[:space:]' '\n' | sort -u) || return 1
  if [[ -n "$instance_ids" ]] && ! [[ "$instance_ids" =~ ^[i0-9a-f[:space:]-]+$ ]]; then
    echo "ERROR: could not identify old EC2 instances safely." >&2
    return 1
  fi
  node_names=$(jq -r '.items[].metadata.name' <<< "$nodes") || return 1
  claim_names=$(jq -r '.items[].metadata.name' <<< "$claims") || return 1
  echo "SmithDB is healthy. Removing old pools; Karpenter stays running until nodes terminate..."
  kubectl delete nodepool smithdb-instance-store smithdb-compute --ignore-not-found --wait=true --timeout=15m || return 1
  local name
  for name in $claim_names; do
    kubectl wait --for=delete "nodeclaim/$name" --timeout=15m || return 1
  done
  for name in $node_names; do
    kubectl wait --for=delete "node/$name" --timeout=15m || return 1
  done
  if [[ -n "$instance_ids" ]]; then
    # Word splitting is intentional: the waiter accepts a list of EC2 IDs.
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --region "$region" --instance-ids $instance_ids || return 1
  fi
  # Recheck after termination; do not rely solely on the earlier snapshot.
  claims=$(kubectl get nodeclaims -o json) || return 1
  nodes=$(kubectl get nodes -l karpenter.sh/nodepool -o json) || return 1
  ec2_ids=$(_smithdb_old_instances "$cluster" "$region") || return 1
  [[ -z "$ec2_ids" ]] && jq -e '.items | length == 0' <<< "$claims" >/dev/null &&
    jq -e '.items | length == 0' <<< "$nodes" >/dev/null || {
      echo "ERROR: Karpenter nodes, claims, or EC2 instances remain. Keeping the controller; check them and rerun make apply." >&2
      return 1
    }
}
