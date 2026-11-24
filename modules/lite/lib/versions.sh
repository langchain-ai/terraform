#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Versions: each chart line in infra/pins.yaml resolved against its live Helm repo, and the bare-metal
# module's datastores chart packaged. Sourced by bin/lite.
#
# The other modules pin LangSmith to a line (CHART_VERSION:-~0.17.0 in their deploy.sh) and resolve it
# when they deploy; Lite resolves before the plan instead, so the plan, the box and the dashboard tag all
# name the same exact version, and the plan shows it. helm show chart --repo reads a repo's index
# without adding the repo to anyone's helm configuration.

# A top-level key of a Chart.yaml. Anchored at the line's start: dependencies carry their own indented
# version keys, and an unanchored match read prometheus's alertmanager subchart as the chart (2.5.1).
chart_field() { awk -v f="^$1:" '$0 ~ f { gsub(/["\047]/, "", $2); print $2; exit }'; }

# pins.yaml as JSON, through Terraform's own YAML reader, so no YAML library is needed here.
pins_json() { tf_eval 'yamldecode(file("pins.yaml"))' || fail "could not read infra/pins.yaml" "check infra/pins.yaml is valid YAML."; }

# One "name repo chart line" line a chart.
pinned_charts() {
  python3 -c 'import json,sys
for n, c in json.loads(sys.argv[1])["charts"].items(): print(n, c["repo"], c["chart"], c["version"])' "$1"
}

# resolve_versions: write infra/resolved.auto.tfvars.json and build/charts/datastores-*.tgz. Its steps
# print through run, so it reads as part of the command that called it.
resolve_versions() {
  local pins lines="" name repo chart line meta version release scrape_url tmp
  pins="$(pins_json)"
  while read -r name repo chart line; do
    meta="$(helm show chart --repo "$repo" "$chart" --version "$line" 2>/dev/null)" \
      || fail "$chart: no release of line $line in $repo" "check the line in infra/pins.yaml, or the network."
    version="$(chart_field version <<<"$meta")"
    lines+="$name $version $(chart_field appVersion <<<"$meta")"$'\n'
  done < <(pinned_charts "$pins")

  tmp="$(mktemp -d)"
  run datastores "package the datastores chart" package_datastores "$tmp"
  lines+="datastores $(cat "$tmp/name") -"$'\n'

  # The chart's own scrape annotations at the release that will run (pins.yaml, observability).
  release="$(awk '$1 == "langsmith" { print $2 }' <<<"$lines")"
  scrape_url="$(json_get observability scrape_values <<<"$pins")"
  run scrape "the chart's metrics annotations at langsmith $release" \
    curl -fsS --max-time 30 "${scrape_url//\{release\}/$release}" -o "$tmp/scrape.yaml"

  printf '%s' "$lines" | python3 -c '
import json, sys
charts, apps = {}, {}
for row in sys.stdin.read().splitlines():
    name, version, app = row.split(" ")
    charts[name] = version
    if app != "-":
        apps[name] = app
scrape = open(sys.argv[2]).read()
json.dump({"resolved": {"charts": charts, "app_versions": apps, "scrape_values": scrape}},
          open(sys.argv[1], "w"), indent=2, sort_keys=True)
' "$INFRA/resolved.auto.tfvars.json" "$tmp/scrape.yaml"
  rm -rf "$tmp"
}

# The datastores chart, named for its version and a digest of every file in it: a change to a template
# without a version bump still gives helm-controller a new chart URL to install.
package_datastores() {
  local out="$1" ds_version ds_digest
  [[ -d "$DATASTORES_CHART" ]] || { echo "the datastores chart is missing at $DATASTORES_CHART"; return 1; }
  ds_version="$(chart_field version <"$DATASTORES_CHART/Chart.yaml")"
  ds_digest="$(cd "$DATASTORES_CHART" && find . -type f ! -name '.DS_Store' -print0 | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-12)"
  mkdir -p "$BUILD/charts"
  helm package "$DATASTORES_CHART" -d "$out" &&
    mv "$out"/datastores-*.tgz "$BUILD/charts/datastores-$ds_version-$ds_digest.tgz" &&
    printf '%s' "$ds_version-$ds_digest" >"$out/name"
}

# make pins: what each line resolves to now, each chart's newest release, and k3s's stable channel.
cmd_pins() {
  local pins name repo chart line version newest stable
  need terraform helm python3 curl
  heading "pins" "each pinned line against its live repo (infra/pins.yaml)"
  pins="$(pins_json)"
  printf '  %s%-18s %-10s %-10s %s%s\n' "$DIM" "chart" "line" "resolves" "newest" "$OFF"
  while read -r name repo chart line; do
    version="$(helm show chart --repo "$repo" "$chart" --version "$line" 2>/dev/null | chart_field version)"
    newest="$(helm show chart --repo "$repo" "$chart" 2>/dev/null | chart_field version)"
    printf '  %-18s %-10s %-10s %s\n' "$name" "$line" "${version:-${RED}none$OFF}" \
      "$([[ "$newest" == "$version" ]] && echo "$newest" || echo "$YELLOW$newest$OFF")"
  done < <(pinned_charts "$pins")
  stable="$(curl -fsS --max-time 15 -o /dev/null -w '%{redirect_url}' https://update.k3s.io/v1-release/channels/stable 2>/dev/null \
    | sed 's|.*/tag/||; s|%2B|+|')"
  printf '\n  %-18s %-21s %s\n' k3s "$(json_get k3s <<<"$pins")" "stable channel ${stable:-unknown}"
  printf '\n  %sA newer patch inside a line arrives with the next make plan; a new line is an edit to infra/pins.yaml.%s\n\n' "$DIM" "$OFF"
}
