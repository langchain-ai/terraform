#!/usr/bin/env bash
# Regression checks for SSM failures and concurrent secret creation. Runs the
# complete setup script in an isolated shell with a fake AWS CLI and no credentials.
# Usage: bash modules/aws/infra/scripts/test-setup-env-ssm.sh [bash|zsh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SHELL="${1:-bash}"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/infra/scripts"
cp "$SCRIPT_DIR/setup-env.sh" "$TEST_TMP/infra/scripts/"
cat > "$TEST_TMP/infra/terraform.tfvars" <<'EOF'
name_prefix = "ssm-regression"
environment = "test"
region = "us-west-2"
EOF

cat > "$TEST_TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -eu
operation="$2"
shift 2
parameter="" json=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) parameter="$2"; shift 2 ;;
    --cli-input-json) json="${2#file://}"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$operation" == "put-parameter" ]]; then
  # A racing writer must not be overwritten, regardless of the earlier read.
  jq -e '.Overwrite == false' "$json" >/dev/null || exit 99
  echo write >> "$MOCK_LOG"
  case "$MOCK_MODE" in
    race)
      echo 'An error occurred (ParameterAlreadyExists) when calling PutParameter' >&2
      exit 254 ;;
    write-denied)
      echo 'An error occurred (AccessDeniedException) when calling PutParameter' >&2
      exit 254 ;;
  esac
  exit 0
fi
[[ "$operation" == "get-parameter" ]] || exit 99
if [[ "$parameter" == */"$MOCK_TARGET" ]]; then
  case "$MOCK_MODE" in
    missing|race|write-denied)
      echo 'An error occurred (ParameterNotFound) when calling GetParameter' >&2
      exit 254 ;;
    denied)
      echo 'An error occurred (AccessDeniedException) when calling GetParameter' >&2
      exit 254 ;;
    expired)
      echo 'The SSO session associated with this profile has expired' >&2
      exit 255 ;;
    credentials)
      echo 'Unable to locate credentials' >&2
      exit 253 ;;
    timeout)
      echo 'Connection timed out' >&2
      exit 124 ;;
    misleading)
      echo 'An error occurred (AccessDeniedException): ParameterNotFound is not permitted' >&2
      exit 254 ;;
  esac
fi
printf '%s\n' 'TestOnlyPassword123!'
EOF

cat > "$TEST_TMP/bin/openssl" <<'EOF'
#!/usr/bin/env bash
echo generate >> "$MOCK_LOG"
printf '%s\n' 'GeneratedTestPassword123!'
EOF

cat > "$TEST_TMP/run.sh" <<'EOF'
if [[ "$MOCK_PRESET" == true ]]; then
  export "$MOCK_VAR=ExportedTestPassword123!"
fi
result=0
source "$MOCK_ROOT/infra/scripts/setup-env.sh" || result=$?
if [[ "$MOCK_EXPECT" == failure ]]; then
  [[ $result -ne 0 ]] || exit 10
  # Only a deliberate environment override may remain on a failed setup.
  if [[ "$MOCK_PRESET" == false ]]; then
    ! printenv "$MOCK_VAR" >/dev/null || exit 11
  fi
else
  [[ $result -eq 0 ]] || exit 12
  actual=$(printenv "$MOCK_VAR")
  case "$MOCK_PRESET:$MOCK_LOCAL:$MOCK_MODE" in
    true:*) expected='ExportedTestPassword123!' ;;
    false:true:missing) expected='LocalTestPassword123!' ;;
    false:false:missing|false:false:write-denied) expected='GeneratedTestPassword123!' ;;
    *) expected='TestOnlyPassword123!' ;;
  esac
  [[ "$actual" == "$expected" ]] || exit 13
fi
EOF
chmod +x "$TEST_TMP/bin/aws" "$TEST_TMP/bin/openssl"

run_case() {
  local mode="$1" preset="$2" legacy="$3" expect="$4" writes="$5" generates="$6"
  local target="${7:-postgres-password}" varname="TF_VAR_postgres_password"
  [[ "$target" != langsmith-api-key-salt ]] || varname=TF_VAR_langsmith_api_key_salt
  rm -f "$TEST_TMP/infra/.pg_password"
  if [[ "$legacy" == true ]]; then
    printf '%s' 'LocalTestPassword123!' > "$TEST_TMP/infra/.pg_password"
  fi
  : > "$TEST_TMP/calls"
  # A clean environment prevents developer credentials or TF_VAR overrides
  # from hiding a regression or reaching the fake CLI.
  if ! env -i PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_TMP" \
    MOCK_ROOT="$TEST_TMP" MOCK_LOG="$TEST_TMP/calls" MOCK_MODE="$mode" \
    MOCK_PRESET="$preset" MOCK_LOCAL="$legacy" MOCK_EXPECT="$expect" \
    MOCK_TARGET="$target" MOCK_VAR="$varname" \
    "$TEST_SHELL" "$TEST_TMP/run.sh" > "$TEST_TMP/output" 2>&1; then
    echo "FAIL: $mode (preset=$preset, local=$legacy, target=$target)"
    cat "$TEST_TMP/output"
    exit 1
  fi
  local actual_writes actual_generates
  actual_writes=$(grep -c '^write$' "$TEST_TMP/calls" || true)
  actual_generates=$(grep -c '^generate$' "$TEST_TMP/calls" || true)
  if [[ "$actual_writes" != "$writes" || "$actual_generates" != "$generates" ]]; then
    echo "FAIL: $mode wrote $actual_writes and generated $actual_generates values"
    exit 1
  fi
  if [[ "$legacy" == true && "$(cat "$TEST_TMP/infra/.pg_password")" != LocalTestPassword123! ]]; then
    echo "FAIL: $mode changed the local backup"
    exit 1
  fi
  echo "PASS: $mode (preset=$preset, local=$legacy, target=$target)"
}

run_case found false false success 0 0
run_case found true false success 0 0
run_case found false true success 0 0
run_case missing false false success 1 1
run_case missing true false success 1 0
run_case missing false true success 1 0
for mode in denied expired credentials timeout misleading; do
  run_case "$mode" false false failure 0 0
done
run_case denied true false failure 0 0
run_case denied false true failure 0 0
run_case denied false false failure 0 0 langsmith-api-key-salt
run_case race false false failure 1 1
run_case race true false failure 1 0
run_case race false true failure 1 0
run_case write-denied false false success 1 1
