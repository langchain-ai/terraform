#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# terraform.sh — terraform in infra/, with the object store keys setup-env.sh kept.
#
# Usage (from baremetal/):   make plan | make apply | make destroy   (ARGS are passed on)
#
# An external object store's keys, with object_store_secret_managed, reach Terraform only as
# TF_VAR_object_store_access_key_id and TF_VAR_object_store_secret_access_key, and setup-env.sh keeps
# them in infra/.secrets.env. A run without them stops at plan on the variables' validation. One already
# in the environment wins. Values are never printed.

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  echo "ERROR: run this script, do not source it: ${BASH_SOURCE[0]}" >&2
  return 1
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

# The keys are exported only when the module writes the Secret: exported whenever the secrets file held them,
# keys kept from an earlier setting tripped the variables' validation on every plan.
_tfvar_is_true object_store_secret_managed || exec terraform -chdir="$INFRA_DIR" "$@"
for pair in object_store_access_key_id:OBJECT_STORE_ACCESS_KEY_ID object_store_secret_access_key:OBJECT_STORE_SECRET_ACCESS_KEY; do
  var="TF_VAR_${pair%%:*}"
  if [[ -z "${!var:-}" ]]; then
    value="$(_secret_get "${pair#*:}")"
    [[ -z "$value" ]] || export "$var=$value"
  fi
done

exec terraform -chdir="$INFRA_DIR" "$@"
