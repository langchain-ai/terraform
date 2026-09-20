#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Uninstalls LangSmith from the correct GKE cluster.
#
# Resolves cluster name and region from terraform.tfvars + terraform output,
# updates kubeconfig to target the right cluster, then removes the Helm release
# and operator-managed resources.
#
# Sandboxes use a JuiceFS CSI driver in the same Helm release as sandbox-host.
# Deleting the release first leaves mount pods holding juicefs.com/finalizer
# with no controller left to clear it. Tear down JuiceFS volumes while CSI is
# still available, then force-clear any leftover finalizers.
# Sourced directly, the `set -euo pipefail` below would leak into the caller's
# shell and leave it armed to exit on the next non-zero command, and any `exit`
# here would close that shell outright. So when sourced, hand off to a child
# process and return its status - `source` then behaves exactly like running it.
# Keep this above `set`.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
DELETE_TIMEOUT="${DELETE_TIMEOUT:-120s}"
# In-cluster ClickHouse holds trace data, so its claim is kept by default.
# Set this to true when the cluster is going away. The GCE PD CSI driver can
# then reclaim the disk before Terraform removes the GKE cluster.
DELETE_DATA_PVCS="${DELETE_DATA_PVCS:-false}"

# Names of resources of type $1 whose name matches extended regex $2.
# Resource names are used because sandbox-host names vary between chart
# versions, and JuiceFS mount pods do not carry chart labels.
_names_matching() {
  local _type="$1" _pattern="$2"
  kubectl get "$_type" -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -Ei -- "$_pattern" || true
}

# Force-delete pods stuck in Terminating. Clear the finalizer that only the
# removed JuiceFS CSI controller could otherwise clear.
_force_clear_stuck_pods() {
  local _pod
  while IFS= read -r _pod; do
    [[ -z "$_pod" ]] && continue
    echo "  force-deleting pod $_pod"
    kubectl patch pod "$_pod" -n "$NAMESPACE" \
      --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null || true
    kubectl delete pod "$_pod" -n "$NAMESPACE" \
      --grace-period=0 --force --wait=false --ignore-not-found || true
  done < <(
    {
      kubectl get pods -n "$NAMESPACE" \
        -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true
      _names_matching pods 'juicefs'
    } | sort -u
  )
}

# ── tfvars parser ─────────────────────────────────────────────────────────────
# Values are cut at the closing quote, or at an inline # for bare booleans and
# numbers. Keep identical to the other copies of this function.
_parse_tfvar() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      if (substr($0, 1, 1) == "\"") { sub(/^"/, ""); sub(/".*$/, "") }
      else { sub(/#.*$/, ""); gsub(/[[:space:]]+$/, "") }
      print; exit
    }
  ' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true
}

# ── Resolve config from terraform.tfvars (best effort) ────────────────────────
# TEARDOWN.md Option B documents teardown with no Terraform state and instructs
# running this script, so hard-requiring terraform.tfvars and `terraform output`
# made it unusable in exactly the situation it is documented for. Both are now
# optional: when they resolve, the script retargets kubeconfig itself; when they
# do not, it falls back to the active kubectl context and names the cluster it is
# about to act on so the operator can confirm.
_project_id=""; _name_prefix=""; _environment=""; _region=""
if [[ -f "$INFRA_DIR/terraform.tfvars" ]]; then
  _project_id=$(_parse_tfvar "project_id")
  _name_prefix=$(_parse_tfvar "name_prefix")
  _environment=$(_parse_tfvar "environment")
  _region=$(_parse_tfvar "region")
  _region="${_region:-us-west2}"
  echo "Resolved from terraform.tfvars:"
  echo "  name_prefix  = ${_name_prefix:-(empty)}"
  echo "  environment  = ${_environment:-(empty)}"
  echo "  project_id   = ${_project_id:-(empty)}"
  echo "  region       = $_region"
else
  echo "NOTE: no terraform.tfvars at $INFRA_DIR."
  echo "      Falling back to the active kubectl context (TEARDOWN.md Option B)."
fi
echo ""

# ── Point kubeconfig at the right cluster, if Terraform can tell us ───────────
_cluster_name=""
if [[ -n "$_project_id" && -n "$_region" ]]; then
  _cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
fi

if [[ -n "$_cluster_name" ]]; then
  echo "Updating kubeconfig for cluster: $_cluster_name..."
  "$SCRIPT_DIR/get-kubeconfig.sh" "$_cluster_name" "$_region" "$_project_id"
else
  echo "NOTE: cluster name unavailable from Terraform output — kubeconfig left as is."
fi

_ctx=$(kubectl config current-context 2>/dev/null) || _ctx=""
if [[ -z "$_ctx" ]]; then
  echo "ERROR: no active kubectl context, and no cluster resolvable from Terraform." >&2
  echo "       Point kubectl at the target cluster first:" >&2
  echo "         gcloud container clusters get-credentials <cluster> \\" >&2
  echo "           --region <region> --project <project-id>" >&2
  exit 1
