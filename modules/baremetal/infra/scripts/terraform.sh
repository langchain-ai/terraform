#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# terraform.sh — terraform in infra/, with the object store keys setup-env.sh kept.
#
# Usage (from baremetal/):   make plan | make apply | make destroy   (ARGS are passed on)
#
# Their object store's keys reach Terraform only as TF_VAR_object_store_access_key_id and
# TF_VAR_object_store_secret_access_key, and setup-env.sh keeps them in infra/.secrets.env. Without
# this, make plan and make apply ran without them: the module then read the Secret it had written
# itself as the customer's, and every caller had to export them on its own. One already in the
# environment wins. Values are never printed.

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  echo "ERROR: run this script, do not source it: ${BASH_SOURCE[0]}" >&2
  return 1
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

for pair in object_store_access_key_id:OBJECT_STORE_ACCESS_KEY_ID object_store_secret_access_key:OBJECT_STORE_SECRET_ACCESS_KEY; do
  var="TF_VAR_${pair%%:*}"
  if [[ -z "${!var:-}" ]]; then
    value="$(_secret_get "${pair#*:}")"
    [[ -z "$value" ]] || export "$var=$value"
  fi
done

exec terraform -chdir="$INFRA_DIR" "$@"
