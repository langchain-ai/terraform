#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# upgrade-guard.sh — Refuses a terraform apply that would break an install
# upgraded from 0.17. make apply and quickdeploy run it first.
#
# It refuses an apply that would remove the 0.17 SmithDB Karpenter pools while
# Karpenter still owns nodes: with smithdb_keep_karpenter_pools unset, one apply
# deletes the NodePools and the controller together, and EC2 instances the
# controller still owned keep running with nothing to remove them.
#
# A new install (no state) passes. A failed read of the state or the cluster
# refuses, because it cannot show the apply is safe.
#
# Usage: infra/scripts/upgrade-guard.sh
# Exit 0 safe to apply, 1 refused.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

_refuse() {
  echo "ERROR: $1" >&2
  echo "       See SMITHDB.md, \"Upgrading from 0.17\"." >&2
  exit 1
}

if ! _state=$(terraform -chdir="$INFRA_DIR" state list 2>&1); then
  grep -q "No state file was found" <<< "$_state" && exit 0
  _refuse "could not read the Terraform state, so the upgrade checks cannot run: $_state"
fi

if grep -q '^kubectl_manifest\.smithdb_nodepool_' <<< "$_state" && ! _tfvar_is_true "smithdb_keep_karpenter_pools"; then
  _cluster=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster=""
  _region=$(_parse_tfvar "region") || _region=""
  [[ -n "$_cluster" && -n "$_region" ]] \
    || _refuse "the 0.17 SmithDB Karpenter pools are in the state, and the cluster name or region needed to check them is unknown."
  _use_cluster_kubeconfig "$_cluster" "$_region" > /dev/null 2>&1 \
    || _refuse "the 0.17 SmithDB Karpenter pools are in the state, and the cluster $_cluster could not be reached to check them."
  _claims=$(kubectl get nodeclaims -o name 2>&1) \
    || _refuse "the 0.17 SmithDB Karpenter pools are in the state, and listing their nodes failed: $_claims"
  [[ -z "$_claims" ]] \
    || _refuse "this apply would remove Karpenter while it still owns $(wc -l <<< "$_claims" | tr -d ' ') node(s), leaving their EC2 instances running. Set smithdb_keep_karpenter_pools = true until kubectl get nodeclaims lists nothing."
fi
