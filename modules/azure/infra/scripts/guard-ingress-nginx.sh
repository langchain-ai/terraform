#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# guard-ingress-nginx.sh — Stop a plan or apply while the Terraform state still
# holds the ingress-nginx release.
#
# 0.18 removed ingress_controller = "nginx". On a deployment that still runs it,
# the next apply removes ingress-nginx and its load balancer, and the public IP
# changes. Validation stops only a terraform.tfvars that says "nginx"; one
# created on the old nginx default never set ingress_controller and now reads
# as envoy-gateway. Both deployments hold the release in their state, so this
# reads the state.
#
# Usage (from azure/):
#   ./infra/scripts/guard-ingress-nginx.sh
#
# Run by make plan, make apply, make tf, and tf-run.sh. Exit 0 to continue, 1 to stop.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# An unreadable state (no init yet) lets the run through, and terraform reports it.
_state=$(terraform -chdir="$INFRA_DIR" state list 2>/dev/null) || exit 0
grep -qE '(^|\.)module\.aks\.helm_release\.nginx_ingress\[' <<< "$_state" || exit 0

fail "This deployment still runs ingress-nginx, which 0.18 removed."
info "Applying this release removes ingress-nginx and its load balancer, and the public IP changes."
action "Keep the previous release until the deployment has moved to another controller."
action "On that release, set ingress_controller in terraform.tfvars, then run make apply, make init-values, and make deploy back to back."
action "Update any DNS A record that points at the old IP, then upgrade. See INGRESS_CONTROLLERS.md."
exit 1
