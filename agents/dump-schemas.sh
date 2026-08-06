#!/usr/bin/env bash
# Dump `terraform providers schema -json` per root into agents/schema/.
# Ground truth for the pinned provider versions, for agents to grep instead of
# guessing attribute names. Gitignored: regenerate rather than commit.
# Usage: bash agents/dump-schemas.sh [<provider>/<root> ...]   (default: all)
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$REPO_ROOT/agents/schema"
mkdir -p "$OUT_DIR"

# Same discovery rule as check.sh: a root is modules/<provider>/<root> with its
# own versions.tf. Discovered rather than hardcoded so a new root cannot be
# silently missed.
if [ $# -eq 0 ]; then
  discovered=()
  for _versions in "$REPO_ROOT"/modules/*/*/versions.tf; do
    [ -f "$_versions" ] || continue
    _root=${_versions%/versions.tf}
    discovered+=("${_root#"$REPO_ROOT/modules/"}")
  done
  if [ ${#discovered[@]} -eq 0 ]; then
    echo "dump-schemas: found no terraform roots under modules/" >&2
    exit 2
  fi
  set -- "${discovered[@]}"
fi

status=0
for rel in "$@"; do
  dir="$REPO_ROOT/modules/$rel"
  if [ ! -d "$dir" ]; then
    echo "== $rel: no such root, skipping" >&2
    status=1
    continue
  fi
  out="$OUT_DIR/$(echo "$rel" | tr '/' '-').schema.json"
  if [ ! -d "$dir/.terraform" ]; then
    echo "== $rel: not initialized, running terraform init -backend=false"
    (cd "$dir" && terraform init -backend=false -input=false -no-color >/dev/null) || {
      echo "   init failed for $rel, skipping" >&2
      status=1
      continue
    }
  fi
  echo "== $rel -> ${out#"$REPO_ROOT/"}"
  if ! (cd "$dir" && terraform providers schema -json) > "$out.tmp"; then
    echo "   schema dump failed for $rel" >&2
    rm -f "$out.tmp"
    status=1
    continue
  fi
  mv "$out.tmp" "$out"
done

echo "Done. Schemas in agents/schema/"
exit "$status"
