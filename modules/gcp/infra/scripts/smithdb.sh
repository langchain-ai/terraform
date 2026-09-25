#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# smithdb.sh — SmithDB size, rollout phase, and status.
#
# Usage (from gcp/):
#   make smithdb-configure SIZING=<minimal|small|medium|large> [CACHE=<local-ssd|network-disk>]
#   make smithdb-phase PHASE=<off|dual-write|backfill|cutover> [START_TIME=<RFC 3339>] [FORCE=true]
#   make smithdb-status
#
# configure and phase change only infra/terraform.tfvars. Terraform checks the
# result at the next plan. Run `make deploy-all` to apply it. The cutover check
# and status are read-only: kubectl get, and one SELECT in the taskdb pod.
#
# RELEASE_NAME and NAMESPACE (default langsmith for both) must match deploy.sh.

# Sourced directly, the `set -euo pipefail` below would leak into the caller's
# shell. So when sourced, hand off to a child process and return its status.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

TFVARS="$INFRA_DIR/terraform.tfvars"
RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"

# Chart 0.17 names: the taskdb StatefulSet pod, its container, its database,
# and its user (smithdb.migration.taskdb.postgres defaults in values.yaml).
TASKDB_POD="${RELEASE_NAME}-smithdb-taskdb-postgres-0"
TASKDB_ARGS=(-c taskdb-postgres -- psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -U postgres -d smithdb_migration)

_die() {
  fail "$1" >&2
  shift
  local line
  for line in "$@"; do printf "     %s\n" "$line" >&2; done
  exit 1
}

[[ -f "$TFVARS" ]] || _die "terraform.tfvars not found at $TFVARS." "Run: make quickstart"

# A tfvars value, with a bare null read as unset.
_tfvar() { local v; v="$(_parse_tfvar "$1")"; [[ "$v" == "null" ]] && v=""; printf '%s' "$v"; }
_tfbool() { if _tfvar_is_true "$1"; then printf 'true'; else printf 'false'; fi; }
_tfout() { terraform -chdir="$INFRA_DIR" output -raw "$1" 2>/dev/null || true; }

# Replace the first uncommented `key = ...` line in terraform.tfvars, or append
# one. `cat >`, not mv, keeps the file permissions.
_set_tfvar() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if awk -v key="$key" -v value="$value" '
    !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print key " = " value; done = 1; next }
    { print }
    END { exit done ? 0 : 3 }
  ' "$TFVARS" > "$tmp"; then
    cat "$tmp" > "$TFVARS"
  else
    [[ -s "$TFVARS" && -n "$(tail -c 1 "$TFVARS")" ]] && printf '\n' >> "$TFVARS"
    printf '%s = %s\n' "$key" "$value" >> "$TFVARS"
  fi
  rm -f "$tmp"
  pass "$(printf '%-28s = %s' "$key" "$value")"
}

_phase_name() {
  case "$(_tfbool smithdb_ingestion_enabled)/$(_tfbool smithdb_migration_enabled)/$(_tfbool smithdb_query_enabled)" in
    false/false/false) printf 'off' ;;
    true/false/false)  printf 'dual-write' ;;
    true/true/false)   printf 'backfill' ;;
    true/false/true)   printf 'cutover' ;;
    *)                 printf 'custom' ;;
  esac
}

