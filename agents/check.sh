#!/usr/bin/env bash
# Machine grading for HCL and shell edits. Enforced in CI by
# .github/workflows/checks.yaml, and run locally before handing back:
#   bash agents/check.sh                    # fmt repo-wide, every root, every script
#   bash agents/check.sh modules/aws        # fmt and the roots under one dir, terraform only
#   bash agents/check.sh --scripts          # every tracked *.sh, no terraform
#   bash agents/check.sh --fmt modules/ocp  # fmt only (repo-wide with no dir)
#
# terraform fmt -check first, over the named dirs (the whole repo with no
# argument). Per root: terraform validate (init -backend=false, so no cloud
# creds or state) and tflint with the provider's pinned ruleset. Scripts are
# linted repo-wide rather than per root, so naming a directory checks terraform
# only.
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

# terraform fmt -check over repo-relative dirs. Unlike validate it needs no root,
# so --fmt reaches HCL that has none (modules/ocp), which is how CI covers it.
# fmt skips hidden dirs, so .terraform/ and .claude/ drop out on their own, but
# it does read gitignored files: a generated terraform.tfvars or a local
# backend_override.tf never reaches CI, so a finding in one is dropped here
# instead of failing a run that CI would pass.
fmt_check() {
  local out rc file bad=0
  echo "== terraform fmt -check $*"
  out=$(cd "$REPO_ROOT" && terraform fmt -recursive -check -no-color "$@")
  rc=$?
  case "$rc" in
    0) return 0 ;;
    3) ;;  # unformatted files, listed one per line on stdout
    *) return 1 ;;  # parse error, reported on stderr
  esac
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    git -C "$REPO_ROOT" check-ignore -q -- "$file" && continue
    echo "   not formatted: $file"
    bad=1
  done <<EOF
$out
EOF
  if [ "$bad" -eq 1 ]; then
    echo "   fix with: terraform fmt -recursive <dir>"
    return 1
  fi
}

# Print the terraform roots at or beneath one repo-relative directory. Roots are
# discovered rather than listed so a new one cannot be silently missed, and so a
# CI leg can scope itself to modules/<provider> without carrying a second copy
# of the rule. A root is any directory with its own versions.tf, minus the
# internal child modules under modules/<provider>/<root>/modules/<child>/:
# those are validated transitively via --call-module-type=all, and four of them
# (azure keyvault, redis, k8s-cluster, smithdb) do carry a versions.tf, so depth
# alone cannot tell them apart from a root. Depth varies anyway,
# modules/aws/infra is two levels down and modules/byoc/aws/langsmith-byoc-role
# is three.
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
esac

# CI installs the Terraform pinned in .terraform-version. A different local
# binary can format or validate differently, so say so rather than fail: the
# run is still useful, it just stops being a promise about CI.
tf_pin=$(tr -d '[:space:]' < "$REPO_ROOT/.terraform-version")
tf_have=$(terraform version | sed -n '1s/^Terraform v//p')
if [ "$tf_have" != "$tf_pin" ]; then
  echo "check: local terraform is $tf_have but CI pins $tf_pin (.terraform-version);" >&2
  echo "       fmt and validate results may differ from the PR's" >&2
fi

# --fmt stops after the fmt check, so it skips root discovery too: a dir with no
# root is exactly what it is for.
fmt_only=0
if [ "${1:-}" = --fmt ]; then
  fmt_only=1
  shift
fi

lint_all=0
if [ $# -eq 0 ]; then
  set -- modules
  lint_all=1
fi

# Expand each named directory into the roots beneath it. An empty expansion
# fails rather than passing quietly: a CI leg scoped to one provider would
# otherwise report success having checked nothing.
roots=()
fmt_dirs=()
for arg in "$@"; do
  arg=${arg#"$REPO_ROOT/"}
  arg=${arg%/}
  if [ ! -d "$REPO_ROOT/$arg" ]; then
    echo "check: no such dir: $arg" >&2
    exit 2
  fi
  fmt_dirs+=("$arg")
  [ "$fmt_only" -eq 0 ] || continue
  before=${#roots[@]}
  while IFS= read -r _root; do
    [ -n "$_root" ] || continue
    roots+=("$_root")
  done <<EOF
$(discover_roots "$arg")
EOF
  if [ "${#roots[@]}" -eq "$before" ]; then
    echo "check: no terraform root under $arg. A root has its own versions.tf; child" >&2
    echo "modules (modules/*/infra/modules/*) are checked via their parent root." >&2
    exit 2
  fi
done

# Provider dirs already handled, so tflint --init runs once per provider rather
# than per root. Space-delimited for bash 3.2 (no associative arrays).
tflint_inited=" "
status=0

# No argument checks formatting from the repo root, so HCL outside every root
# is covered too; a named dir checks only that dir.
if [ "$lint_all" -eq 1 ]; then
  fmt_dirs=(.)
fi
fmt_check "${fmt_dirs[@]}" || status=1
if [ "$fmt_only" -eq 1 ]; then
  exit "$status"
fi

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
fi

exit "$status"
