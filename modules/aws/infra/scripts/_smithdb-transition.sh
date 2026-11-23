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

# Each migration pod requests 100Gi of ephemeral storage, and the pods run on the
# SmithDB nodes. A node with the default 100 GiB boot disk cannot hold one, so the
# pods would stay Pending and the deploy would hang. Stop before anything is written.
_smithdb_migration_disk_check() {
  local gb="$1"
  [[ "$gb" =~ ^[0-9]+$ ]] || return 0
  (( gb >= 150 )) && return 0
  echo "ERROR: each migration pod requests 100Gi of ephemeral storage, and the SmithDB nodes have a ${gb} GiB boot disk, so the pods would stay Pending." >&2
  echo "       Set smithdb_node_root_volume_size_gb to at least 150 in terraform.tfvars, run make apply, then run this again." >&2
  return 1
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
_smithdb_managed_values() {
  local path values setting tier=small
  for path in query mutations runRules statsQuery ingestion compactionWorker compaction clusterManager; do
    VALUES_ARGS+=(--set-json "smithdb.$path.deployment.resources={}")
  done
  values=$(_smithdb_cache_values "$tier" "${VALUES_ARGS[@]}") || return 1
  # deploy.sh reads the tier after this returns.
  # shellcheck disable=SC2034
  SMITHDB_RESOURCE_TIER=$(jq -er '."smithdb.resourceTier"' <<< "$values") || return 1
  while IFS= read -r setting; do
    VALUES_ARGS+=(--set-json "$setting")
  done < <(jq -r 'to_entries[] | "\(.key)=\(.value | tojson)"' <<< "$values")
}

# The tier comes from the Helm values and the node size from Terraform, so only a
# deploy can compare them. Each size is the tier's largest pod in the chart's tier
# table, over both layouts (cluster, and from chart 0.18 unified), so the check
# holds for either smithdb.topology. Returns 1, with the reason, when no SmithDB
# node can hold that pod.
_smithdb_tier_fits() {
  local tier="$1" cpu mem nodes
  case "$tier" in
    small) cpu=8 mem=16 ;;
    medium) cpu=28 mem=64 ;;
    large) cpu=56 mem=150 ;;
    *) return 0 ;;
  esac
  nodes=$(kubectl get nodes -l langsmith-nodepool/smithdb=true -o json) || {
    echo "ERROR: could not list the SmithDB nodes, so the SmithDB tier check cannot run." >&2
    return 1
  }
  jq -e --argjson cpu "$cpu" --argjson mem "$mem" '
    def cores: if endswith("m") then (rtrimstr("m") | tonumber / 1000) else tonumber end;
    def gib: if endswith("Ki") then (rtrimstr("Ki") | tonumber / 1048576)
      elif endswith("Mi") then (rtrimstr("Mi") | tonumber / 1024)
      elif endswith("Gi") then (rtrimstr("Gi") | tonumber)
      else (tonumber / 1073741824) end;
    any(.items[]; (.status.allocatable.cpu | cores) >= $cpu and (.status.allocatable.memory | gib) >= $mem)
  ' <<< "$nodes" >/dev/null && return 0
  echo "ERROR: smithdb.resourceTier $tier needs a SmithDB node with $cpu vCPU and $mem GiB allocatable, and node-group-smithdb has none." >&2
  echo "       Set smithdb_node_instance_type for that tier in terraform.tfvars and run make apply," >&2
  echo "       or set a smaller tier in langsmith-values-smithdb.yaml. See SMITHDB.md, \"Scaling up\"." >&2
  return 1
}

# Use Helm's YAML merge to replace only cache overrides, preserving unrelated
# volumes and mounts. This also handles existing values files during transition.
_smithdb_cache_values() (
  set -euo pipefail
  local chart tier="$1"
  shift
  chart=$(mktemp -d)
  trap 'rm -rf "$chart"' EXIT
  mkdir "$chart/templates"
  printf 'apiVersion: v2\nname: smithdb-cache\nversion: 0.1.0\n' > "$chart/Chart.yaml"
  cat > "$chart/templates/values.yaml" <<'TEMPLATE'
{{- $settings := dict "smithdb.resourceTier" (default .Values.fallbackTier .Values.smithdb.resourceTier) -}}
{{- range $name := list "query" "mutations" "runRules" "statsQuery" "ingestion" "compactionWorker" -}}
  {{- $deployment := default (dict) (dig $name "deployment" (dict) $.Values.smithdb) -}}
  {{- $volumes := list -}}
  {{- range $deployment.volumes -}}
    {{- if not (has .name (list "cache" "local-ssd-storage")) -}}
      {{- $volumes = append $volumes . -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $settings (printf "smithdb.%s.deployment.volumes" $name) $volumes -}}
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

_smithdb_cleanup() {
  local namespace="$1" release="$2" region="$3" cache_class="$4" cluster="$5"
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
  if ! jq -e --arg sc "$cache_class" '[.items[] |
      select(.spec.template.spec.nodeSelector["langsmith-nodepool/smithdb"] == "true") |
      .spec.template.spec.volumes[]? | select(.name == "cache")] |
      length > 0 and all(.[]; .ephemeral.volumeClaimTemplate.spec.storageClassName == $sc)' <<< "$workloads" >/dev/null; then
    echo "ERROR: SmithDB caches must use the generated EBS StorageClass." >&2
    echo "Run make deploy to apply the tier resources and EBS caches." >&2
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
