#!/bin/sh
# Dump `terraform providers schema -json` per initialized root into
# agents/schema/. Ground truth for the pinned provider versions.
# Usage: bash agents/dump-schemas.sh [root-dir ...]  (default: all known roots)
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$REPO_ROOT/agents/schema"
mkdir -p "$OUT_DIR"

if [ $# -gt 0 ]; then
  ROOTS="$*"
else
  ROOTS="aws/infra aws/app azure/infra azure/app gcp/infra gcp/app"
fi

for rel in $ROOTS; do
  dir="$REPO_ROOT/modules/$rel"
  [ -d "$dir" ] || continue
  out="$OUT_DIR/$(echo "$rel" | tr '/' '-').schema.json"
  if [ ! -d "$dir/.terraform" ]; then
    echo "== $rel: not initialized, running terraform init -backend=false -input=false"
    (cd "$dir" && terraform init -backend=false -input=false -no-color >/dev/null) || {
      echo "   init failed for $rel, skipping"
      continue
    }
  fi
  echo "== $rel -> ${out#$REPO_ROOT/}"
  (cd "$dir" && terraform providers schema -json) > "$out.tmp" && mv "$out.tmp" "$out"
done

echo "Done. Schemas in agents/schema/"