# Prints "total migrated validated promoted" for the taskdb migration_jobs
# table, or returns 1 when the query cannot run. The session is read-only.
_taskdb_counts() {
  local out
  command -v kubectl >/dev/null 2>&1 || return 1
  [[ "$(kubectl get pod "$TASKDB_POD" -n "$NAMESPACE" --request-timeout=10s \
    -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]] || return 1
  out="$(kubectl exec -n "$NAMESPACE" "$TASKDB_POD" --request-timeout=30s "${TASKDB_ARGS[@]}" \
    -c 'SET default_transaction_read_only = on' \
    -c 'SELECT count(*), count(migrated_at), count(validated_at), count(promoted_at) FROM migration_jobs' \
    2>/dev/null)" || return 1
  [[ "$out" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] || return 1
  printf '%s' "$out"
}

_cmd_configure() {
  local sizing="${SIZING:-}" cache="${CACHE:-}" v
  case "$sizing" in
    minimal|small|medium|large) ;;
    *) _die "SIZING='$sizing' is not valid. Use minimal, small, medium, or large." \
         "Example: make smithdb-configure SIZING=small CACHE=local-ssd" ;;
  esac
  case "$cache" in
    ""|local-ssd|network-disk) ;;
    *) _die "CACHE='$cache' is not valid. Use local-ssd or network-disk." ;;
  esac

  if [[ "$sizing" == "minimal" && "$cache" == "local-ssd" ]]; then
    _die "SIZING=minimal requires network-disk. minimal has no SmithDB node pools, so no Local SSD." \
      "Run: make smithdb-configure SIZING=minimal"
  fi

  # With no CACHE, the tfvars value stays. minimal writes null instead: null
  # gives network-disk for minimal, and a later size change gets local-ssd.
  header "SmithDB size and cache storage (infra/terraform.tfvars)"
  _set_tfvar smithdb_sizing "\"$sizing\""
  if [[ -n "$cache" ]]; then
    _set_tfvar smithdb_cache_storage "\"$cache\""
  elif [[ "$sizing" == "minimal" ]]; then
    _set_tfvar smithdb_cache_storage null
  fi

  echo ""
  info "A change of size or cache storage can replace the SmithDB node pools, and each cache starts empty."
  info "For a created metastore, a size change also changes the Cloud SQL tier. The instance is offline for less than 60 seconds."
  for v in smithdb_instance_store_machine_type smithdb_instance_store_local_ssd_count \
           smithdb_instance_store_disk_size smithdb_compute_machine_type smithdb_metastore_tier; do
    if [[ -n "$(_tfvar "$v")" ]]; then
      warn "terraform.tfvars pins $v = $(_tfvar "$v"). It wins over the default for $sizing."
    fi
  done
  _tfvar_is_true enable_smithdb || warn "enable_smithdb is not true, so these values have no effect yet."
  action "Run: make deploy-all"
}

