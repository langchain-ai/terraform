#!/usr/bin/env bash
# Regression checks for secret precedence, persistence, and failures. Runs the
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
enable_sandboxes = true
EOF

cat > "$TEST_TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -eu
operation="$2"
shift 2
parameter="" json="" query="" decrypt=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) parameter="$2"; shift 2 ;;
    --cli-input-json) json="${2#file://}"; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    --with-decryption) decrypt=true; shift ;;
    *) shift ;;
  esac
done
if [[ "$operation" == "put-parameter" ]]; then
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
  parameter=$(jq -r '.Name' "$json")
  jq -r '.Value' "$json" > "$MOCK_STORE/${parameter##*/}"
  exit 0
fi
[[ "$operation" == "get-parameter" && "$query" == Parameter.Value && "$decrypt" == true ]] || exit 99
if [[ "$MOCK_MODE" == roundtrip ]]; then
  if [[ -f "$MOCK_STORE/${parameter##*/}" ]]; then
    cat "$MOCK_STORE/${parameter##*/}"
    exit 0
  fi
  echo 'An error occurred (ParameterNotFound) when calling GetParameter' >&2
  exit 254
fi
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
if [[ "$1" != rand ]]; then
  exec "$REAL_OPENSSL" "$@"
fi
echo generate >> "$MOCK_LOG"
printf '%s\n' 'GeneratedTestPassword123!'
EOF

cat > "$TEST_TMP/run.sh" <<'EOF'
case "$MOCK_PRESET" in
  true) export "$MOCK_VAR=ExportedTestPassword123!" ;;
  same) export "$MOCK_VAR=TestOnlyPassword123!" ;;
esac
if [[ "$MOCK_MODE" == roundtrip && "$MOCK_STAGE" == create ]]; then
  export LANGSMITH_LICENSE_KEY='TestOnlyPassword123!'
  export LANGSMITH_ADMIN_PASSWORD='TestOnlyPassword123!'
  export LANGSMITH_ADMIN_EMAIL='admin@example.invalid'
fi
result=0
source "$MOCK_ROOT/infra/scripts/setup-env.sh" || result=$?
if [[ "$MOCK_EXPECT" == failure ]]; then
  [[ $result -ne 0 ]] || exit 10
  if [[ "$MOCK_PRESET" == false ]]; then
    ! printenv "$MOCK_VAR" >/dev/null || exit 11
  fi
else
  [[ $result -eq 0 ]] || exit 12
  actual=$(printenv "$MOCK_VAR")
  case "$MOCK_PRESET:$MOCK_LOCAL:$MOCK_MODE" in
    false:true:missing) expected='LocalTestPassword123!' ;;
    true:false:missing) expected='ExportedTestPassword123!' ;;
    false:false:missing|false:false:roundtrip) expected='GeneratedTestPassword123!' ;;
    *) expected='TestOnlyPassword123!' ;;
  esac
  [[ "$actual" == "$expected" ]] || exit 13
  [[ "$(cat "$MOCK_FILE")" == "$expected" ]] || exit 14
  [[ "$(ls -l "$MOCK_FILE" | cut -c 1-10)" == -rw------- ]] || exit 15
fi
EOF
chmod +x "$TEST_TMP/bin/aws" "$TEST_TMP/bin/openssl"

