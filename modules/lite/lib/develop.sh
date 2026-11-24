#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Changing Lite itself: render and check. Sourced by bin/lite.

# Every release through its real chart, at the resolved versions with helm-controller's values layers,
# per infra/tests/render-*.tfvars case: what terraform test cannot see is whether the charts accept the
# values. Needs the Helm repos, so it is not in check.
cmd_render() {
  need terraform helm python3 curl
  heading "render" "every release through its real chart, for each case in infra/tests/render-*.tfvars"
  start_log "$BUILD/logs"
  resolve_versions
  local vars label work
  work="$(mktemp -d)"
  # Expanded now: a local is gone by the time EXIT runs (see install_bundle).
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

# Lite's Traefik settings over k3s's own, against the chart the pinned k3s release bundles (its manifest
# names it and carries k3s's values). k3s's build, not upstream's: upstream 40.1.0 refuses the newer
# Traefik image k3s runs with it.
render_traefik() {
  local work="$1" plan="$2" k3s manifest version
  k3s="$(json_get k3s_version <<<"$(tf show -json "$plan" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["planned_values"]["outputs"]["box"]["value"]))')")"
  manifest="$(curl -fsS --max-time 30 "https://raw.githubusercontent.com/k3s-io/k3s/${k3s//+/%2B}/manifests/traefik.yaml")" || return 1
  version="$(sed -n 's|.*/static/charts/traefik-\([0-9][^/]*\)\.tgz|\1|p' <<<"$manifest" | tail -1)"
  [[ -n "$version" ]] || { echo "no Traefik chart version in k3s $k3s's manifest"; return 1; }
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

cmd_check() {
  need terraform python3 shellcheck uv
  heading "check" "offline, as CI runs it"
  start_log "$BUILD/logs"
  run fmt "terraform fmt" terraform -chdir="$INFRA" fmt -check -recursive
  run validate "validate and tflint (scripts/check.sh)" bash "$LITE/../../scripts/check.sh" modules/lite
  run tests "the plan tests (scripts/plan-tests.sh)" bash "$LITE/../../scripts/plan-tests.sh" modules/lite
  run shell "shellcheck" shellcheck -S style -x "$LITE/bin/lite" "$LITE"/lib/*.sh "$LITE"/box/*.sh
  run iam "the AWS policy covers every resource the AWS host makes" check_iam_policy
  run quality "Python: tests, cc < 15, crap < 30, no dead code" check_python
  printf '\n'
}


# infra/hosts/aws/iam-policy.json has one statement a resource type, its Sid the type in CamelCase
# (aws_ebs_volume -> AwsEbsVolume): a resource added to the host without its permissions would fail
# only at an apply, with someone else's credentials.
check_iam_policy() {
  python3 - "$LITE/infra/hosts/aws" <<'PY'
import json, re, sys
d = sys.argv[1]
sids = {s["Sid"] for s in json.load(open(f"{d}/iam-policy.json"))["Statement"]}
types = set(re.findall(r'^resource "(aws_\w+)"', open(f"{d}/main.tf").read(), re.M))
missing = sorted(t for t in types if "".join(w.capitalize() for w in t.split("_")) not in sids)
print("every resource type has its statement" if not missing else "no statement for: " + ", ".join(missing))
sys.exit(1 if missing else 0)
PY
}

# radon, coverage and vulture come from uv's cache, never installed into the system.
check_python() {
  local q="$BUILD/quality" tools=(uv run --quiet --no-project --with radon --with coverage --with vulture)
  mkdir -p "$q"
  # Every tool runs from lib/: from two places, coverage and radon name files differently and every
  # file read as untested.
  (
    cd "$LITE/lib" || exit 1
    PYTHONPATH=. "${tools[@]}" coverage run --data-file="$q/.coverage" --source=. --omit='tests/*' -m unittest discover -s tests -q &&
      "${tools[@]}" coverage json --data-file="$q/.coverage" -o "$q/coverage.json" -q &&
      "${tools[@]}" radon cc -j -e 'tests/*' . >"$q/radon.json" &&
      "${tools[@]}" vulture . --exclude tests --min-confidence 80 &&
      python3 quality.py "$q/radon.json" "$q/coverage.json"
  )
}
