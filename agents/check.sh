#!/usr/bin/env bash
# Machine grading for HCL and shell edits. Enforced in CI by
# .github/workflows/checks.yaml, and run locally before handing back:
#   bash agents/check.sh                    # every root, plus every script
#   bash agents/check.sh modules/aws/infra  # one root, terraform only
#   bash agents/check.sh --scripts          # every tracked *.sh, no terraform
#
# Per root: terraform validate (init -backend=false, so no cloud creds or
# state) and tflint with the provider's pinned ruleset. Scripts are linted
# repo-wide, not per root. Exit non-zero on failure.
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Script linting gates at warning: the repo is clean at that bar, so holding it
# there prevents regression. tflint gates at error because the HCL still carries
# pre-existing warnings (unused variables, missing version constraints).
# CI sets neither -- it inherits these, so a green local run is a green PR.
SHELLCHECK_SEVERITY=${SHELLCHECK_SEVERITY:-warning}
TFLINT_SEVERITY=${TFLINT_SEVERITY:-error}

# Every tracked *.sh at one bar, whole repo, once. Not scoped per provider:
# the sweep takes about a second, and scoping it left the scripts outside a
# provider tree (agents/, .github/scripts/, modules/ocp/) with no cover at all.
# git ls-files rather than find, so ignored trees (.terraform/, a worktree under
# .claude/) drop out without an exclude list.
lint_scripts() {
  command -v shellcheck >/dev/null 2>&1 || {
    echo "   (shellcheck not installed, skipping script lint)"; return 0; }
  local count
  count=$(git -C "$REPO_ROOT" ls-files '*.sh' | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    echo "check: no *.sh tracked in git, so no script was linted" >&2
    return 2
  fi
  echo "== shellcheck $count script(s) at -S $SHELLCHECK_SEVERITY"
  (cd "$REPO_ROOT" && git ls-files -z '*.sh' \
    | xargs -0 shellcheck -S "$SHELLCHECK_SEVERITY")
}

init_upgrade=0
list_roots=0
case "${1:-}" in
  --init-upgrade) init_upgrade=1; shift ;;
  --list-roots) list_roots=1; shift ;;
  --scripts) lint_scripts; exit $? ;;
esac

# No args: every terraform root and every script. Roots are discovered rather
# than listed so a new one cannot be silently missed. Naming roots on the command
# line means terraform only -- use --scripts for the shell half.
# A root is any directory under modules/ with its own
# versions.tf, minus the internal child modules under
# modules/<provider>/<root>/modules/<child>/ -- those are validated transitively
# via --call-module-type=all, and two of them (azure keyvault, azure redis) do
# carry a versions.tf, so depth alone cannot tell them apart from a root.
# Depth genuinely varies: modules/aws/infra is two levels down,
# modules/byoc/aws/langsmith-byoc-role is three. modules/ocp has no versions.tf
# anywhere, so it is not covered.
lint_all=0
if [ $# -eq 0 ] || [ "$list_roots" -eq 1 ]; then
  discovered=()
  while IFS= read -r _versions; do
    [ -n "$_versions" ] || continue
    case "${_versions#modules/}" in */modules/*) continue ;; esac
    discovered+=("$REPO_ROOT/${_versions%/versions.tf}")
  done <<EOF
$(cd "$REPO_ROOT" && find modules -name versions.tf -not -path '*/.terraform/*' | sort)
EOF
  if [ ${#discovered[@]} -eq 0 ]; then
    echo "check: found no terraform roots under modules/" >&2
    exit 2
  fi
  # --list-roots keeps CI from re-implementing the rule above: the workflow
  # filters this list per provider instead of carrying its own glob.
  if [ "$list_roots" -eq 1 ]; then
    for _root in "${discovered[@]}"; do
      echo "${_root#"$REPO_ROOT/"}"
    done
    exit 0
  fi
  set -- "${discovered[@]}"
  lint_all=1
fi

# Provider dirs already handled, so tflint --init runs once per provider rather
# than per root. Space-delimited for bash 3.2 (no associative arrays).
tflint_inited=" "
status=0

for dir in "$@"; do
  case "$dir" in /*) ;; *) dir="$REPO_ROOT/$dir" ;; esac
  [ -d "$dir" ] || { echo "check: no such dir: $dir" >&2; status=2; continue; }

  # Resolve the owning provider dir. Everything provider-scoped (the tflint
  # config, the shell scripts) hangs off this.
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
done

if [ "$lint_all" -eq 1 ]; then
  lint_scripts || status=1
fi

exit "$status"
