#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/..}"
source "$SCRIPT_DIR/_smithdb-transition.sh"

# Inspect the exact plan being applied, including saved plans and -var overrides.
# tfvars text alone cannot tell whether this apply removes the old pools.
umask 077
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT
_plan="$_tmp/plan"
_auto=false
_input=true
_plan_args=()
_run_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -auto-approve|-auto-approve=true) _auto=true ;;
    -auto-approve=false) _auto=false ;;
    -input=false) _input=false; _run_args+=("$1") ;;
    -destroy) echo "Use make destroy for teardown; make apply protects the SmithDB transition." >&2; exit 1 ;;
    -json) echo "Use make apply without -json so the transition can be reviewed." >&2; exit 1 ;;
    -parallelism|-lock-timeout)
      _run_args+=("$1" "$2"); shift ;;
    -parallelism=*|-lock-timeout=*|-lock=*|-no-color|-compact-warnings)
      _run_args+=("$1") ;;
    -var|-var-file|-target|-replace|-input)
      _plan_args+=("$1" "$2"); shift ;;
    -*) _plan_args+=("$1") ;;
    *)
      [[ $# == 1 && ${#_plan_args[@]} == 0 ]] || { echo "Pass a saved plan alone." >&2; exit 1; }
      _plan="$1"
      [[ "$_plan" == /* ]] || _plan="$INFRA_DIR/$_plan"
      _auto=true ;;
  esac
  shift
done
if [[ "$_plan" == "$_tmp/plan" ]]; then
  terraform -chdir="$INFRA_DIR" plan ${_plan_args[@]+"${_plan_args[@]}"} ${_run_args[@]+"${_run_args[@]}"} -out="$_plan"
fi
terraform -chdir="$INFRA_DIR" show -json "$_plan" > "$_tmp/plan.json"
_cleanup=$(jq -r '[.resource_changes[]? | select(.change.actions | index("delete")) |
  select(.type == "google_container_node_pool" and .change.after == null and (.name == "instance_store" or .name == "compute"))] | length > 0' "$_tmp/plan.json")
if [[ "$_auto" != true ]]; then
  if [[ "$_input" == false || "${TF_INPUT:-true}" == false ]]; then
    echo "ERROR: applying requires approval. Use -auto-approve or an approved saved plan." >&2
    exit 1
  fi
  if [[ "$_cleanup" == true ]]; then
    echo "Old SmithDB pools will be removed after health checks."
  fi
  echo "Apply this plan?"
  read -r -p 'Type yes to continue: ' _answer
  [[ "$_answer" == yes ]] || exit 1
fi
if [[ "$_cleanup" == true ]]; then
  if ! jq -e '.variables.enable_smithdb.value == true and .variables.smithdb_transition_mode.value == false and
    .planned_values.outputs.smithdb_cache_storage.value == "network-disk"' "$_tmp/plan.json" >/dev/null; then
    echo "ERROR: use make destroy for teardown; removing old SmithDB pools requires the network-disk pool." >&2
    exit 1
  fi
  _cluster=$(jq -er '.planned_values.outputs.cluster_name.value' "$_tmp/plan.json")
  _region=$(jq -er '.variables.region.value' "$_tmp/plan.json")
  _project=$(jq -er '.variables.project_id.value' "$_tmp/plan.json")
  _namespace=$(jq -er '.variables.langsmith_namespace.value' "$_tmp/plan.json")
  _release=$(jq -er '.variables.langsmith_release_name.value' "$_tmp/plan.json")
  _cache=$(jq -er '.planned_values.outputs.smithdb_cache_storage_class_name.value' "$_tmp/plan.json")
  export KUBECONFIG="$_tmp/kubeconfig"
  gcloud container clusters get-credentials "$_cluster" --region="$_region" --project="$_project" >/dev/null
  _smithdb_transition_ready "$_namespace" "$_release" "$_cache"
fi
terraform -chdir="$INFRA_DIR" apply ${_run_args[@]+"${_run_args[@]}"} "$_plan"
