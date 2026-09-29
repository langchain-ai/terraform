#!/usr/bin/env bash
#
# Print, as a JSON array, the providers whose terraform checks a change needs.
# Feeds the check and plan-tests matrices in .github/workflows/checks.yaml.
#
#   git diff --name-only --no-renames -z <base> HEAD | changed-providers.sh
#   changed-providers.sh --all
#
# Reads NUL-separated paths on stdin, so git never quotes an unusual filename
# out of the match. A path under modules/<provider>/ selects that provider. A
# change to the gate itself (agents/, this script, or the workflow) selects
# every provider. Anything else, modules/ocp and docs included, selects none.
set -euo pipefail

# The providers with a check and plan-tests leg. A new provider goes here.
PROVIDERS=(aws azure byoc gcp)

all=0
selected=" "
if [[ "${1:-}" == "--all" ]]; then
  all=1
else
  while IFS= read -r -d '' path; do
    case "$path" in
      agents/* | .github/workflows/checks.yaml | .github/scripts/changed-providers.sh)
        all=1 ;;
      modules/*/*)
        p=${path#modules/}
        selected+="${p%%/*} " ;;
    esac
  done
fi

out=""
for p in "${PROVIDERS[@]}"; do
  if [[ $all == 1 || "$selected" == *" $p "* ]]; then
    out+="${out:+,}\"$p\""
  fi
done
echo "[$out]"
