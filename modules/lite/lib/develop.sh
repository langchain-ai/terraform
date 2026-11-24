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
    # A box's Traefik; a cluster of one's own brings its own ingress.
    if ! grep -q '^cloud *= *"cluster"' "$vars"; then
      run traefik "k3s's Traefik with Lite's settings, ${label#render-}" render_traefik "$work" "$work/$label.plan"
    fi
  done
  printf '\n'
}

# Lite's Traefik settings over k3s's own, against the Traefik chart the pinned k3s release bundles: its
# manifest names the chart (traefik-<version>.tgz, k3s's own build, published in k3s's chart repo) and
# carries k3s's values. k3s's build, not upstream's: upstream 40.1.0 refuses the newer Traefik image k3s
# runs with it.
render_traefik() {
  local work="$1" plan="$2" k3s manifest version
  k3s="$(json_get k3s_version <<<"$(tf show -json "$plan" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["planned_values"]["outputs"]["box"]["value"]))')")"
  manifest="$(curl -fsS --max-time 30 "https://raw.githubusercontent.com/k3s-io/k3s/${k3s//+/%2B}/manifests/traefik.yaml")" || return 1
  version="$(sed -n 's|.*/static/charts/traefik-\([0-9][^/]*\)\.tgz|\1|p' <<<"$manifest" | tail -1)"
  [[ -n "$version" ]] || { echo "no Traefik chart version in k3s $k3s's manifest"; return 1; }
  # k3s's valuesContent: the indented block under the traefik HelmChart's valuesContent.
  awk '/name: traefik$/ { t = 1 } t && /valuesContent: \|-/ { v = 1; next } v && /^  [a-z]/ { exit } v { sub(/^    /, ""); print }' <<<"$manifest" >"$work/traefik.k3s.yaml"
  tf show -json "$plan" | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["planned_values"]["outputs"]["box"]["value"]["traefik_values"], open(sys.argv[1], "w"))' "$work/traefik.lite.json"
  echo "k3s $k3s bundles Traefik chart $version"
  helm template traefik traefik --repo https://k3s-io.github.io/k3s-charts --version "$version" -n kube-system \
    -f "$work/traefik.k3s.yaml" -f "$work/traefik.lite.json"
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
  run python "every Python file parses" python3 -c 'import ast, sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' "$LITE"/lib/*.py
  run settings "the questions refuse a missing ssh_host" check_settings
  printf '\n'
}

# Without a terminal nothing is asked: a missing required setting must fail, and one given as NAME=value
# must be saved. A fleet runs make up this way, and a prompt there would hang it.
check_settings() {
  local dir
  dir="$(mktemp -d)"
  ! python3 "$LITE/lib/settings.py" "$dir/t.tfvars" </dev/null || return 1
  ssh_host=lab1 box=m python3 "$LITE/lib/settings.py" "$dir/t.tfvars" </dev/null || return 1
  grep -q '^box = "m"$' "$dir/t.tfvars" && grep -q '^ssh_host = "lab1"$' "$dir/t.tfvars"
  local ok=$?
  rm -rf "$dir"
  return "$ok"
}
