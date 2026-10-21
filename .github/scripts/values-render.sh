#!/usr/bin/env bash
#
# Render guard: every tracked Helm values file must render against the chart line
# the providers are pinned to. Catches values that the chart rejects outright
# (renamed or removed keys) before they can reach a customer.
#
# Renders, per provider:
#   base + CI site fixture                          the minimum every deploy uses
#   base + fixture + each overlay, one at a time    isolates the failing overlay
#   base + fixture + a representative full stack    catches overlay interactions
#
# OCP is excluded: its values files do not currently target this chart line.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_REPO="${CHART_REPO:-https://langchain-ai.github.io/helm}"
CHART="${CHART:-langchain/langsmith}"
PROVIDERS="aws azure gcp"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Overlays that legitimately do not apply to the langsmith chart.
# Listed explicitly so a skip is never silent.
skip_overlay() {
  case "$(basename "$1")" in
    # langgraph-dataplane chart, not langsmith
    langsmith-values-dataplane.yaml) return 0 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Resolve the pinned chart version from deploy.sh ───────────────────────────
pin=""
for p in $PROVIDERS; do
  f="$REPO_ROOT/modules/$p/helm/scripts/deploy.sh"
  v="$(grep -oE 'CHART_VERSION:-~[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null | head -1 | sed 's/.*-~//')"
  if [ -z "$v" ]; then
    echo "::error::$p deploy.sh is not chart-line pinned" >&2
    exit 1
  fi
  if [ -z "$pin" ]; then pin="$v"
  elif [ "$pin" != "$v" ]; then
    echo "::error::providers disagree on chart version ($pin vs $v in $p)" >&2
    exit 1
  fi
done
CONSTRAINT="~$pin"
echo "Chart: $CHART  constraint: $CONSTRAINT"

helm repo add langchain "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
resolved="$(helm search repo "$CHART" --version "$CONSTRAINT" -o json 2>/dev/null \
  | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"
echo "Resolved chart version: ${resolved:-unknown}"
echo

fail=0
pass=0

render() {
  local label="$1"; shift
  if out="$(helm template ls "$CHART" --version "$CONSTRAINT" "$@" 2>&1)"; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$label"
    printf '%s\n' "$out" \
      | grep -oE 'execution error at \(langsmith/templates/[^)]*\): .*|Error: .*' \
      | head -2 | sed 's/^/         /'
  fi
}

for p in $PROVIDERS; do
  base="$REPO_ROOT/modules/$p/helm/values/values.yaml"
  site="$REPO_ROOT/.github/fixtures/site-$p.yaml"
  overlays_dir="$REPO_ROOT/modules/$p/helm/values/overlays"

  echo "── $p"
  if [ ! -f "$base" ]; then
    echo "  FAIL base values file missing: modules/$p/helm/values/values.yaml"
    fail=$((fail + 1))
    continue
  fi
  if [ ! -f "$site" ]; then
    echo "  FAIL CI site fixture missing: .github/fixtures/site-$p.yaml"
    fail=$((fail + 1))
    continue
  fi

  render "base + site" -f "$base" -f "$site"

  stack=""
  for ov in "$overlays_dir"/*.yaml; do
    [ -e "$ov" ] || continue
    if skip_overlay "$ov"; then
      echo "  skip $(basename "$ov")  (not a langsmith-chart values file)"
      continue
    fi
    # Agent Builder hard-fails without config.deployment.enabled, which only the
    # agent-deploys overlay sets. Render it the way it is actually deployed.
    case "$(basename "$ov")" in
      langsmith-values-agent-builder.yaml)
        render "base + site + agent-deploys + $(basename "$ov")" \
          -f "$base" -f "$site" -f "$overlays_dir/langsmith-values-agent-deploys.yaml" -f "$ov" ;;
      *)
        render "base + site + $(basename "$ov")" -f "$base" -f "$site" -f "$ov" ;;
    esac
    case "$(basename "$ov")" in
      langsmith-values-agent-deploys.yaml|langsmith-values-agent-builder.yaml|\
langsmith-values-insights.yaml|langsmith-values-polly.yaml)
        stack="$stack -f $ov" ;;
    esac
  done

  sizing="$overlays_dir/langsmith-values-sizing-production.yaml"
  if [ -n "$stack" ] && [ -f "$sizing" ]; then
    # shellcheck disable=SC2086
    render "base + site + production sizing + agent-deploys + insights + polly" \
      -f "$base" -f "$site" -f "$sizing" $stack
  fi
  echo
done

echo "──────────────────────────────────────────"
echo "rendered ok: $pass    failed: $fail"
[ "$fail" -eq 0 ] || exit 1
