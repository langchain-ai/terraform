#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-clickhouse-cluster.sh — Unit tests for how clickhouse_cluster reaches the
# chart (_clickhouse_cluster_resolved and _clickhouse_values_block in
# _common.sh): a name set only in *.auto.tfvars or TF_VAR_clickhouse_cluster
# reaches clickhouse.external.cluster through the clickhouse_cluster output, and
# the stamp deploy.sh compares reads the same value. terraform is a shell
# function here, so no Azure and no Terraform binary.
#
# Usage:
#   ./infra/scripts/test-clickhouse-cluster.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-clickhouse-cluster.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export INFRA_DIR="$TMP"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

# The output the stub returns: unset = no state (the call fails), else the JSON.
TF_OUTPUT_JSON=""
TF_HAS_STATE="false"
terraform() {
  if [[ "$*" == *"output -json clickhouse_cluster"* && "$TF_HAS_STATE" == "true" ]]; then
    printf '%s\n' "$TF_OUTPUT_JSON"
    return 0
  fi
  return 1
}

PASS=0; FAIL=0
_check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ok   $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL $name"; FAIL=$((FAIL + 1))
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/       /'
  fi
}
_tfvars() { printf '%s\n' "$@" > "$TMP/terraform.tfvars"; }

BASE='clickhouse:
  external:
    enabled: true
    existingSecretName: "langsmith-clickhouse"'

echo "clickhouse_cluster:"

# Before the first apply: terraform.tfvars is all there is.
TF_HAS_STATE="false"; _tfvars 'clickhouse_source = "external"' 'clickhouse_cluster = "replicated"'
_check "no state: the terraform.tfvars name is written" \
  "$BASE
    cluster: \"replicated\"" "$(_clickhouse_values_block external)"

# The name lives only in an auto.tfvars file (or TF_VAR_): terraform.tfvars
# lacks it, and the applied output carries it.
TF_HAS_STATE="true"; TF_OUTPUT_JSON='"replicated"'; _tfvars 'clickhouse_source = "external"'
_check "name only in *.auto.tfvars or TF_VAR_: the output's name is written" \
  "$BASE
    cluster: \"replicated\"" "$(_clickhouse_values_block external)"

# The output wins over a terraform.tfvars value an auto file overrode.
TF_HAS_STATE="true"; TF_OUTPUT_JSON='"from-auto"'; _tfvars 'clickhouse_source = "external"' 'clickhouse_cluster = "from-tfvars"'
_check "the output wins over terraform.tfvars" "from-auto" "$(_clickhouse_cluster_resolved)"

# A name added to terraform.tfvars since the last apply (null output) is kept.
TF_HAS_STATE="true"; TF_OUTPUT_JSON='null'; _tfvars 'clickhouse_source = "external"' 'clickhouse_cluster = "replicated"'
_check "null output, name in terraform.tfvars: the name is kept" "replicated" "$(_clickhouse_cluster_resolved)"

# Neither names a cluster: no cluster line.
TF_HAS_STATE="true"; TF_OUTPUT_JSON='null'; _tfvars 'clickhouse_source = "external"'
_check "no name anywhere: no cluster line" "$BASE" "$(_clickhouse_values_block external)"

# A malformed output is ignored, not written into the YAML.
TF_HAS_STATE="true"; TF_OUTPUT_JSON='"bad name"'; _tfvars 'clickhouse_source = "external"'
_check "an output outside the name rule is not written" "$BASE" "$(_clickhouse_values_block external)"

# In-cluster ClickHouse: the comment only, whatever the output says.
TF_HAS_STATE="true"; TF_OUTPUT_JSON='"replicated"'
_check "in-cluster: the comment only" "# clickhouse: in-cluster (managed by Helm chart)" "$(_clickhouse_values_block in-cluster)"

# The stamp and the drift check read the same resolved value.
TF_HAS_STATE="true"; TF_OUTPUT_JSON='"replicated"'; _tfvars 'clickhouse_source = "external"'
_values_input_stamp > "$TMP/values.yaml"
_check "the stamp records the output's name" "replicated" "$(_read_values_stamp "$TMP/values.yaml" clickhouse_cluster)"
rc=0; out=$(_values_stamp_drift "$TMP/values.yaml") || rc=$?
_check "the same output reads as no drift" "rc=0" "${out}rc=$rc"
TF_OUTPUT_JSON='"other"'
rc=0; out=$(_values_stamp_drift "$TMP/values.yaml") || rc=$?
_check "a changed output is drift, named as Terraform's" \
  "clickhouse_cluster: generated with 'replicated', Terraform now says 'other'
rc=1" "${out}
rc=$rc"

echo ""
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
