#!/bin/sh
# Machine grading for HCL and shell edits. Run after every edit, before
# handing back:
#   bash agents/check.sh modules/aws/infra
# Runs terraform validate (init -backend=false if needed, no cloud creds),
# tflint when available, and shellcheck on scripts under the provider dir.
# Regenerates the schema dump if missing or versions.tf is newer.
# Exit non-zero on failure.
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ $# -lt 1 ]; then
  echo "usage: bash agents/check.sh <terraform-root-dir> [more dirs...]" >&2
  exit 2
fi

status=0
for dir in "$@"; do
  case "$dir" in /*) ;; *) dir="$REPO_ROOT/$dir" ;; esac
  [ -d "$dir" ] || { echo "check: no such dir: $dir" >&2; status=2; continue; }
  echo "== check $dir"
  rel=${dir#"$REPO_ROOT/modules/"}

  if [ ! -d "$dir/.terraform" ]; then
    (cd "$dir" && terraform init -backend=false -input=false -no-color) || {
      status=1; continue; }
  fi

  if [ "${1:-}" = "--init-upgrade" ]; then
    (cd "$dir" && terraform init -backend=false -input=false -upgrade -no-color) || status=1
  fi

  (cd "$dir" && terraform validate -no-color) || status=1

  if command -v tflint >/dev/null 2>&1; then
    # Config (provider plugin pins) lives in modules/<provider>/.tflint.hcl.
    # --chdir makes tflint inspect the root while resolving the config upward
    # from it. Deep inspection is off: no cloud creds needed.
    tflint_parent=$(CDPATH= cd -- "$dir/.." && pwd)
    # Warnings are advisory (pre-existing noise); fail the gate only on
    # tflint errors or worse.
    if [ -f "$tflint_parent/.tflint.hcl" ]; then
      tflint --chdir="$dir" --call-module-type=all --format compact --minimum-failure-severity=error || status=1
    else
      (cd "$dir" && tflint --call-module-type=all --format compact --minimum-failure-severity=error) || status=1
    fi
  else
    echo "   (tflint not installed, skipping lint)"
  fi

  # Lint the provider's shell scripts (deploy, secrets, setup helpers).
  # -S error: warnings are advisory (pre-existing noise); errors fail the gate.
  if command -v shellcheck >/dev/null 2>&1; then
    provider_dir="$REPO_ROOT/modules/$(echo "$rel" | cut -d/ -f1)"
    [ -d "$provider_dir" ] || provider_dir="$dir"
    # Run find from inside provider_dir so paths are relative: the worktree
    # path itself contains /.claude/, which would exclude every file if we
    # matched -path against absolute paths.
    sc_count=$(cd "$provider_dir" && find . -name '*.sh' \
      -not -path '*/.terraform/*' -not -path '*/.claude/*' | wc -l | tr -d ' ')
    if [ "$sc_count" -gt 0 ]; then
      (cd "$provider_dir" && find . -name '*.sh' \
        -not -path '*/.terraform/*' -not -path '*/.claude/*' \
        -print0 | xargs -0 shellcheck -S error) || status=1
      echo "   shellcheck: $sc_count script(s) clean at -S error"
    fi
  else
    echo "   (shellcheck not installed, skipping script lint)"
  fi

  # Keep the schema dump fresh for this root.
  case "$rel" in
    "$dir") ;;  # not under modules/, skip schema bookkeeping
    *)
      schema="$REPO_ROOT/agents/schema/$(echo "$rel" | tr '/' '-').schema.json"
      if [ ! -f "$schema" ] || [ "$dir/versions.tf" -nt "$schema" ] \
         || { [ -f "$dir/.terraform.lock.hcl" ] && [ "$dir/.terraform.lock.hcl" -nt "$schema" ]; }; then
        mkdir -p "$REPO_ROOT/agents/schema"
        (cd "$dir" && terraform providers schema -json) > "$schema.tmp" \
          && mv "$schema.tmp" "$schema" \
          && echo "   schema refreshed: agents/schema/$(basename "$schema")"
      fi
      ;;
  esac
done

exit "$status"
