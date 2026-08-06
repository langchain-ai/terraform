#!/usr/bin/env bash
# Machine grading for HCL and shell edits. Enforced in CI by
# .github/workflows/checks.yaml, and run locally before handing back:
#   bash agents/check.sh                    # every terraform root
#   bash agents/check.sh modules/aws/infra  # one root
#
# Per root: terraform validate (init -backend=false, so no cloud creds or
# state), tflint with the provider's pinned ruleset, and shellcheck over the
# provider's *.sh. Exit non-zero on failure.
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Script linting gates at warning: the repo is clean at that bar, so holding it
# there prevents regression. tflint gates at error because the HCL still carries
# pre-existing warnings (unused variables, missing version constraints).
# CI sets neither -- it inherits these, so a green local run is a green PR.
# (Comment deliberately does not open with the linter's name: a comment whose
# first word is that name is parsed as an inline directive, not prose.)
SHELLCHECK_SEVERITY=${SHELLCHECK_SEVERITY:-warning}
TFLINT_SEVERITY=${TFLINT_SEVERITY:-error}

init_upgrade=0
if [ "${1:-}" = "--init-upgrade" ]; then
  init_upgrade=1
  shift
fi

# No args: every terraform root. A root is modules/<provider>/<root> with its
# own versions.tf. Anything deeper (infra/modules/*) is a child module,
# validated transitively via --call-module-type=all. modules/byoc and
# modules/ocp have no <provider>/<root>/versions.tf and are not covered.
if [ $# -eq 0 ]; then
  discovered=()
  for _versions in "$REPO_ROOT"/modules/*/*/versions.tf; do
    [ -f "$_versions" ] || continue
    discovered+=("${_versions%/versions.tf}")
  done
  if [ ${#discovered[@]} -eq 0 ]; then
    echo "check: found no terraform roots under modules/" >&2
    exit 2
  fi
  set -- "${discovered[@]}"
fi

# Provider dirs already handled, so tflint --init and shellcheck run once each
# rather than per root. Space-delimited for bash 3.2 (no associative arrays).
tflint_inited=" "
shellchecked=" "
status=0

for dir in "$@"; do
  case "$dir" in /*) ;; *) dir="$REPO_ROOT/$dir" ;; esac
  [ -d "$dir" ] || { echo "check: no such dir: $dir" >&2; status=2; continue; }

  # Resolve the owning provider dir. Everything provider-scoped (the tflint
  # config, the shell scripts, the schema dump name) hangs off this.
  case "$dir" in
    "$REPO_ROOT"/modules/*/*)
      rel=${dir#"$REPO_ROOT/modules/"}
      provider=${rel%%/*}
      provider_dir="$REPO_ROOT/modules/$provider"
      ;;
    *)
      rel=""
      provider=""
      provider_dir="$dir"
      ;;
  esac

  echo "== check ${dir#"$REPO_ROOT/"}"

  if [ ! -d "$dir/.terraform" ]; then
    (cd "$dir" && terraform init -backend=false -input=false -no-color) || {
      status=1; continue; }
  elif [ "$init_upgrade" -eq 1 ]; then
    (cd "$dir" && terraform init -backend=false -input=false -upgrade -no-color) || status=1
  fi

  (cd "$dir" && terraform validate -no-color) || status=1

  if command -v tflint >/dev/null 2>&1; then
    # The provider plugin pin lives in modules/<provider>/.tflint.hcl. tflint
    # only looks for .tflint.hcl in its working directory (and then $HOME) --
    # it does NOT walk up the tree -- so with --chdir pointing at the root, the
    # config has to be passed explicitly or the provider ruleset silently never
    # loads and only the bundled terraform rules run.
    tflint_cfg="$provider_dir/.tflint.hcl"
    tflint_args=(--chdir="$dir" --call-module-type=all --format=compact
                 --minimum-failure-severity="$TFLINT_SEVERITY")
    if [ -f "$tflint_cfg" ]; then
      tflint_args+=(--config="$tflint_cfg")
      # Plugins install to ~/.tflint.d/plugins; idempotent once warm, and
      # required at least once per machine or tflint exits "plugin not found".
      case "$tflint_inited" in
        *" $provider "*) ;;
        *)
          tflint --init --config="$tflint_cfg" >/dev/null || {
            echo "   tflint --init failed for $provider" >&2; status=1; }
          tflint_inited="$tflint_inited$provider "
          ;;
      esac
    else
      echo "   (no $provider/.tflint.hcl, bundled terraform rules only)"
    fi
    tflint "${tflint_args[@]}" || status=1
  else
    echo "   (tflint not installed, skipping lint)"
  fi

  # Lint the provider's shell scripts (deploy, secrets, setup helpers). Scoped
  # to the provider rather than the root because the scripts under helm/ drive
  # the app root and belong to the same review.
  if command -v shellcheck >/dev/null 2>&1; then
    case "$shellchecked" in
      *" $provider_dir "*) ;;
      *)
        shellchecked="$shellchecked$provider_dir "
        # find runs from inside provider_dir so -path matches relative paths:
        # a worktree checkout lives under .claude/, which would otherwise
        # exclude every file in the tree.
        sc_count=$(cd "$provider_dir" && find . -name '*.sh' \
          -not -path '*/.terraform/*' -not -path '*/.claude/*' | wc -l | tr -d ' ')
        if [ "$sc_count" -gt 0 ]; then
          (cd "$provider_dir" && find . -name '*.sh' \
            -not -path '*/.terraform/*' -not -path '*/.claude/*' \
            -print0 | xargs -0 shellcheck -S "$SHELLCHECK_SEVERITY") || status=1
          echo "   shellcheck: $sc_count script(s) at -S $SHELLCHECK_SEVERITY"
        fi
        ;;
    esac
  else
    echo "   (shellcheck not installed, skipping script lint)"
  fi

  # Refresh the agent-facing schema dump. Local convenience only: the dump is
  # gitignored and CI has no agent to read it.
  if [ -n "$rel" ] && [ -z "${CI:-}" ]; then
    schema="$REPO_ROOT/agents/schema/$(echo "$rel" | tr '/' '-').schema.json"
    if [ ! -f "$schema" ] || [ "$dir/versions.tf" -nt "$schema" ] \
       || { [ -f "$dir/.terraform.lock.hcl" ] && [ "$dir/.terraform.lock.hcl" -nt "$schema" ]; }; then
      mkdir -p "$REPO_ROOT/agents/schema"
      (cd "$dir" && terraform providers schema -json) > "$schema.tmp" \
        && mv "$schema.tmp" "$schema" \
        && echo "   schema refreshed: agents/schema/$(basename "$schema")"
    fi
  fi
done

exit "$status"