# Args: SSM mode, shell (false=unset, same=matches SSM, true=different), local
# copy present, expected result, write count, generation count, optional SSM key.
run_case() {
  local mode="$1" preset="$2" legacy="$3" expect="$4" writes="$5" generates="$6"
  local target="${7:-postgres-password}" varname="TF_VAR_postgres_password"
  [[ "$target" != langsmith-api-key-salt ]] || varname=TF_VAR_langsmith_api_key_salt
  local file="$TEST_TMP/infra/.pg_password"
  [[ "$target" != langsmith-api-key-salt ]] || file="$TEST_TMP/infra/.api_key_salt"
  rm -rf "$TEST_TMP/infra/".[!.]* "$TEST_TMP/store"
  mkdir "$TEST_TMP/store"
  if [[ "$legacy" == true ]]; then
    printf '%s' 'LocalTestPassword123!' > "$file"
  fi
  if [[ "$mode" == local-failed ]]; then
    mkdir "$file"
  fi
  : > "$TEST_TMP/calls"
  # A clean environment prevents developer credentials or TF_VAR overrides
  # from hiding a regression or reaching the fake CLI.
  if ! env -i PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_TMP" \
    MOCK_ROOT="$TEST_TMP" MOCK_LOG="$TEST_TMP/calls" MOCK_MODE="$mode" \
    MOCK_PRESET="$preset" MOCK_LOCAL="$legacy" MOCK_EXPECT="$expect" \
    MOCK_TARGET="$target" MOCK_VAR="$varname" MOCK_FILE="$file" MOCK_STORE="$TEST_TMP/store" \
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
  if [[ "$expect" == failure && "$legacy" == true && "$(cat "$file")" != LocalTestPassword123! ]]; then
    echo "FAIL: $mode changed the local backup"
    exit 1
  fi
  if grep -qE '(TestOnly|ExportedTest|LocalTest|GeneratedTest)Password123!' "$TEST_TMP/output"; then
    echo "FAIL: $mode exposed a credential in output"
    exit 1
  fi
  echo "PASS: $mode (preset=$preset, local=$legacy, target=$target)"
}

run_case found false false success 0 0
run_case found same false success 0 0
run_case found false true success 0 0
run_case found same true success 0 0
run_case found true false failure 0 0
run_case found true true failure 0 0
run_case missing false false success 1 1
run_case missing true false success 1 0
run_case missing false true success 1 0
run_case missing true true failure 0 0
for mode in denied expired credentials timeout misleading; do
  run_case "$mode" false false failure 0 0
  run_case "$mode" true true failure 0 0
done
run_case denied false false failure 0 0 langsmith-api-key-salt
for mode in race write-denied; do
  run_case "$mode" false false failure 1 1
  run_case "$mode" true false failure 1 0
  run_case "$mode" false true failure 1 0
done
run_case local-failed false false failure 0 0

# Exercise every enabled secret through creation, SSM reads, and local import.
rm -rf "$TEST_TMP/infra/".[!.]* "$TEST_TMP/store"
mkdir "$TEST_TMP/store"
for stage in create read import; do
  if [[ "$stage" == import ]]; then
    rm -f "$TEST_TMP/store/"*
  fi
  : > "$TEST_TMP/calls"
  if ! env -i PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_TMP" \
    REAL_OPENSSL="$(command -v openssl)" MOCK_MODE=roundtrip MOCK_STAGE="$stage" \
    MOCK_ROOT="$TEST_TMP" MOCK_STORE="$TEST_TMP/store" MOCK_LOG="$TEST_TMP/calls" \
    MOCK_PRESET=false MOCK_LOCAL=false MOCK_EXPECT=success \
    MOCK_VAR=TF_VAR_postgres_password MOCK_FILE="$TEST_TMP/infra/.pg_password" \
    "$TEST_SHELL" "$TEST_TMP/run.sh" > "$TEST_TMP/output" 2>&1; then
    echo "FAIL: all-secret $stage"
    cat "$TEST_TMP/output"
    exit 1
  fi
  if [[ "$stage" == create ]]; then
    cp -R "$TEST_TMP/infra" "$TEST_TMP/snapshot"
  else
    diff -r "$TEST_TMP/snapshot" "$TEST_TMP/infra" >/dev/null
    ! grep -q '^generate$' "$TEST_TMP/calls"
    [[ "$stage" != read ]] || ! grep -q '^write$' "$TEST_TMP/calls"
  fi
  local_count=$(find "$TEST_TMP/infra" -maxdepth 1 -type f -name '.*' | wc -l | tr -d ' ')
  ssm_count=$(find "$TEST_TMP/store" -type f | wc -l | tr -d ' ')
  [[ "$local_count" == "$ssm_count" ]] || { echo "FAIL: not every SSM secret has a local copy"; exit 1; }
  echo "PASS: all-secret $stage ($ssm_count parameters)"
done
