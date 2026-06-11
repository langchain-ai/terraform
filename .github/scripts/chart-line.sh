#!/usr/bin/env bash
#
# Release guard: parse and validate the pinned chart MAJOR.MINOR line from
# every provider's deploy.sh.
#
# Prints the agreed line (e.g. "0.15") to stdout on success.
# Exits non-zero if any provider is unpinned or the providers disagree.
#
# The pinned line is the single source of truth for the release tag's
# MAJOR.MINOR, so this guard ensures a tag can never ship a deploy.sh that
# targets a different chart line than the tag claims.
set -euo pipefail

# Resolve repo root from this script's location (.github/scripts/ -> repo root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVIDERS=(aws gcp azure ocp)

line=""
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

  mm="$(printf '%s' "$pin" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$line" ]]; then
    line="$mm"
  elif [[ "$line" != "$mm" ]]; then
    echo "::error::chart line mismatch: providers disagree ('$line' vs '$mm' in $p deploy.sh)" >&2
    exit 1
  fi
done

printf '%s\n' "$line"
