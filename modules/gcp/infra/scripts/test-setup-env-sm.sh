#!/usr/bin/env bash
# Exercise setup in a fresh shell with fake cloud/storage tools and no credentials.
# Protect cloud precedence, create-only persistence, and failure before export.
# Usage: bash modules/gcp/infra/scripts/test-setup-env-sm.sh [bash|zsh]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SHELL="${1:-bash}"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/infra/scripts" "$TEST_TMP/store"
cp "$SCRIPT_DIR/setup-env.sh" "$TEST_TMP/infra/scripts/"
cat > "$TEST_TMP/infra/terraform.tfvars" <<'EOF'
project_id = "secret-regression"
name_prefix = "sm-regression"
environment = "test"
enable_sandboxes = true
enable_sso_oidc = true
EOF
cat > "$TEST_TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "$1" == secrets ]] || exit 99
shift
operation="$1"
shift
if [[ "$operation" == versions ]]; then
  [[ "$1" == access && "$2" == latest ]] || exit 99
  operation=access
  shift 2
fi
secret="" data=false
for arg in "$@"; do
  case "$arg" in
    --secret=*) secret="${arg#*=}" ;;
    --data-file=-) data=true ;;
    --*) ;;
    *) secret="$arg" ;;
  esac
done
[[ -n "$secret" ]] || exit 99
if [[ "$operation" == create ]]; then
  [[ "$data" == true ]] || exit 99
  echo write >> "$MOCK_LOG"
  case "$MOCK_MODE" in
    race|write-denied) exit 1 ;;
  esac
  [[ ! -e "$MOCK_STORE/$secret" ]] || exit 99
  cat > "$MOCK_STORE/$secret"
  exit 0
fi
if [[ "$MOCK_MODE" == roundtrip ]]; then
  if [[ -f "$MOCK_STORE/$secret" ]]; then
    [[ "$operation" != access ]] || cat "$MOCK_STORE/$secret"
    exit 0
  fi
  echo "ERROR: (gcloud.secrets.versions.$operation) NOT_FOUND: Secret not found" >&2
  [[ "$operation" != describe ]] || echo 'ERROR: (gcloud.secrets.describe) NOT_FOUND: Secret not found' >&2
  exit 1
fi
if [[ "$secret" == *-"$MOCK_TARGET" ]]; then
  case "$MOCK_MODE" in
    missing|race|write-denied|version-missing|describe-denied)
      if [[ "$operation" == describe ]]; then
        [[ "$MOCK_MODE" != version-missing ]] || exit 0
        if [[ "$MOCK_MODE" == describe-denied ]]; then
          echo 'ERROR: (gcloud.secrets.describe) PERMISSION_DENIED: Access denied' >&2
          exit 1
        fi
        echo 'ERROR: (gcloud.secrets.describe) NOT_FOUND: Secret not found' >&2
      else
        echo 'ERROR: (gcloud.secrets.versions.access) NOT_FOUND: Secret not found or has no versions' >&2
      fi
      exit 1 ;;
    denied|misleading)
      echo 'ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: NOT_FOUND mentioned in policy' >&2
      exit 1 ;;
    expired) echo 'ERROR: Reauthentication required' >&2; exit 1 ;;
    disabled) echo 'ERROR: SERVICE_DISABLED: Secret Manager API has not been used in project' >&2; exit 1 ;;
    timeout) exit 124 ;;
    version-disabled) echo 'ERROR: FAILED_PRECONDITION: version is DISABLED' >&2; exit 1 ;;
    empty) exit 0 ;;
    invalid) printf '%s' 'invalid'; exit 0 ;;
  esac
fi
printf '%s' 'TestOnlyPassword123!'
EOF
cat > "$TEST_TMP/bin/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" != rand ]]; then
  while [[ $# -gt 1 && "$1" != -out ]]; do shift; done
  [[ $# -gt 1 ]] || exit 99
  printf '%032d' 0 > "$2"
  exit 0
fi
echo generate >> "$MOCK_LOG"
printf '%s' 'GeneratedTestPassword123!'
EOF
cat > "$TEST_TMP/run.sh" <<'EOF'
case "$MOCK_PRESET" in
  different) export "$MOCK_VAR=ShellTestPassword123!" ;;
  same) export "$MOCK_VAR=TestOnlyPassword123!" ;;
esac
if [[ "$MOCK_MODE" == roundtrip && "$MOCK_STAGE" == create ]]; then
  export TF_VAR_postgres_password='TestOnlyPassword123!'
  export TF_VAR_langsmith_license_key='TestOnlyPassword123!'
  export TF_VAR_langsmith_admin_password='TestOnlyPassword123!'
  export TF_VAR_langsmith_oauth_client_id='TestOnlyPassword123!'
  export TF_VAR_langsmith_oauth_client_secret='TestOnlyPassword123!'
  export TF_VAR_langsmith_oauth_issuer_url='https://example.invalid'
fi
result=0
source "$MOCK_ROOT/infra/scripts/setup-env.sh" || result=$?
if [[ "$MOCK_EXPECT" == failure ]]; then
  [[ $result -ne 0 ]] || exit 10
  [[ "$MOCK_PRESET" != unset ]] || ! printenv "$MOCK_VAR" >/dev/null || exit 11
else
  [[ $result -eq 0 ]] || exit 12
  case "$MOCK_MODE:$MOCK_PRESET" in
    missing:unset|roundtrip:*) expected='GeneratedTestPassword123!' ;;
    missing:different) expected='ShellTestPassword123!' ;;
    *) expected='TestOnlyPassword123!' ;;
  esac
  [[ "$(printenv "$MOCK_VAR")" == "$expected" ]] || exit 13