_cmd_phase() {
  local phase="${PHASE:-}" start_time="${START_TIME:-}" ingestion migration query current counts total promoted
  case "$phase" in
    off)        ingestion=false; migration=false; query=false ;;
    dual-write) ingestion=true;  migration=false; query=false ;;
    backfill)   ingestion=true;  migration=true;  query=false ;;
    cutover)    ingestion=true;  migration=false; query=true ;;
    *) _die "PHASE='$phase' is not valid. Use off, dual-write, backfill, or cutover." ;;
  esac
  if [[ -n "$start_time" ]]; then
    [[ "$phase" == "backfill" ]] || _die "START_TIME applies only to PHASE=backfill."
    [[ "$start_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] \
      || _die "START_TIME='$start_time' is not an RFC 3339 timestamp." "Example: START_TIME=2026-01-01T00:00:00Z"
  fi
  [[ "$phase" == "off" ]] || _tfvar_is_true enable_smithdb \
    || _die "PHASE=$phase requires enable_smithdb = true in terraform.tfvars."
  current="$(_phase_name)"

  # Cutover removes the backfill Job and the taskdb, and the chart deletes the
  # taskdb volume. Refuse it until every backfill row is promoted.
  if [[ "$phase" == "cutover" && "$current" != "cutover" && "${FORCE:-false}" != "true" ]]; then
    header "Backfill check (read-only)"
    counts="$(_taskdb_counts)" || _die "Could not read migration_jobs from $TASKDB_POD in namespace $NAMESPACE." \
      "The taskdb runs only in the backfill phase. See: make smithdb-status" \
      "With no backfill to wait for: make smithdb-phase PHASE=cutover FORCE=true"
    read -r total _ _ promoted <<< "$counts"
    if (( total == 0 || promoted < total )); then
      _die "migration_jobs: $promoted of $total rows have promoted_at. Cutover stopped." \
        "The backfill Job adds the rows when it starts. Watch it with: make smithdb-status" \
        "To continue without the check: make smithdb-phase PHASE=cutover FORCE=true"
    fi
    pass "migration_jobs: all $total rows have promoted_at."
  fi

  header "SmithDB rollout gates (infra/terraform.tfvars)"
  _set_tfvar smithdb_ingestion_enabled "$ingestion"
  _set_tfvar smithdb_migration_enabled "$migration"
  _set_tfvar smithdb_query_enabled "$query"
  [[ -n "$start_time" ]] && _set_tfvar smithdb_migration_start_time "\"$start_time\""

  echo ""
  info "Phase: $current -> $phase. ClickHouse stays enabled."
  [[ "$ingestion" == "false" && "$current" != "off" ]] \
    && warn "LangSmith stops the dual write. SmithDB does not get the traces written while it is off."
  [[ "$migration" == "false" && "$current" == "backfill" ]] \
    && warn "The deploy removes the backfill Job and the taskdb, and the chart deletes the taskdb volume."
  action "Run: make deploy-all"
}

_cmd_status() {
  local counts total migrated validated promoted pools sizing cache start

  sizing="$(_tfvar smithdb_sizing)"; cache="$(_tfvar smithdb_cache_storage)"; start="$(_tfvar smithdb_migration_start_time)"
  header "SmithDB in infra/terraform.tfvars"
  info "enable_smithdb = $(_tfbool enable_smithdb)   phase: $(_phase_name)"
  info "smithdb_sizing = ${sizing:-unset (follows sizing_profile)}   smithdb_cache_storage = ${cache:-unset (default for the size)}"
  info "smithdb_migration_start_time = ${start:-unset (chart default window)}"

  header "SmithDB resolved by Terraform (last apply)"
  if [[ -z "$(_tfout smithdb_sizing)" ]]; then
    skip "No smithdb_sizing output: SmithDB is off, or no apply with this module version."
  else
    pools="$(terraform -chdir="$INFRA_DIR" output -json smithdb_node_pool_config 2>/dev/null | tr -d '\n ' || true)"
    info "Size: $(_tfout smithdb_sizing)   Cache storage: $(_tfout smithdb_cache_storage)   Auth Proxy: $(_tfout smithdb_metastore_use_auth_proxy)"
    info "Node pools: ${pools:-null}"
  fi

  header "SmithDB in Kubernetes (namespace $NAMESPACE)"
  if ! command -v kubectl >/dev/null 2>&1 || ! kubectl get namespace "$NAMESPACE" --request-timeout=10s >/dev/null 2>&1; then
    skip "kubectl is missing, the cluster is unreachable, or namespace $NAMESPACE does not exist."
    return 0
  fi
  info "kubectl context: $(kubectl config current-context 2>/dev/null || echo '?')"
  kubectl get pods,jobs,pvc -n "$NAMESPACE" -o wide --request-timeout=10s 2>/dev/null \
    | awk 'NF == 0 || /^NAME/ || /smithdb/' || true

  header "SmithDB backfill progress (taskdb migration_jobs)"
  if counts="$(_taskdb_counts)"; then
    read -r total migrated validated promoted <<< "$counts"
    info "Rows: $total   migrated_at: $migrated   validated_at: $validated   promoted_at: $promoted"
    if (( total > 0 && promoted == total )); then
      pass "Every row has promoted_at. Next phase: make smithdb-phase PHASE=cutover"
    else
      info "Not complete. A long pause near the end is normal. The Job adds the rows when it starts."
    fi
  else
    skip "No taskdb to read. The taskdb runs only in the backfill phase."
  fi
}

case "${1:-}" in
  configure) _cmd_configure ;;
  phase)     _cmd_phase ;;
  status)    _cmd_status ;;
  *)
    echo "Usage: $0 configure|phase|status   (see the header of this file, or: make help)" >&2
    exit 2 ;;
esac
