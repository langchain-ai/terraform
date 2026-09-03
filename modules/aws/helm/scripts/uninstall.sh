#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Uninstalls LangSmith from the correct EKS cluster.
#
# Resolves cluster name and region from terraform.tfvars + terraform output,
# updates kubeconfig to target the right cluster, then removes the Helm release
# and ESO resources.
#
# Phase 10 / sandboxes: JuiceFS CSI lives in the same Helm release as
# sandbox-host. Deleting the release first leaves mount pods holding
# juicefs.com/finalizer with no controller left to clear it, so kubectl
# delete hangs forever. Tear down JuiceFS volumes while CSI is still up,
# then force-clear any leftover finalizers after helm uninstall.
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
SANDBOX_RELEASE_NAME="${SANDBOX_RELEASE_NAME:-langsmith-sandbox}"
DELETE_TIMEOUT="${DELETE_TIMEOUT:-120s}"
# In-cluster ClickHouse holds trace data, so its claim is kept by default:
# uninstall is also the path to a clean Helm reinstall on the same cluster.
# Set to true when the cluster is going away, so the EBS CSI driver reclaims
# the volume before terraform destroy removes the driver.
DELETE_DATA_PVCS="${DELETE_DATA_PVCS:-false}"

# Names of resources of type $1 whose name matches extended regex $2.
# Resource names rather than labels: the sandbox-host workload is named
# "sandbox-host" on some chart versions and "<release>-sandbox-host" on
# others, and JuiceFS mount pods carry no chart labels at all.
_names_matching() {
  local _type="$1" _pattern="$2"
  kubectl get "$_type" -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -Ei -- "$_pattern" || true
}

# Force-delete pods stuck in Terminating and strip the JuiceFS finalizer that
# only the (now-removed) CSI controller would clear. Without this, kubectl
# delete blocks past terminationGracePeriodSeconds with no way to finish.
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
      # Pods the API server has accepted a delete for but that never finish.
      kubectl get pods -n "$NAMESPACE" \
        -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true
      # JuiceFS mount pods, which hold juicefs.com/finalizer.
      _names_matching pods 'juicefs'
    } | sort -u
  )
}

# ── Resolve config from terraform.tfvars (best effort) ────────────────────────
# TEARDOWN.md Option B covers teardown with no Terraform state. Hard-requiring
# terraform.tfvars and `terraform output` made this script unusable there, which
# is why Option B fell back to a bare `helm uninstall` — the very ordering that
# strands JuiceFS mount pods on juicefs.com/finalizer. Both inputs are now
# optional: when they resolve, the script retargets kubeconfig itself; when they
# do not, it uses the active kubectl context and names it in the confirmation.
_environment=""; _name_prefix=""; _region="${AWS_REGION:-}"; _sandbox_deployment_mode="same_cluster"
if [[ -f "$INFRA_DIR/terraform.tfvars" ]]; then
  _environment=$(_parse_tfvar "environment") || _environment="${LANGSMITH_ENV:-}"
  _name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
  _region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"
  _sandbox_deployment_mode=$(_parse_tfvar "sandbox_deployment_mode") || _sandbox_deployment_mode="same_cluster"
  echo "Resolved from terraform.tfvars:"
  echo "  name_prefix  = ${_name_prefix:-(empty)}"
  echo "  environment  = ${_environment:-(empty)}"
  echo "  region       = ${_region:-(empty)}"
else
  echo "NOTE: no terraform.tfvars at $INFRA_DIR."
  echo "      Falling back to the active kubectl context (TEARDOWN.md Option B)."
fi
echo ""

# ── Point kubeconfig at the right cluster, if Terraform can tell us ───────────
_cluster_name=""
_sandbox_cluster_name=""
_sandbox_namespace="langsmith-sandbox"
if [[ -n "$_region" ]]; then
  _cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
  if [[ "$_sandbox_deployment_mode" == "separate_cluster" ]]; then
    _sandbox_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_cluster_name 2>/dev/null) || _sandbox_cluster_name=""
    _sandbox_namespace=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_namespace 2>/dev/null) || _sandbox_namespace="langsmith-sandbox"
  fi
fi

if [[ -n "$_cluster_name" ]]; then
  echo "Updating kubeconfig for cluster: $_cluster_name..."
  aws eks update-kubeconfig --name "$_cluster_name" --region "$_region"
else
  echo "NOTE: cluster name unavailable from Terraform output — kubeconfig left as is."
fi

