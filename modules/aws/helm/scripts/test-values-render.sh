#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-values-render.sh — Checks _values.sh, which writes and checks the two
# values files on AWS, Azure and GCP: the merge, the seal, the header inputs, the
# 0.17 layout, and the checks deploy.sh runs. scripts/check.sh keeps the three
# copies of _values.sh identical, so this tests all of them. Needs helm for the
# merge; no chart and no cluster.
#
# Usage: bash helm/scripts/test-values-render.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_values.sh
source "$SCRIPT_DIR/_values.sh"
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is not installed" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# check <name> <want> <got>
check() {
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); echo "  PASS  $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $1"
    echo "        want: ${2:-(nothing)}" | sed '2,$s/^/              /'
    echo "        got:  ${3:-(nothing)}" | sed '2,$s/^/              /'
  fi
}

# get <file>... -- <key>...: the value, or "(none)" when _values_get returns 1.
get() {
  _values_get "$@" || echo "(none)"
}

# A module and its terraform.tfvars, in a directory name with a space, as a
# checkout path can have.
MOD="$TMP/a module"
VALUES="$MOD/helm/values"
EXAMPLES="$VALUES/examples"
mkdir -p "$EXAMPLES" "$MOD/helm/scripts" "$MOD/infra"
printf '# The base values.\nconfig:\n  basePath: ""\n' > "$EXAMPLES/$_VALUES_BASE"
printf 'fleet:\n  enabled: true\n' > "$EXAMPLES/langsmith-values-fleet.yaml"
printf '#!/usr/bin/env bash\n' > "$MOD/helm/scripts/init-values.sh"
INFRA_DIR="$MOD/infra"
printf 'enable_fleet = true\nregion = "us-west-2"\n' > "$INFRA_DIR/terraform.tfvars"
# Like the parsers of the three clouds: the first line of a key, quotes removed.
_parse_tfvar() {
  awk -v key="$1" -F' *= *' '$1 == key { v = $2; gsub(/"/, "", v); print v; found = 1; exit }
    END { exit !found }' "$INFRA_DIR/terraform.tfvars"
}

echo "sha256"
check "of stdin" "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb" "$(printf 'abc\n' | _values_sha256)"
printf 'abc\n' > "$TMP/abc"
check "of a file" "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb" "$(_values_sha256 "$TMP/abc")"

echo "merge"
cat > "$TMP/a.yaml" <<'EOF'
config:
  hostname: "http://a"
  port: "5432"
list: [1, 2]
smithdb:
  query:
    deployment:
      resources:
        requests:
          cpu: "1"
annotations:
  eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/a"
EOF
cat > "$TMP/b.yaml" <<'EOF'
config:
  extra: true
  empty: ""
  gone: null
list: [3]
EOF
_values_merge "$TMP/merged.yaml" -f "$TMP/a.yaml" -f "$TMP/b.yaml" --set polly.enabled=false \
  --set-json 'smithdb.query.deployment.resources={}' --set-string count=10
check "a later file adds a key" "true" "$(get "$TMP/merged.yaml" -- config extra)"
check "an earlier key stays" "http://a" "$(get "$TMP/merged.yaml" -- config hostname)"
check "a quoted number stays a string" "5432" "$(get "$TMP/merged.yaml" -- config port)"
check "--set applies" "false" "$(get "$TMP/merged.yaml" -- polly enabled)"
check "--set-string applies" "10" "$(get "$TMP/merged.yaml" -- count)"
check "--set-json {} clears a map" "(none)" "$(get "$TMP/merged.yaml" -- smithdb query deployment resources requests cpu)"
check "a later list replaces an earlier one" "3" \
  "$(awk '/^list:/ { l = 1; next } l && /^[^ -]/ { l = 0 } l { gsub(/[- ]/, ""); print }' "$TMP/merged.yaml")"
check "a key with dots" "arn:aws:iam::123456789012:role/a" \
  "$(get "$TMP/merged.yaml" -- annotations eks.amazonaws.com/role-arn)"
check "an empty string is a value" "" "$(get "$TMP/merged.yaml" -- config empty)"
check "a null is no value" "(none)" "$(get "$TMP/merged.yaml" -- config gone)"
check "a map is no value" "(none)" "$(get "$TMP/merged.yaml" -- config)"
check "a missing key is no value" "(none)" "$(get "$TMP/merged.yaml" -- missing key)"
check "the second file wins when read from both" "true" "$(get "$TMP/a.yaml" "$TMP/b.yaml" -- config extra)"

echo "seal"
_values_render_base "$EXAMPLES/$_VALUES_BASE" "$VALUES/$_VALUES_BASE"
check "a written base is intact" "intact" "$(_values_seal_state "$VALUES/$_VALUES_BASE")"
check "the base holds the example after two header lines" "same" \
  "$(tail -n +3 "$VALUES/$_VALUES_BASE" | cmp -s - "$EXAMPLES/$_VALUES_BASE" && echo same)"
