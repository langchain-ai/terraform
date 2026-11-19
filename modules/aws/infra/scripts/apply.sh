#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/..}"
source "$SCRIPT_DIR/_smithdb-transition.sh"

# Inspect the exact plan being applied, including saved plans and -var overrides.
# tfvars text alone cannot tell whether this apply removes the old controller.
umask 077
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT
_plan="$_tmp/plan"
_auto=false
_input=true
_plan_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -auto-approve|-auto-approve=true) _auto=true ;;
    -auto-approve=false) _auto=false ;;
    -input=false) _input=false; _plan_args+=("$1") ;;
    -destroy) echo "Use make destroy for teardown; make apply protects the SmithDB transition." >&2; exit 1 ;;
    -json) echo "Use make apply without -json so the transition can be reviewed." >&2; exit 1 ;;
    -var|-var-file|-target|-replace|-parallelism|-lock-timeout|-input)
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
  terraform -chdir="$INFRA_DIR" plan ${_plan_args[@]+"${_plan_args[@]}"} -out="$_plan"
fi
terraform -chdir="$INFRA_DIR" show -json "$_plan" > "$_tmp/plan.json"
_cleanup=$(jq -r '[.resource_changes[]? | select(.change.actions | index("delete")) |
  select((.address | startswith("kubectl_manifest.smithdb_")) or
    (.address | contains("karpenter")))] | length > 0' "$_tmp/plan.json")
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
  if ! jq -e '.variables.enable_smithdb.value == true and .variables.smithdb_transition_mode.value == false' "$_tmp/plan.json" >/dev/null; then
    echo "ERROR: Karpenter cleanup requires enable_smithdb = true and smithdb_transition_mode = false." >&2
    exit 1
  fi
  _cluster=$(jq -er '.planned_values.outputs.cluster_name.value' "$_tmp/plan.json")
  _region=$(jq -er '.variables.region.value' "$_tmp/plan.json")
  _namespace=$(jq -er '.variables.langsmith_namespace.value' "$_tmp/plan.json")
  _release=$(jq -er '.variables.langsmith_release_name.value' "$_tmp/plan.json")
  _cache=$(jq -er '.planned_values.outputs.smithdb_cache_storage_class_name.value' "$_tmp/plan.json")
  export KUBECONFIG="$_tmp/kubeconfig"
  aws eks update-kubeconfig --region "$_region" --name "$_cluster" --kubeconfig "$KUBECONFIG" >/dev/null
  _smithdb_cleanup "$_namespace" "$_release" "$_region" "$_cache" "$_cluster"
fi
terraform -chdir="$INFRA_DIR" apply "$_plan"
