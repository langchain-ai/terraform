#!/usr/bin/env bash
#
# Print, as a JSON array, the providers whose terraform checks a change needs.
# Feeds the check and plan-tests matrices in .github/workflows/checks.yaml, so
# a PR runs only the legs for the clouds it touches.
#
#   git diff --name-only HEAD^1 HEAD | .github/scripts/changed-providers.sh
#   .github/scripts/changed-providers.sh --all
#
# Reads changed paths on stdin, one per line. A path under modules/<provider>/
# selects that provider. A change to the gate itself (agents/, this script, or
# the workflow) selects every provider, since it can break any leg. Anything
# else selects none: modules/ocp and the docs have no terraform leg, and every
# script is linted by the shellcheck job regardless of this list.
set -euo pipefail

# The one list of providers with a check and plan-tests leg. A new provider
# directory goes here.
PROVIDERS=(aws azure byoc gcp)

emit() {
  local out="" p
  for p in "$@"; do
    out+="${out:+,}\"$p\""
  done
  echo "[$out]"
}

if [[ "${1:-}" == "--all" ]]; then
  emit "${PROVIDERS[@]}"
  exit 0
fi

selected=" "
while IFS= read -r path; do
  case "$path" in
    agents/* | .github/workflows/checks.yaml | .github/scripts/changed-providers.sh)
      emit "${PROVIDERS[@]}"
      exit 0
      ;;
    modules/*/*)
      p=${path#modules/}
      p=${p%%/*}
      selected+="$p "
      ;;
  esac
done

# Emit in PROVIDERS order, so modules/ocp and any unlisted directory drop out.
picked=()
for p in "${PROVIDERS[@]}"; do
  case "$selected" in *" $p "*) picked+=("$p") ;; esac
done
emit ${picked[@]+"${picked[@]}"}