check "only the owner can read it" "-rw-------" "$(ls -l "$VALUES/$_VALUES_BASE" | cut -c1-10)"
cp "$VALUES/$_VALUES_BASE" "$TMP/edited.yaml"
printf 'extra: line\n' >> "$TMP/edited.yaml"
check "an appended line is an edit" "edited" "$(_values_seal_state "$TMP/edited.yaml")"
check "a file without the line 1 hash is unsealed" "unsealed" "$(_values_seal_state "$EXAMPLES/$_VALUES_BASE")"
check "a missing file is missing" "missing" "$(_values_seal_state "$TMP/none.yaml")"

echo "plan and write"
printf 'config:\n  hostname: "http://generated"\n' > "$TMP/core.yaml"
_values_plan_reset
_values_plan_file generated "$TMP/core.yaml" "core values"
_values_plan_file example "$EXAMPLES/langsmith-values-fleet.yaml"
_values_plan_local "$VALUES"
_values_plan_set --set polly.enabled=false
_values_plan_tfvars enable_fleet region unset_key
_values_plan_resolved some_flag true
_values_plan_script "$MOD" helm/scripts/init-values.sh
OVR="$VALUES/$_VALUES_OVERRIDES"
_values_write "$VALUES" "$EXAMPLES"
check "the write succeeds" "0" "$?"
check "the overrides file is intact" "intact" "$(_values_seal_state "$OVR")"
check "an example merges" "true" "$(get "$OVR" -- fleet enabled)"
check "a --set merges" "false" "$(get "$OVR" -- polly enabled)"
check "the header records an unset key" "  tfvar unset_key =" "$(_values_notes "$OVR" tfvar | tail -n 1)"
check "the header records no local file" "  local none" "$(_values_notes "$OVR" local)"
check "deploy.sh's checks pass" "0" "$(_values_check "$MOD" "$VALUES" 2>/dev/null; echo $?)"
check "nothing drifted" "" "$(_values_drift "$OVR" "$MOD" "$VALUES")"
check "the same resolved value is no drift" "" "$(_values_resolved_drift "$OVR" some_flag=true)"
check "another resolved value is drift" \
  'Terraform now resolves some_flag to "false", and the file was written for "true"' \
  "$(_values_resolved_drift "$OVR" some_flag=false)"
check "an unrecorded resolved value is drift" \
  'Terraform now resolves new_flag to "x", and the file was written for "unset"' \
  "$(_values_resolved_drift "$OVR" new_flag=x)"

echo "drift"
printf 'region = "eu-west-1"\nenable_fleet = true\n' > "$INFRA_DIR/terraform.tfvars"
check "a terraform.tfvars change" 'terraform.tfvars has region = "eu-west-1", and the file was written for "us-west-2"' \
  "$(_values_drift "$OVR" "$MOD" "$VALUES")"
check "deploy.sh's checks stop on it" "1" "$(_values_check "$MOD" "$VALUES" 2>/dev/null; echo $?)"
printf 'enable_fleet = true\nregion = "us-west-2"\nunset_key = "now set"\n' > "$INFRA_DIR/terraform.tfvars"
check "a key set later" 'terraform.tfvars has unset_key = "now set", and the file was written for ""' \
  "$(_values_drift "$OVR" "$MOD" "$VALUES")"
printf 'enable_fleet = true\nregion = "us-west-2"\n' > "$INFRA_DIR/terraform.tfvars"
printf 'frontend:\n  replicas: 3\n' > "$VALUES/$_VALUES_LOCAL"
check "a local file added later" "$_VALUES_LOCAL was added" "$(_values_drift "$OVR" "$MOD" "$VALUES")"
_values_plan_reset
_values_plan_file generated "$TMP/core.yaml" "core values"
_values_plan_local "$VALUES"
_values_plan_tfvars region
_values_plan_script "$MOD" helm/scripts/init-values.sh
_values_write "$VALUES" "$EXAMPLES"
check "the local file merges" "3" "$(get "$OVR" -- frontend replicas)"
check "the local file is recorded" "" "$(_values_drift "$OVR" "$MOD" "$VALUES")"
printf 'frontend:\n  replicas: 4\n' > "$VALUES/$_VALUES_LOCAL"
check "a local file changed later" "$_VALUES_LOCAL changed" "$(_values_drift "$OVR" "$MOD" "$VALUES")"
rm "$VALUES/$_VALUES_LOCAL"
check "a local file removed later" "$_VALUES_LOCAL was removed" "$(_values_drift "$OVR" "$MOD" "$VALUES")"
printf '# changed\n' >> "$MOD/helm/scripts/init-values.sh"
check "a module script changed" "helm/scripts/init-values.sh changed (a module upgrade)" \
  "$(_values_drift "$OVR" "$MOD" "$VALUES" | grep 'init-values.sh')"

