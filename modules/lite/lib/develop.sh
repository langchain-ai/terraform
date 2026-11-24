#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Changing Lite itself: render and check. Sourced by bin/lite.

# Render every release the plan would install through its real chart, at the resolved versions and with
# the values layers helm-controller applies, for each infra/tests/render-*.tfvars case. What terraform
# test cannot see: whether the charts accept the values. Needs the Helm repos, so it is not in check.
cmd_render() {
  need terraform helm python3 curl
  heading "render" "every release through its real chart, for each case in infra/tests/render-*.tfvars"
  start_log "$BUILD/logs"
  resolve_versions
  local vars label work
  work="$(mktemp -d)"
  # Expanded now: a local is gone by the time EXIT runs, and set -u stopped the cleanup on it.
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  for vars in "$INFRA"/tests/render-*.tfvars; do
    label="$(basename "$vars" .tfvars)"
    run "${label#render-}" "plan the case" tf plan -input=false -lock=false -var-file="$vars" -out="$work/$label.plan"
    tf show -json "$work/$label.plan" | python3 -c '
import json, sys
out = sys.argv[1]
for name, r in json.load(sys.stdin)["planned_values"]["outputs"]["values"]["value"].items():
    json.dump(r["values"], open(f"{out}/{name}.json", "w"))
    open(f"{out}/{name}.layer.yaml", "w").write(r["layer"] or "{}\n")
    c = r["chart"]
    print(name, r["namespace"], c.get("repo", "-"), c["chart"], c.get("version", "-"))
' "$work" >"$work/releases"
    while read -r name ns repo chart version; do
      run "$name" "helm template, ${label#render-}" render_one "$work" "$name" "$ns" "$repo" "$chart" "$version"
    done <"$work/releases"
  done
  printf '\n'
}

render_one() {
  local work="$1" name="$2" ns="$3" repo="$4" chart="$5" version="$6" args
  if [[ "$name" == datastores ]]; then args=("$DATASTORES_CHART"); else args=("$chart" --repo "$repo" --version "$version"); fi
  helm template "$name" "${args[@]}" -n "$ns" -f "$work/$name.json" -f "$work/$name.layer.yaml"
}

# Offline, as CI runs it: the repo's own gates for this module, and this folder's shell.
cmd_check() {
  need terraform python3 shellcheck
  heading "check" "offline, as CI runs it"
  start_log "$BUILD/logs"
  run fmt "terraform fmt" terraform -chdir="$INFRA" fmt -check -recursive
  run validate "validate and tflint (scripts/check.sh)" bash "$LITE/../../scripts/check.sh" modules/lite
  run tests "the plan tests (scripts/plan-tests.sh)" bash "$LITE/../../scripts/plan-tests.sh" modules/lite
  run shell "shellcheck" shellcheck -S style -x "$LITE/bin/lite" "$LITE"/lib/*.sh "$LITE"/box/*.sh
  run python "the plan summary parses" python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$LITE/lib/summary.py"
  printf '\n'
}