fi
EOF
chmod +x "$TEST_TMP/bin/gcloud" "$TEST_TMP/bin/openssl"

run_case() {
  local mode="$1" preset="$2" expect="$3" writes="$4" generates="$5"
  local target="${6:-api-key-salt}" varname=TF_VAR_langsmith_api_key_salt
  [[ "$target" != admin-password ]] || varname=TF_VAR_langsmith_admin_password
  : > "$TEST_TMP/calls"
  rm -f "$TEST_TMP/store/"*
  if ! env -i PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_TMP" \
    MOCK_ROOT="$TEST_TMP" MOCK_LOG="$TEST_TMP/calls" MOCK_MODE="$mode" \
    MOCK_PRESET="$preset" MOCK_EXPECT="$expect" MOCK_TARGET="$target" \
    MOCK_VAR="$varname" MOCK_STORE="$TEST_TMP/store" \
    "$TEST_SHELL" "$TEST_TMP/run.sh" > "$TEST_TMP/output" 2>&1; then
    echo "FAIL: $mode (shell=$preset, target=$target)"
    cat "$TEST_TMP/output"
    exit 1
  fi
  [[ "$(grep -c '^write$' "$TEST_TMP/calls" || true)" == "$writes" ]] || { echo "FAIL: $mode writes"; exit 1; }
  [[ "$(grep -c '^generate$' "$TEST_TMP/calls" || true)" == "$generates" ]] || { echo "FAIL: $mode generates"; exit 1; }
  if grep -qE '(TestOnly|ShellTest|GeneratedTest)Password123!' "$TEST_TMP/output"; then
    echo "FAIL: credential exposed in output"; exit 1
  fi
  echo "PASS: $mode (shell=$preset, target=$target)"
}
run_case found unset success 0 0
run_case found same success 0 0
run_case found different failure 0 0
run_case missing unset success 1 1
run_case missing different success 1 0
for mode in denied expired disabled timeout misleading version-missing version-disabled describe-denied empty; do
  run_case "$mode" unset failure 0 0
  run_case "$mode" different failure 0 0
done
for mode in race write-denied; do
  run_case "$mode" unset failure 1 1
  run_case "$mode" different failure 1 0
done
run_case invalid unset failure 0 0 admin-password
run_case missing unset failure 0 0 admin-password

# A second shell must recover every enabled feature's credentials from the cloud.
rm -f "$TEST_TMP/store/"*
for stage in create read; do
  : > "$TEST_TMP/calls"
  if ! env -i PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_TMP" \
    MOCK_MODE=roundtrip MOCK_STAGE="$stage" MOCK_ROOT="$TEST_TMP" \
    MOCK_STORE="$TEST_TMP/store" MOCK_LOG="$TEST_TMP/calls" MOCK_PRESET=unset \
    MOCK_EXPECT=success MOCK_VAR=TF_VAR_langsmith_api_key_salt \
    "$TEST_SHELL" "$TEST_TMP/run.sh" > "$TEST_TMP/output" 2>&1; then
    echo "FAIL: all-secret $stage"; cat "$TEST_TMP/output"; exit 1
  fi
  if [[ "$stage" == create ]]; then
    cp -R "$TEST_TMP/store" "$TEST_TMP/snapshot"
  else
    diff -r "$TEST_TMP/snapshot" "$TEST_TMP/store" >/dev/null
    [[ ! -s "$TEST_TMP/calls" ]] || { echo 'FAIL: rerun changed cloud credentials'; exit 1; }
  fi
  [[ "$(find "$TEST_TMP/infra" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 1 ]] || { echo 'FAIL: local password backup created'; exit 1; }
  echo "PASS: all-secret $stage"
done
