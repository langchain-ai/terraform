#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# guard-ingress-default.sh — Require an explicit choice before replacing an
# existing controller with Envoy Gateway because ingress_controller is unset.
#
# The current default can replace a controller from an older deployment,
# removing its release and load balancer IP. Exit before that switch unless
# ingress_controller was explicitly selected.
#
# Usage (from azure/):
#   ./infra/scripts/guard-ingress-default.sh [terraform args...]
#
# Pass the same args the plan or apply gets, so a -var or -var-file that sets
# ingress_controller counts. Run by make plan, make apply, make tf, and tf-run.sh.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# Matches both HCL (key = ...) and JSON ("key": ...) variable files.
_sets_ingress_controller() {
  grep -qE -e '^[[:space:]]*ingress_controller[[:space:]]*=' \
           -e '"ingress_controller"[[:space:]]*:' "$1" 2>/dev/null
}

# Any source Terraform reads the variable from counts as a choice.
[ -z "${TF_VAR_ingress_controller:-}" ] || exit 0
for _f in "$INFRA_DIR"/terraform.tfvars "$INFRA_DIR"/terraform.tfvars.json \
          "$INFRA_DIR"/*.auto.tfvars "$INFRA_DIR"/*.auto.tfvars.json; do
  [ -f "$_f" ] && _sets_ingress_controller "$_f" && exit 0
done

# terraform -chdir resolves a relative -var-file against INFRA_DIR.
_var_file() {
  case "$1" in
    /*) _sets_ingress_controller "$1" ;;
    *)  _sets_ingress_controller "$INFRA_DIR/$1" ;;
  esac
}
_next=""
for _arg in "$@"; do
  case "$_next" in
    var)      case "$_arg" in ingress_controller=*) exit 0 ;; esac ;;
    var-file) _var_file "$_arg" && exit 0 ;;
  esac
  _next=""
  case "$_arg" in
    -var=ingress_controller=*|--var=ingress_controller=*) exit 0 ;;
    -var|--var)                                           _next="var" ;;
    -var-file=*|--var-file=*)                             _var_file "${_arg#*=}" && exit 0 ;;
    -var-file|--var-file)                                 _next="var-file" ;;
  esac
done

# Keep the retired release's state address to detect affected deployments.
# An unreadable state (no init yet) lets Terraform report the error itself.
_legacy_controller=$(terraform -chdir="$INFRA_DIR" state list 'module.aks.helm_release.nginx_ingress[0]' 2>/dev/null || true)
[ -n "$_legacy_controller" ] || exit 0

fail "ingress_controller is not set, and this deployment has an existing controller."
info "The default is envoy-gateway. Applying it replaces the existing controller and its load balancer, and the public IP changes."
action "To move to Envoy Gateway, add:  ingress_controller = \"envoy-gateway\""
action "Then run make apply, make init-values, and make deploy back to back. LangSmith is unreachable from the apply until the deploy finishes."
action "Update any DNS A record that points at the old IP."
exit 1