_ctx=$(kubectl config current-context 2>/dev/null) || _ctx=""
if [[ -z "$_ctx" ]]; then
  echo "ERROR: no active kubectl context, and no cluster resolvable from Terraform." >&2
  echo "       Point kubectl at the target cluster first:" >&2
  echo "         aws eks update-kubeconfig --name <cluster> --region <region>" >&2
  exit 1
fi
echo "  Active context: $_ctx"
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
echo "This will remove, from cluster context '$_ctx':"
echo "  - Helm release '$RELEASE_NAME' from namespace '$NAMESPACE'"
echo "  - ExternalSecret 'langsmith-config' from namespace '$NAMESPACE'"
echo "  - ClusterSecretStore 'langsmith-ssm'"
echo "  - JuiceFS / sandbox volumes (while CSI is still present)"
if [[ -n "$_sandbox_cluster_name" ]]; then
  echo "  - Helm release '$SANDBOX_RELEASE_NAME' from sandbox cluster '$_sandbox_cluster_name' namespace '$_sandbox_namespace'"
fi
if [[ "$DELETE_DATA_PVCS" == "true" ]]; then
  echo "  - ClickHouse data PVCs — TRACE DATA IS DELETED (DELETE_DATA_PVCS=true)"
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

if [[ -n "$_sandbox_cluster_name" ]]; then
  echo "Uninstalling standalone sandbox runtime from '$_sandbox_cluster_name'..."
  trap 'aws eks update-kubeconfig --name "$_cluster_name" --region "$_region" >/dev/null 2>&1 || true' EXIT
  aws eks update-kubeconfig --name "$_sandbox_cluster_name" --region "$_region"
  if helm list -n "$_sandbox_namespace" --filter "^${SANDBOX_RELEASE_NAME}$" --output json 2>/dev/null | grep -q '"name"'; then
    helm uninstall "$SANDBOX_RELEASE_NAME" -n "$_sandbox_namespace" --wait --timeout 10m
  else
    echo "Helm release '$SANDBOX_RELEASE_NAME' not found in namespace '$_sandbox_namespace' — skipping."
  fi
  aws eks update-kubeconfig --name "$_cluster_name" --region "$_region"
  trap - EXIT
  echo ""
fi

# ── Pre-Helm: tear down JuiceFS while CSI can still unmount ───────────────────
# helm uninstall removes the JuiceFS CSI driver along with the release. A PVC
# that mounts through that driver can then never be unmounted, because the
# controller that clears juicefs.com/finalizer is gone. Drop the consumer and
# the volume first, while the driver is still running.
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

# ── Remove ESO resources ──────────────────────────────────────────────────────
echo "Removing ESO resources..."
kubectl delete externalsecret langsmith-config -n "$NAMESPACE" --ignore-not-found
kubectl delete clustersecretstore langsmith-ssm --ignore-not-found
echo ""

# ── Clean up operator-managed resources ──────────────────────────────────────
# platform-backend creates agent-builder and LangGraph resources at runtime with
# no Helm owner reference. Target only LangSmith resources by label so workloads
# from other teams sharing this namespace are not affected.
# Bounded by --timeout so a pod that cannot terminate does not block the run
# indefinitely; anything left over is force-cleared below.
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

# ── Reclaim dynamically provisioned EBS before terraform destroy ──────────────
# data-langsmith-clickhouse-* is provisioned by the EBS CSI driver, so Terraform
# has no record of the volume. Destroying the cluster first leaves it billing
# with nothing attached, because the driver that would reclaim it goes with the
# cluster. Deleting the claim here is the only point where reclaim still works.
_data_pvcs=$(_names_matching pvc 'clickhouse')
if [[ -n "$_data_pvcs" ]]; then
  if [[ "$DELETE_DATA_PVCS" == "true" ]]; then
    echo "Deleting ClickHouse data PVCs (reclaims EBS while the CSI driver is alive)..."
    while IFS= read -r _pvc; do
      [[ -z "$_pvc" ]] && continue
      echo "  deleting PVC $_pvc"
      kubectl delete pvc "$_pvc" -n "$NAMESPACE" \
        --ignore-not-found --timeout="$DELETE_TIMEOUT" || true
    done <<< "$_data_pvcs"
  else
    echo "Keeping ClickHouse data PVCs (DELETE_DATA_PVCS is not true):"
    echo "$_data_pvcs" | sed 's|^|  |'
    echo "  These are dynamically provisioned EBS volumes that Terraform does not"
    echo "  track. Before 'terraform destroy', delete them so the volumes are"
    echo "  reclaimed instead of orphaned:"
    echo "    DELETE_DATA_PVCS=true $0"
  fi
  echo ""
fi

echo "Uninstall complete."
