#!/usr/bin/env bash
# Machine grading for HCL and shell edits. Enforced in CI by
# .github/workflows/checks.yaml, and run locally before handing back:
#   bash agents/check.sh                    # every root, every script, tfvars docs
#   bash agents/check.sh modules/aws        # the roots under one dir, terraform only
#   bash agents/check.sh --scripts          # every tracked *.sh, no terraform
#   bash agents/check.sh --tfvars           # every variable is documented, no terraform
#
# Per root: terraform validate (init -backend=false, so no cloud creds or
# state) and tflint with the provider's pinned ruleset. Scripts and tfvars docs
# are checked repo-wide rather than per root, so naming a directory checks
# terraform only.
#
# set -u, deliberately without -e: a failing root records a non-zero status and
# the loop continues, so one broken root still reports on the rest.
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Script linting gates at warning: the repo is clean at that bar, so holding it
# there prevents regression. tflint gates at error because the HCL still carries
# pre-existing warnings (unused variables, missing version constraints).
# CI sets neither, it inherits these, so a green local run is a green PR.
SHELLCHECK_SEVERITY=${SHELLCHECK_SEVERITY:-warning}
TFLINT_SEVERITY=${TFLINT_SEVERITY:-error}
# Variables knowingly absent from a terraform.tfvars.example: the app-root
# inputs that make init-app writes from infra outputs, plus documentation debt
# predating the gate. Both live in one file because the gate only cares whether
# an entry is expected, not why it is there.
TFVARS_BASELINE=${TFVARS_BASELINE:-$REPO_ROOT/agents/tfvars-doc-baseline.txt}

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

# Every variable a root declares has to be mentioned in that root's
# terraform.tfvars.example. Without this, adding a variable and documenting
# nothing passes fmt, validate, tflint and shellcheck: the option ships working
# but undiscoverable, and the customer copying the template never learns it
# exists. A mention anywhere in the file counts, including commented out or in
# prose, since most options are documented as "uncomment to enable".
#
# Roots are the directories that ship a terraform.tfvars.example, discovered
# from git rather than listed, so a new root is covered the day it lands.
# The other profiles (.production, .dev, .minimum) are curated subsets and are
# deliberately not held to this bar.
check_tfvars_docs() {
  local example root var undocumented="" baseline new stale rc=0 count=0

  while IFS= read -r example; do
    [ -n "$example" ] || continue
    root=${example%/terraform.tfvars.example}
    count=$((count + 1))
    while IFS= read -r var; do
      [ -n "$var" ] || continue
      grep -qE "(^|[^A-Za-z0-9_])${var}([^A-Za-z0-9_]|\$)" \
        "$REPO_ROOT/$example" && continue
      undocumented="${undocumented}${root} ${var}
"
    done <<EOF
$(grep -h '^variable "' "$REPO_ROOT/$root"/*.tf 2>/dev/null \
  | sed 's/^variable "//; s/".*//' | sort -u)
EOF
  done <<EOF
$(cd "$REPO_ROOT" && git ls-files '*/terraform.tfvars.example')
EOF

  # Same guard as the root expansion: an empty sweep fails rather than passing
  # having checked nothing.
  if [ "$count" -eq 0 ]; then
    echo "check: no terraform.tfvars.example tracked in git, so no root was" >&2
    echo "checked for undocumented variables." >&2
    return 2
  fi

  echo "== tfvars docs: $count root(s) with a terraform.tfvars.example"

  undocumented=$(printf '%s' "$undocumented" | sort -u)
  baseline=$(grep -vE '^[[:space:]]*(#|$)' "$TFVARS_BASELINE" 2>/dev/null | sort -u)

  # Both directions. Only checking for new entries would let the baseline cover
  # variables that have since been documented or deleted, and it would never
  # shrink.
  new=$(printf '%s\n' "$undocumented" | grep -v '^$' \
    | grep -Fxv -f <(printf '%s\n' "$baseline"))
  stale=$(printf '%s\n' "$baseline" | grep -v '^$' \
    | grep -Fxv -f <(printf '%s\n' "$undocumented"))

  if [ -n "$new" ]; then
    echo "check: declared but absent from the root's terraform.tfvars.example," >&2
    echo "so a customer copying the template cannot discover it:" >&2
    printf '%s\n' "$new" | sed 's/^/   /' >&2
    echo "Document each one, or add it to ${TFVARS_BASELINE#"$REPO_ROOT/"}." >&2
    rc=1
  fi

  if [ -n "$stale" ]; then
    echo "check: baseline entr(ies) that are no longer undocumented -- the" >&2
    echo "variable is either documented now or gone. Delete these lines from" >&2
    echo "${TFVARS_BASELINE#"$REPO_ROOT/"}:" >&2
    printf '%s\n' "$stale" | sed 's/^/   /' >&2
    rc=1
  fi

  return "$rc"
}

# Print the terraform roots at or beneath one repo-relative directory. Roots are
# discovered rather than listed so a new one cannot be silently missed, and so a
# CI leg can scope itself to modules/<provider> without carrying a second copy
# of the rule. A root is any directory with its own versions.tf, minus the
# internal child modules under modules/<provider>/<root>/modules/<child>/:
# those are validated transitively via --call-module-type=all, and two of them
# (azure keyvault, azure redis) do carry a versions.tf, so depth alone cannot
# tell them apart from a root. Depth varies anyway, modules/aws/infra is two
# levels down and modules/byoc/aws/langsmith-byoc-role is three.
discover_roots() {
  local versions
  while IFS= read -r versions; do
    versions=${versions#./}
    [ -n "$versions" ] || continue
    case "${versions#modules/}" in */modules/*) continue ;; esac
    echo "${versions%/versions.tf}"
  done <<EOF
$(cd "$REPO_ROOT" && find "$1" -name versions.tf -not -path '*/.terraform/*' | sort)
EOF
}

case "${1:-}" in
  --scripts) lint_scripts; exit $? ;;
  --tfvars)  check_tfvars_docs; exit $? ;;
esac

lint_all=0
if [ $# -eq 0 ]; then
  set -- modules
  lint_all=1
fi

# Expand each named directory into the roots beneath it. An empty expansion
# fails rather than passing quietly: a CI leg scoped to one provider would
# otherwise report success having checked nothing.
roots=()
for arg in "$@"; do
  arg=${arg#"$REPO_ROOT/"}
  arg=${arg%/}
  if [ ! -d "$REPO_ROOT/$arg" ]; then
    echo "check: no such dir: $arg" >&2
    exit 2
  fi
  before=${#roots[@]}
  while IFS= read -r _root; do
    [ -n "$_root" ] || continue
    roots+=("$_root")
  done <<EOF
$(discover_roots "$arg")
EOF
  if [ "${#roots[@]}" -eq "$before" ]; then
    echo "check: no terraform root under $arg, so this run would have checked" >&2
    echo "nothing. The directory was renamed, or its versions.tf is gone." >&2
    exit 2
  fi
done

# Provider dirs already handled, so tflint --init runs once per provider rather
# than per root. Space-delimited for bash 3.2 (no associative arrays).
tflint_inited=" "
status=0

for rel in "${roots[@]}"; do
  dir="$REPO_ROOT/$rel"
  # Everything provider-scoped (the tflint config) hangs off the provider dir.
  provider=${rel#modules/}
  provider=${provider%%/*}
  provider_dir="$REPO_ROOT/modules/$provider"

  echo "== check $rel"

  if [ ! -d "$dir/.terraform" ]; then
    (cd "$dir" && terraform init -backend=false -input=false -no-color) || {
      status=1; continue; }
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
  check_tfvars_docs || status=1
fi

exit "$status"
