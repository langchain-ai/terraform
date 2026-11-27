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
# With the local-ssd cache, ephemeral storage is on the instance store, so the boot
# disk size does not count.
_smithdb_migration_disk_check() {
  local gb="$1" cache_storage="${2:-network-disk}"
  [[ "$cache_storage" != "local-ssd" ]] || return 0
  [[ "$gb" =~ ^[0-9]+$ ]] || return 0
  (( gb >= 150 )) && return 0
  echo "ERROR: each migration pod requests 100Gi of ephemeral storage, and the SmithDB nodes have a ${gb} GiB boot disk, so the pods would stay Pending." >&2
  echo "       Set smithdb_node_root_volume_size_gb to at least 150 in terraform.tfvars, run make apply, then run this again." >&2
  return 1
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

# make init-values keeps an existing sizing file, so one copied earlier can still set
# smithdb.resourceTier. langsmith-values-smithdb.yaml loads after it, so a different
# tier there would replace the sizing file's tier without notice. Returns 1, with the
# fix, when the sizing file sets a tier other than the deployed one.
_smithdb_sizing_tier_check() {
  local file="$1" deployed="$2" tier
  [[ -n "$file" && -f "$file" ]] || return 0
  tier=$(awk '
    /^[^ #]/ { s = ($1 == "smithdb:") }
    s && /^  resourceTier:/ { v = $2; gsub(/["\047]/, "", v); print v; exit }
  ' "$file")
  [[ -z "$tier" || "$tier" == "$deployed" ]] && return 0
  echo "ERROR: ${file##*/} sets smithdb.resourceTier: $tier, but langsmith-values-smithdb.yaml loads after it, so the release would run the $deployed tier." >&2
  echo "       Set the tier in langsmith-values-smithdb.yaml and remove it from ${file##*/}. See SMITHDB.md, \"Scaling up\"." >&2
  return 1
}

# Use Helm's YAML merge to replace only cache overrides, preserving unrelated volumes and mounts.
# The network-disk cache drops every cache volume, so the chart generates its gp3 claim.
# The local-ssd cache (--set-string cacheStorage=local-ssd) replaces it with an emptyDir named cache and sets the tier's CPU and memory with a matching ephemeral-storage, which the chart needs for an emptyDir cache.
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
