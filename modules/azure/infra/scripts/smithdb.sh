#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# smithdb.sh — SmithDB size, rollout phase, and status.
#
# Usage (from azure/):
#   make smithdb-configure SIZING=<minimal|small|medium|large>
#   make smithdb-phase PHASE=<off|dual-write|backfill|cutover> [FORCE=true]
#   make smithdb-status
#
# configure and phase change only infra/terraform.tfvars (or the one under
# LANGSMITH_INFRA_DIR). Terraform checks the result at the next plan. The
# cutover check and status are read-only: kubectl get, and one SELECT in the
# taskdb pod.
#
# The release name and namespace come from langsmith_release_name and
# langsmith_namespace in terraform.tfvars, the same as deploy.sh.

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

_die() {
  fail "$1" >&2
  shift
  local line
  for line in "$@"; do printf "     %s\n" "$line" >&2; done
  exit 1
}

[[ -f "$TFVARS" ]] || _die "terraform.tfvars not found at $TFVARS." "Run: make quickstart"

# A tfvars value, with a missing key or a bare null read as unset.
_tfvar() { local v; v="$(_parse_tfvar "$1")" || v=""; [[ "$v" == "null" ]] && v=""; printf '%s' "$v"; }
_tfbool() { if _tfvar_is_true "$1"; then printf 'true'; else printf 'false'; fi; }
_tfout() { terraform -chdir="$INFRA_DIR" output -raw "$1" 2>/dev/null || true; }

RELEASE_NAME="${RELEASE_NAME:-$(_tfvar langsmith_release_name)}"
RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-$(_tfvar langsmith_namespace)}"
NAMESPACE="${NAMESPACE:-langsmith}"

# Chart 0.17 names: the taskdb StatefulSet pod, its container, its database,
# and its user (smithdb.migration.taskdb.postgres defaults in values.yaml). The
# chart fullname adds -langsmith to a release name that lacks it.
if [[ "$RELEASE_NAME" == *langsmith* ]]; then _fullname="$RELEASE_NAME"; else _fullname="${RELEASE_NAME}-langsmith"; fi
TASKDB_POD="${_fullname}-smithdb-taskdb-postgres-0"
TASKDB_ARGS=(-c taskdb-postgres -- psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -U postgres -d smithdb_migration)

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

# make apply refuses to run against a root outside this repo, so point a
# wrapper-root user at terraform there instead.
_next_step() {
  if [[ -n "${LANGSMITH_INFRA_DIR:-}" ]]; then
    action "Run terraform apply in $LANGSMITH_INFRA_DIR, then: make init-values deploy"
  else
    action "Run: make deploy-all"
  fi
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
  local sizing="${SIZING:-}" sku
  case "$sizing" in
    minimal|small|medium|large) ;;
    *) _die "SIZING='$sizing' is not valid. Use minimal, small, medium, or large." \
         "Example: make smithdb-configure SIZING=small" ;;
  esac

  header "SmithDB size (terraform.tfvars)"
  _set_tfvar smithdb_sizing "\"$sizing\""

  echo ""
  info "A size change replaces the SmithDB pods, and each cache volume is sized from the new tier."
  info "For the metastore, a size change also changes the Flexible Server SKU, which restarts the server."
  sku="$(_tfvar smithdb_metastore_sku_name)"
  [[ -z "$sku" ]] || warn "terraform.tfvars pins smithdb_metastore_sku_name = $sku. It wins over the default for $sizing."
  case "$sizing" in
    medium|large) info "The $sizing query pod requests 28 vCPU. Size the smithdb node pool for it: see SMITHDB.md, \"Sizing\"." ;;
  esac
  _tfvar_is_true enable_smithdb || warn "enable_smithdb is not true, so this value has no effect yet."
  _next_step
}

_cmd_phase() {
  local phase="${PHASE:-}" ingestion migration query current counts total promoted
  case "$phase" in
    off)        ingestion=false; migration=false; query=false ;;
    dual-write) ingestion=true;  migration=false; query=false ;;
    backfill)   ingestion=true;  migration=true;  query=false ;;
    cutover)    ingestion=true;  migration=false; query=true ;;
    *) _die "PHASE='$phase' is not valid. Use off, dual-write, backfill, or cutover." ;;
  esac
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

  header "SmithDB rollout gates (terraform.tfvars)"
  _set_tfvar smithdb_ingestion_enabled "$ingestion"
  _set_tfvar smithdb_migration_enabled "$migration"
  _set_tfvar smithdb_query_enabled "$query"

  echo ""
  info "Phase: $current -> $phase. ClickHouse stays enabled."
  [[ "$ingestion" == "false" && "$current" != "off" ]] \
    && warn "LangSmith stops the dual write. SmithDB does not get the traces written while it is off."
  [[ "$migration" == "true" && "$current" != "backfill" ]] \
    && info "The apply grants the SmithDB identity read access to the trace-blob account and waits 300 seconds for it to take effect."
  [[ "$migration" == "false" && "$current" == "backfill" ]] \
    && warn "The deploy removes the backfill Job and the taskdb, and the chart deletes the taskdb volume."
  _next_step
}

_cmd_status() {
  local counts total migrated validated promoted sizing

  sizing="$(_tfvar smithdb_sizing)"
  header "SmithDB in terraform.tfvars"
  info "enable_smithdb = $(_tfbool enable_smithdb)   phase: $(_phase_name)"
  info "smithdb_sizing = ${sizing:-unset (follows sizing_profile)}"

  header "SmithDB resolved by Terraform (last apply)"
  if [[ -z "$(_tfout smithdb_sizing)" ]]; then
    skip "No smithdb_sizing output: SmithDB is off, or no apply with this module version."
  else
    info "Size: $(_tfout smithdb_sizing)   Metastore SKU: $(_tfout smithdb_metastore_sku_name)"
    info "Cache StorageClass: $(_tfout smithdb_cache_storage_class_name)"
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
