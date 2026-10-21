#!/usr/bin/env bash
#
# Release guard: parse and validate the pinned chart MAJOR.MINOR line from
# every install path a provider offers.
#
# There are two of them and both have to agree:
#   1. helm/scripts/deploy.sh    - the shell path, used by `make deploy`
#   2. app/variables.tf          - the Terraform path, `chart_version`'s default
#
# The Terraform default matters because app/main.tf passes a null version to
# helm_release when chart_version is empty, and a null version resolves to
# whatever is newest at apply time. An unpinned default therefore drifts across
# chart lines on its own, with no commit and no tag to show for it.
#
# Prints the agreed line (e.g. "0.15") to stdout on success.
# Exits non-zero if any path is unpinned or the paths disagree.
#
# The pinned line is the single source of truth for the release tag's
# MAJOR.MINOR, so this guard ensures a tag can never ship a module that
# targets a different chart line than the tag claims.
set -euo pipefail

# Resolve repo root from this script's location (.github/scripts/ -> repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVIDERS=(aws gcp azure ocp)

line=""

# Fold one pin into the agreed line, or fail if it disagrees with what we have.
# $1 = the matched pin text, $2 = human-readable source for the error message.
_record_pin() {
  local mm
  mm="$(printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$line" ]]; then
    line="$mm"
  elif [[ "$line" != "$mm" ]]; then
    echo "::error::chart line mismatch: '$line' vs '$mm' in $2" >&2
    exit 1
  fi
}

for p in "${PROVIDERS[@]}"; do
  f="$REPO_ROOT/modules/$p/helm/scripts/deploy.sh"
  if [[ ! -f "$f" ]]; then
    echo "::error::missing deploy.sh for provider '$p' ($f)" >&2
    exit 1
  fi

  # Match the pinned default: CHART_VERSION="${CHART_VERSION:-~0.15.1}"
  pin="$(grep -oE 'CHART_VERSION:-~[0-9]+\.[0-9]+\.[0-9]+' "$f" | head -1 || true)"
  if [[ -z "$pin" ]]; then
    echo "::error::$p deploy.sh is not line-pinned (expected CHART_VERSION:-~MAJOR.MINOR.PATCH)" >&2
    exit 1
  fi
  _record_pin "$pin" "$p deploy.sh"

  # Terraform path. Not every provider ships an app module (ocp is helm + infra
  # only), so absence is fine; an app module that is present must be pinned.
  v="$REPO_ROOT/modules/$p/app/variables.tf"
  [[ -f "$v" ]] || continue

  # Match the pinned default inside the chart_version block: default = "~0.15.1"
  vpin="$(awk '/^variable "chart_version"[[:space:]]*\{/,/^\}/' "$v" \
    | grep -oE 'default[[:space:]]*=[[:space:]]*"~[0-9]+\.[0-9]+\.[0-9]+"' | head -1 || true)"
  if [[ -z "$vpin" ]]; then
    echo "::error::$p app/variables.tf chart_version is not line-pinned (expected default = \"~MAJOR.MINOR.PATCH\")" >&2
    echo "::error::an empty default resolves to the newest chart at apply time and can cross the chart line" >&2
    exit 1
  fi
  _record_pin "$vpin" "$p app/variables.tf"
done

printf '%s\n' "$line"