fi
echo "  Active context: $_ctx"
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
echo "This will remove, from cluster context '$_ctx':"
echo "  - Helm release '$RELEASE_NAME' from namespace '$NAMESPACE'"
echo "  - Operator-managed LangSmith resources in namespace '$NAMESPACE'"
echo "  - JuiceFS / sandbox volumes (while CSI is still present)"
if [[ "$DELETE_DATA_PVCS" == "true" ]]; then
  echo "  - ClickHouse data PVCs - TRACE DATA IS DELETED (DELETE_DATA_PVCS=true)"
else
  echo "  - Keeps ClickHouse data PVCs (set DELETE_DATA_PVCS=true to delete)"
fi
echo ""
printf "Proceed? [y/N] "
read -r _confirm
if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

# ── Pre-Helm: tear down JuiceFS while CSI can still unmount ───────────────────
# Helm uninstall removes the JuiceFS CSI driver with the release. Delete the
# consumer and volume first so the driver can unmount and clear finalizers.
echo "Removing JuiceFS / sandbox volumes while CSI is still present..."
_workload=""
while IFS= read -r _workload; do
  [[ -z "$_workload" ]] && continue
  echo "  deleting $_workload"
  kubectl delete "$_workload" -n "$NAMESPACE" \
    --ignore-not-found --timeout="$DELETE_TIMEOUT" || true
done < <(
  {
    _names_matching deployments 'sandbox-host' | sed 's|^|deployment/|'
    _names_matching statefulsets 'sandbox-host' | sed 's|^|statefulset/|'
  }
)

_pvc=""
while IFS= read -r _pvc; do
  [[ -z "$_pvc" ]] && continue
  echo "  deleting PVC $_pvc"
  kubectl delete pvc "$_pvc" -n "$NAMESPACE" \
    --ignore-not-found --timeout="$DELETE_TIMEOUT" || true
done < <(_names_matching pvc 'juicefs|smithbox')
echo ""

# ── Uninstall Helm release ────────────────────────────────────────────────────
if helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null | grep -q '"name"'; then
  echo "Uninstalling Helm release '$RELEASE_NAME'..."
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
else
  echo "Helm release '$RELEASE_NAME' not found in namespace '$NAMESPACE' — skipping."
fi
echo ""

# ── Clean up operator-managed resources ──────────────────────────────────────
# platform-backend creates agent-builder and LangGraph resources at runtime with
# no Helm owner reference. Target only LangSmith resources by label so workloads
# from other teams sharing this namespace are not affected.
# Bound deletion so one stuck pod cannot block teardown. Force-clear leftovers
# after the graceful delete attempts.
echo "Removing operator-managed LangSmith resources from namespace '$NAMESPACE'..."
kubectl delete deployments,services,pods,jobs,statefulsets,replicasets \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  -n "$NAMESPACE" --ignore-not-found --timeout="$DELETE_TIMEOUT" || true
# Operator-spawned agent deployment pods use a different label pattern
kubectl delete deployments,pods \
  -l "langsmith.dev/managed-by=operator" \
  -n "$NAMESPACE" --ignore-not-found --timeout="$DELETE_TIMEOUT" 2>/dev/null || true
echo ""

echo "Clearing pods stuck in Terminating (JuiceFS finalizers)..."
_force_clear_stuck_pods
echo ""

# ── Reclaim dynamically provisioned GCE PD before Terraform destroy ──────────
# data-langsmith-clickhouse-* uses the premium-rwo storage class and GCE PD CSI.
# Terraform does not track the disk. Delete the claim while CSI is available so
# its reclaim policy can remove the disk before the GKE cluster is destroyed.
_data_pvcs=$(_names_matching pvc 'clickhouse')
if [[ -n "$_data_pvcs" ]]; then
  if [[ "$DELETE_DATA_PVCS" == "true" ]]; then
    echo "Deleting ClickHouse data PVCs (reclaims GCE PD while CSI is available)..."
    while IFS= read -r _pvc; do
      [[ -z "$_pvc" ]] && continue
      echo "  deleting PVC $_pvc"
      kubectl delete pvc "$_pvc" -n "$NAMESPACE" \
        --ignore-not-found --timeout="$DELETE_TIMEOUT" || true
    done <<< "$_data_pvcs"
  else
    echo "Keeping ClickHouse data PVCs (DELETE_DATA_PVCS is not true):"
    echo "$_data_pvcs" | sed 's|^|  |'
    echo "  These are dynamically provisioned GCE Persistent Disks that Terraform"
    echo "  does not track. Before 'terraform destroy', delete them so the disks"
    echo "  are reclaimed instead of orphaned:"
    echo "    DELETE_DATA_PVCS=true $0"
  fi
  echo ""
fi

echo "Uninstall complete."
echo ""
echo "Note: GKE cluster, Cloud SQL, Memorystore, and GCS bucket are managed by Terraform."
echo "To remove infrastructure: terraform -chdir=$INFRA_DIR destroy"
