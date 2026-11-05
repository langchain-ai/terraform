#!/usr/bin/env bash

# --set-json replaces the selector map, whereas another YAML overlay merges it
# and leaves the old pool keys behind. Clear legacy service resources so the
# chart tier controls network-cache workloads; migration and TaskDB keep their own sizing.
_smithdb_managed_values() {
  local path values setting tier=small pool_tolerations
  pool_tolerations=${1:-'[{"key":"langsmith-nodepool/smithdb","operator":"Equal","value":"true","effect":"NoSchedule"}]'}
  for path in query.deployment mutations.deployment runRules.deployment statsQuery.deployment \
    ingestion.deployment compactionWorker.deployment compaction.deployment clusterManager.deployment \
    metastoreMigration.job migration.job migration.taskdb.postgres.statefulSet; do
    VALUES_ARGS+=(
      --set-json "smithdb.$path.nodeSelector={\"langsmith-nodepool/smithdb\":\"true\"}"
    )
  done
  for path in query mutations runRules statsQuery ingestion compactionWorker compaction clusterManager; do
    VALUES_ARGS+=(--set-json "smithdb.$path.deployment.resources={}")
  done
  case "${_sizing_profile:-default}" in
    production) tier=medium ;;
    production-large) tier=large ;;
  esac
  values=$(_smithdb_cache_values "$tier" "$pool_tolerations" "${VALUES_ARGS[@]}") || return 1
  while IFS= read -r setting; do
    VALUES_ARGS+=(--set-json "$setting")
  done < <(jq -r 'to_entries[] | "\(.key)=\(.value | tojson)"' <<< "$values")
}

# Use Helm's YAML merge to replace only cache overrides, preserving unrelated
# volumes and mounts. This also handles existing values files during transition.
_smithdb_cache_values() (
  set -euo pipefail
  local chart tier="$1" pool_tolerations="$2"
  shift 2
  chart=$(mktemp -d)
  trap 'rm -rf "$chart"' EXIT
  mkdir "$chart/templates"
  printf 'apiVersion: v2\nname: smithdb-cache\nversion: 0.1.0\n' > "$chart/Chart.yaml"
  cat > "$chart/templates/values.yaml" <<'TEMPLATE'
{{- $settings := dict "smithdb.resourceTier" (default .Values.fallbackTier .Values.smithdb.resourceTier) -}}
{{- range $path := list "query.deployment" "mutations.deployment" "runRules.deployment" "statsQuery.deployment" "ingestion.deployment" "compactionWorker.deployment" "compaction.deployment" "clusterManager.deployment" "metastoreMigration.job" "migration.job" "migration.taskdb.postgres.statefulSet" -}}
  {{- $pod := $.Values.smithdb -}}
  {{- range $key := splitList "." $path -}}
    {{- $pod = get (default (dict) $pod) $key -}}
  {{- end -}}
  {{- $tolerations := default (list) $pod.tolerations -}}
  {{- range $required := $.Values._smithdbPoolTolerations -}}
    {{- if not (has $required $tolerations) -}}
      {{- $tolerations = append $tolerations $required -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $settings (printf "smithdb.%s.tolerations" $path) $tolerations -}}
{{- end -}}
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
  helm template smithdb-cache "$chart" "$@" --set-string "fallbackTier=$tier" --set-json "_smithdbPoolTolerations=$pool_tolerations" |
    sed '/^#/d; /^---$/d' | jq -er '.data.values'
)

# An existing Job cannot move pools without replacing its immutable template.
_smithdb_check_migration() {
  local workloads
  workloads=$(kubectl get jobs,deployments -n "$1" -l "app.kubernetes.io/instance=$2" -o json) || return 1
  if ! jq -e --arg enabled "${3:-true}" '[.items[] | select(
      (.metadata.name | contains("smithdb-migration")) and
      (.kind == "Deployment" or .spec.template.spec.nodeSelector["langsmith-nodepool/smithdb"] != "true") and
      (.kind == "Deployment" or $enabled != "false" or
        (any(.status.conditions[]?; .type == "Complete" and .status == "True") | not))
    )] | length == 0' <<< "$workloads" >/dev/null; then
    echo "ERROR: finish the existing SmithDB migration before changing node groups." >&2
    echo "Keep TaskDB, its PVC, and credentials until migration completes." >&2
    echo "For a completed Job, run make smithdb-migration-job-end before changing pools." >&2
    return 1
  fi
}
