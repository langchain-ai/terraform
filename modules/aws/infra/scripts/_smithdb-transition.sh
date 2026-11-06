#!/usr/bin/env bash

# --set-json replaces the selector map, whereas another YAML overlay merges it
# and leaves the old pool keys behind. Clear legacy service resources so the
# chart tier controls EBS workloads; migration and TaskDB keep their own sizing.
_smithdb_managed_values() {
  local path values setting tier=small
  for path in query.deployment mutations.deployment runRules.deployment statsQuery.deployment \
    ingestion.deployment compactionWorker.deployment compaction.deployment clusterManager.deployment \
    metastoreMigration.job migration.taskdb.postgres.statefulSet; do
    VALUES_ARGS+=(
      --set-json "smithdb.$path.nodeSelector={\"langsmith-nodepool/smithdb\":\"true\"}"
      --set-json "smithdb.$path.tolerations=[{\"key\":\"langsmith-nodepool/smithdb\",\"operator\":\"Equal\",\"value\":\"true\",\"effect\":\"NoSchedule\"}]"
    )
  done
  for path in query mutations runRules statsQuery ingestion compactionWorker compaction clusterManager; do
    VALUES_ARGS+=(--set-json "smithdb.$path.deployment.resources={}")
  done
  case "${_sizing_profile:-default}" in
    production) tier=medium ;;
    production-large) tier=large ;;
  esac
  values=$(_smithdb_cache_values "$tier" "${VALUES_ARGS[@]}") || return 1
  while IFS= read -r setting; do
    VALUES_ARGS+=(--set-json "$setting")
  done < <(jq -r 'to_entries[] | "\(.key)=\(.value | tojson)"' <<< "$values")
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
