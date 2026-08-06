#!/usr/bin/env bash
# Dump `terraform providers schema -json` per root into agents/schema/.
# Ground truth for the pinned provider versions, for agents to grep instead of
# guessing attribute names. Gitignored: regenerate rather than commit.
# Usage: bash agents/dump-schemas.sh [<path-below-modules> ...]  (default: all)
#   e.g. aws/infra, byoc/aws/langsmith-byoc-role
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$REPO_ROOT/agents/schema"
mkdir -p "$OUT_DIR"

# Root discovery lives in check.sh (--list-roots) rather than being repeated
# here, so the two scripts cannot drift apart about what counts as a root.
if [ $# -eq 0 ]; then
  discovered=()
  while IFS= read -r _root; do
    [ -n "$_root" ] || continue
    discovered+=("${_root#modules/}")
  done <<EOF
$(bash "$REPO_ROOT/agents/check.sh" --list-roots)
EOF
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
