#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# upgrade-guard.sh — Refuses the first 0.18 apply of a 0.17 install whose
# terraform.tfvars leaves the SmithDB settings to their defaults, and any apply
# to a state that still has the Karpenter SmithDB pools. make apply and make
# quickdeploy run it before terraform apply.
#
# In 0.17 an unset enable_smithdb, smithdb_ingestion_enabled or
# smithdb_query_enabled meant off; in 0.18 each defaults to true. Left unset,
# the first apply would switch the install to querying a SmithDB that holds
# none of its ClickHouse history. A 0.17 state is one without the
# smithdb_query_enabled output that 0.18 added.
#
# In 0.17, enable_smithdb = true runs SmithDB on Karpenter, and 0.18 has no
# Karpenter. An apply would delete the pools and the controller under the
# running SmithDB pods.
#
# A new install (no state) passes. A failed read of the state refuses, because
# it cannot show the apply is safe.
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
[[ -n "$_state" ]] || exit 0

if grep -q -e karpenter -e '^kubectl_manifest\.smithdb_' <<< "$_state"; then
  _refuse "this state still has the Karpenter SmithDB node pools, and 0.18 has no Karpenter. This apply would delete them under the running SmithDB pods. Contact LangChain Support before you upgrade this install, or build a new 0.18 install."
fi

_outputs=$(terraform -chdir="$INFRA_DIR" output -json 2>&1) \
  || _refuse "could not read the Terraform outputs, so the upgrade checks cannot run: $_outputs"
grep -q '"smithdb_query_enabled"' <<< "$_outputs" && exit 0

_parse_tfvar "enable_smithdb" > /dev/null \
  || _refuse "0.18 turns SmithDB on by default. This install predates it: set enable_smithdb in terraform.tfvars, false to keep it off or true to turn it on."
if _tfvar_is_true "enable_smithdb"; then
  for _gate in smithdb_ingestion_enabled smithdb_query_enabled; do
    _parse_tfvar "$_gate" > /dev/null \
      || _refuse "0.18 turns $_gate on by default. This install predates it: set $_gate in terraform.tfvars, false unless it has already cut over to SmithDB."
  done
fi