echo "examples"
_values_plan_reset
_values_plan_file example "$EXAMPLES/langsmith-values-fleet.yaml"
_values_write "$VALUES" "$EXAMPLES"
printf 'fleet:\n  enabled: false\n' > "$EXAMPLES/langsmith-values-fleet.yaml"
check "an example changed" "helm/values/examples/langsmith-values-fleet.yaml changed" "$(_values_drift "$OVR" "$MOD" "$VALUES")"
printf '# The base values, changed.\n' > "$EXAMPLES/$_VALUES_BASE"
check "a changed base example stops deploy.sh" "changed after make init-values copied it" \
  "$(_values_check "$MOD" "$VALUES" 2>&1 | grep -o 'changed after make init-values copied it')"

echo "hand edits"
printf 'fleet:\n  enabled: true\n' > "$EXAMPLES/langsmith-values-fleet.yaml"
_values_write "$VALUES" "$EXAMPLES"
printf 'byHand: true\n' >> "$OVR"
cp "$OVR" "$TMP/kept.yaml"
_values_write "$VALUES" "$EXAMPLES" 2> "$TMP/write.err"
check "a write over a hand edit fails" "1" "$?"
check "it prints the edit" "+byHand: true" "$(grep -o '+byHand: true' "$TMP/write.err")"
check "it leaves the edited file" "same" "$(cmp -s "$TMP/kept.yaml" "$OVR" && echo same)"
check "deploy.sh's checks stop on it" "was edited after make init-values wrote it" \
  "$(_values_check "$MOD" "$VALUES" 2>&1 | grep -o 'was edited after make init-values wrote it' | head -1)"
rm "$OVR"

echo "set strings"
_values_plan_reset
_values_plan_file generated "$TMP/core.yaml" "core values"
_values_plan_tfvars region
_values_write "$VALUES" "$EXAMPLES"
_values_notes "$OVR" > "$TMP/notes-before"
_values_set_strings "$OVR" "config.hostname=http://new.example.com" "config.deployment.url=http://new.example.com"
check "the hostname changes" "http://new.example.com" "$(get "$OVR" -- config hostname)"
check "the url changes" "http://new.example.com" "$(get "$OVR" -- config deployment url)"
check "the file stays sealed" "intact" "$(_values_seal_state "$OVR")"
check "the notes stay" "same" "$(_values_notes "$OVR" | cmp -s - "$TMP/notes-before" && echo same)"

echo "0.17 layout"
LEGACY="$TMP/legacy values"
mkdir -p "$LEGACY"
cp "$EXAMPLES/langsmith-values-fleet.yaml" "$LEGACY/"
cp "$EXAMPLES/$_VALUES_BASE" "$LEGACY/"
printf 'config: {}\n' > "$LEGACY/values-overrides.yaml"
printf 'config: {}\n' > "$LEGACY/$_VALUES_OVERRIDES"
printf 'backend: {}\n' > "$LEGACY/langsmith-values-sizing-dev.yaml"
printf 'config: {}\n' > "$LEGACY/langsmith-sandbox-values-overrides.yaml"
printf 'config: {}\n' > "$LEGACY/$_VALUES_LOCAL"
printf 'config: {}\n' > "$LEGACY/$_VALUES_LOCAL.example"
check "the 0.17 files" \
  $'langsmith-values-fleet.yaml\nlangsmith-values-overrides.yaml\nlangsmith-values-sizing-dev.yaml\nvalues-overrides.yaml' \
  "$(_values_legacy_files "$LEGACY" "$EXAMPLES" | LC_ALL=C sort)"
printf 'config: {}\n' > "$LEGACY/$_VALUES_BASE"
check "a base copy that differs from the example" "$_VALUES_BASE" \
  "$(_values_legacy_files "$LEGACY" "$EXAMPLES" | grep -x "$_VALUES_BASE")"
_values_legacy_stop "$LEGACY" "$EXAMPLES" 2> "$TMP/legacy.err"
check "the 0.17 layout stops" "1" "$?"
check "an unchanged copy is marked" "same as examples/langsmith-values-fleet.yaml" \
  "$(grep -o 'same as examples/langsmith-values-fleet.yaml' "$TMP/legacy.err")"
check "the secrets in values-overrides.yaml are named" "plaintext secrets" \
  "$(grep -o 'plaintext secrets' "$TMP/legacy.err")"
check "the move command names the files" "1" "$(grep -c 'mv .*langsmith-values-fleet.yaml' "$TMP/legacy.err")"
check "no 0.17 file passes" "0" "$(_values_legacy_stop "$TMP/none" "$EXAMPLES" 2>/dev/null; echo $?)"

echo "bash 3.2"
_values_plan_reset
_values_render_overrides "$TMP/empty.yaml"
check "an empty plan writes a sealed file" "intact" "$(_values_seal_state "$TMP/empty.yaml")"

echo ""
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
