#!/usr/bin/env bash
# Terraform plan tests, one provider per invocation:
#   bash agents/plan-tests.sh modules/azure
#
# terraform validate parses the HCL but resolves no conditionals. A module gated
# on a variable nothing ever sets validates clean, and so does one gated on the
# wrong variable. Until now the only thing that exercised that wiring was a full
# apply against a real subscription, which is why #170 and the Azure add-on gate
# both reached a customer.
#
# terraform test with mock_provider plans the real root module with no cloud
# credentials and no state, and assertions reach modules and resources directly,
# so a flag flip is checkable as length(module.waf). Provider schema validation
# still runs, so a generated value that the provider itself rejects fails here
# too.
#
# The root is copied to a temp directory before init, for two reasons. terraform
# test auto-loads terraform.tfvars, so a developer's own tfvars would otherwise
# decide the outcome and the suite would fail locally while passing in CI. And
# init in place would rewrite an initialized .terraform directory underneath
# whoever ran it.
#
# Exit 0 clean or nothing to run, 1 a failing test, 2 the suite could not run.
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)

# byoc is a standalone IAM root with no infra/ tree; ocp deploys onto a cluster
# it does not create and has no root module to plan. Skipped by name, not by an
# empty result: an empty result is also what a renamed directory looks like, and
# that must fail.
SKIP_PROVIDERS="byoc ocp"

# Providers are large (azurerm alone is over a gigabyte) and the repo commits no
# lock file, so without a cache every local run re-downloads them.
: "${TF_PLUGIN_CACHE_DIR:=$HOME/.terraform.d/plugin-cache}"
export TF_PLUGIN_CACHE_DIR

if [ $# -ne 1 ]; then
  echo "usage: bash agents/plan-tests.sh modules/<provider>" >&2
  exit 2
fi

arg=${1%/}
provider=$(basename "$arg")
PROVIDER_DIR="$REPO_ROOT/$arg"

if [ ! -d "$PROVIDER_DIR" ]; then
  echo "plan-tests: $arg is not a directory under the repo root." >&2
  exit 2
fi

case " $SKIP_PROVIDERS " in
  *" $provider "*)
    echo "plan-tests: $provider has no root module to plan, skipping."
    exit 0
    ;;
esac

INFRA="$PROVIDER_DIR/infra"
if [ ! -d "$INFRA" ]; then
  echo "plan-tests: $arg/infra is missing." >&2
  exit 2
fi

TESTS_REL="$arg/infra/tests"
if [ -z "$(find "$INFRA/tests" -name '*.tftest.hcl' -print 2>/dev/null)" ]; then
  echo "plan-tests: no *.tftest.hcl files in $TESTS_REL." >&2
  echo "plan-tests: every provider outside SKIP_PROVIDERS needs a suite, so this" >&2
  echo "            is a gap rather than a pass. Add one or name the provider in" >&2
  echo "            SKIP_PROVIDERS with the reason." >&2
  exit 2
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "plan-tests: terraform not installed, skipping $TESTS_REL."
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/plan-tests-$provider.XXXXXX") || {
  echo "plan-tests: could not create a temp directory." >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# *.tfvars is excluded so the suite reads only what its test files declare.
# .terraform is excluded because it is the initialized state of someone else's
# working directory, not input.
if ! tar -C "$INFRA" --exclude='.terraform' --exclude='*.tfvars' -cf - . \
   | tar -C "$WORK" -xf -; then
  echo "plan-tests: could not copy $arg/infra to a temp directory." >&2
  exit 2
fi

mkdir -p "$TF_PLUGIN_CACHE_DIR"

echo "plan-tests: $arg"
if ! (cd "$WORK" && terraform init -backend=false -input=false -no-color >/dev/null); then
  echo "plan-tests: terraform init failed in $arg/infra." >&2
  exit 2
fi

if ! (cd "$WORK" && terraform test -no-color); then
  echo "" >&2
  echo "plan-tests: failing tests in $TESTS_REL" >&2
  exit 1
fi
exit 0
