#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# cert-manager-upgrade.sh — Step an existing cert-manager release up to
#                           cert_manager_version, one minor version at a time.
#
# Usage (from gcp/):
#   make cert-manager-upgrade                # asks before it starts
#   YES=1 make cert-manager-upgrade          # no prompt
#   TARGET=v1.20.4 make cert-manager-upgrade # stop at another supported patch
#
# cert-manager supports upgrades one minor version at a time, and the Terraform
# apply refuses to jump more than one minor (null_resource.cert_manager_upgrade_
# guard). This script runs helm upgrade through the latest patch of each minor
# between the installed version and the target, and waits for cert-manager to be
# ready after each step. Then run make apply, which brings the release back under
# Terraform's values and moves it to the OCI chart repository.
#
# What it touches: the cert-manager Helm release in the cert-manager namespace.
# Certificates, Issuers, and their Secrets stay in place; crds.keep keeps the
# CRDs if the release is ever uninstalled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

CHART="oci://quay.io/jetstack/charts/cert-manager"
NAMESPACE="cert-manager"
RELEASE="cert-manager"

# The latest patch of each minor, from the cert-manager releases page. Each step
# reads its own upgrade notes: https://cert-manager.io/docs/releases/upgrading/
# v1.19.0 is skipped on purpose: it can re-issue certificates unnecessarily.
STEPS=(v1.15.5 v1.16.5 v1.17.4 v1.18.6 v1.19.6 v1.20.4 v1.21.2)

_minor() { printf '%s' "$1" | sed -E 's/^v?1\.([0-9]+)\..*$/\1/'; }

for _tool in gcloud kubectl helm terraform; do
  command -v "$_tool" >/dev/null 2>&1 || { fail "$_tool is required"; exit 1; }
done

TARGET="${TARGET:-$(_parse_tfvar cert_manager_version)}"
TARGET="${TARGET:-v1.21.2}"
_target_minor=$(_minor "$TARGET")

_project_id=$(_parse_tfvar project_id)
_region=$(_parse_tfvar region)
_region="${_region:-us-west2}"
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
if [[ -z "$_project_id" || -z "$_cluster_name" ]]; then
  fail "Could not read project_id from terraform.tfvars or cluster_name from terraform output."
  action "Run from modules/gcp after make apply has created the cluster."
  exit 1
fi

# Credentials for this cluster only, in a temp kubeconfig, as the Terraform
# provisioners do. The operator's current context is left alone.
KUBECONFIG="$(mktemp -t ls-kubeconfig.XXXXXX)"
export KUBECONFIG
trap 'rm -f "$KUBECONFIG"' EXIT
gcloud container clusters get-credentials "$_cluster_name" \
  --region "$_region" --project "$_project_id" --quiet >/dev/null

_installed_version() {
  kubectl get deployment cert-manager -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true
}

_wait_ready() {
  local d
  for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
    kubectl rollout status "deployment/$d" -n "$NAMESPACE" --timeout=300s
  done
}

header "cert-manager upgrade"
_current=$(_installed_version)
if [[ -z "$_current" ]]; then
  info "cert-manager is not installed in ${NAMESPACE}. make apply installs ${TARGET} directly."
  exit 0
fi
_current_minor=$(_minor "$_current")
info "Cluster:   ${_cluster_name} (${_project_id}, ${_region})"
info "Installed: ${_current}"
info "Target:    ${TARGET}"

if [[ ! "$_current_minor" =~ ^[0-9]+$ || ! "$_target_minor" =~ ^[0-9]+$ ]]; then
  fail "Cannot read the installed or target minor version."
  exit 1
fi
if (( _current_minor >= _target_minor )); then
  pass "Already at minor ${_current_minor}. Nothing to step through: run make apply."
  exit 0
fi

_plan=()
for _v in "${STEPS[@]}"; do
  _m=$(_minor "$_v")
  if (( _m > _current_minor && _m < _target_minor )); then
    _plan+=("$_v")
  fi
done
_plan+=("$TARGET")
info "Steps:     ${_plan[*]}"
echo ""
warn "Read the upgrade notes for each step first: https://cert-manager.io/docs/releases/upgrading/"
info "Notable: 1.18 changes the default private key rotationPolicy to Always,"
info "and 1.15 moves the startupapicheck job to its own image (mirror it if you pull from a registry mirror)."

if [[ "${YES:-}" != "1" ]]; then
  printf "\n  Continue? [y/N]: "
  read -r _reply
  [[ "$_reply" =~ ^[Yy]$ ]] || { info "Stopped. Nothing changed."; exit 0; }
fi

for _v in "${_plan[@]}"; do
  header "helm upgrade ${RELEASE} -> ${_v}"
  # --reuse-values keeps the resources Terraform set. crds.enabled replaces the
  # deprecated installCRDs, and crds.keep keeps the CRDs across an uninstall.
  helm upgrade "$RELEASE" "$CHART" --version "$_v" -n "$NAMESPACE" \
    --reuse-values \
    --set installCRDs=false --set crds.enabled=true --set crds.keep=true \
    --wait --timeout 10m
  _wait_ready
  pass "cert-manager $(_installed_version) is ready"
done

echo ""
_not_ready=$(kubectl get certificates -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
  2>/dev/null | awk '$3 != "True" {print $1 "/" $2}' || true)
if [[ -n "$_not_ready" ]]; then
  warn "Certificates that are not Ready:"
  printf '%s\n' "$_not_ready" | sed 's/^/      /'
  action "kubectl describe certificate <name> -n <namespace>"
else
  pass "Every Certificate is Ready"
fi
action "Now run: make apply   (puts the release back under Terraform's values and chart repository)"
