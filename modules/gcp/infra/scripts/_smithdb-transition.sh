#!/usr/bin/env bash

# --set-json replaces the selector map, whereas another YAML overlay merges it
# and leaves the old pool keys behind. Clear legacy service resources so the
# chart tier controls network-cache workloads; migration and TaskDB keep their own sizing.
_smithdb_managed_values() {
  local path values setting
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
  values=$(_smithdb_cache_values small "${VALUES_ARGS[@]}") || return 1
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

# Refuse to remove legacy pools until deployments and TaskDB have moved.
_smithdb_transition_ready() {
  local namespace="$1" release="$2" cache_class="$3" workloads nodes pods
  workloads=$(kubectl get deployments,statefulsets -n "$namespace" -l "app.kubernetes.io/instance=$release" -o json) || return 1
  if ! jq -e '[.items[] | select(
      (.metadata.name | contains("smithdb")) or
      .spec.template.spec.nodeSelector["smithdb-local/instance-store"] != null or
      .spec.template.spec.nodeSelector["smithdb-local/compute"] != null
    )] | length >= 5 and all(.[];
      .spec.template.spec.nodeSelector == {"langsmith-nodepool/smithdb":"true"} and
      (.status.observedGeneration // 0) >= .metadata.generation and
      (.status.updatedReplicas // 0) == (.spec.replicas // 1) and
      (.status.readyReplicas // 0) == (.spec.replicas // 1) and
      (if .kind == "StatefulSet" then .status.currentRevision == .status.updateRevision else true end)
    )' <<< "$workloads" >/dev/null; then
    echo "ERROR: keep smithdb_transition_mode = true until SmithDB and TaskDB are ready on the new pool." >&2
    return 1
  fi
  if ! jq -e --arg sc "$cache_class" '[.items[] | select(.spec.template.spec.nodeSelector["langsmith-nodepool/smithdb"] == "true") | .spec.template.spec.volumes[]? | select(.name == "cache")] |
      length > 0 and all(.[]; .ephemeral.volumeClaimTemplate.spec.storageClassName == $sc)' <<< "$workloads" >/dev/null; then
    echo "ERROR: run make init-values and make deploy to move SmithDB caches to the generated StorageClass." >&2
    return 1
  fi
  nodes=$(kubectl get nodes -o json) || return 1
  pods=$(kubectl get pods -A -o json) || return 1
  if ! jq -e --argjson nodes "$nodes" '[.items[] |
      select(.spec.nodeName as $node | any($nodes.items[];
        .metadata.name == $node and
        (.metadata.labels["smithdb-local/instance-store"] == "true" or .metadata.labels["smithdb-local/compute"] == "true"))) |
      select(.status.phase != "Succeeded" and .status.phase != "Failed") |
      select(any(.metadata.ownerReferences[]?; .kind == "DaemonSet") | not)
    ] | length == 0' <<< "$pods" >/dev/null; then
    echo "ERROR: application pods still use the old SmithDB pools. Keep transition mode enabled." >&2
    return 1
  fi
}
