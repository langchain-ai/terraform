#!/usr/bin/env bash
# Exercise the wizard's generated tfvars with no cloud resources or state.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gcloud" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'config get-value project' ]] || exit 2
echo langsmith-fixture
MOCK
chmod +x "$TEST_DIR/bin/gcloud"
export PATH="$TEST_DIR/bin:$PATH"
export LANGSMITH_ADMIN_EMAIL=fixture@example.invalid
for mode in network local-ssd; do
  mkdir "$TEST_DIR/$mode"
  export INFRA_DIR="$TEST_DIR/$mode"
  {
    # Dev, default identity and nodes, in-cluster backends/ClickHouse, no TLS.
    printf '1\n\n\n\n\n\n\n\n\n\n\n\n\n2\n1\n3\ny\n2\n'
    if [[ "$mode" == network ]]; then
      # Use a custom shape/counts, including a rejected max below the minimum.
      printf '1\nc3-standard-44\n0\n3\n2\n7\n'
    else
      printf '2\n'
    fi
  } | bash "$SCRIPT_DIR/quickstart.sh" > "$TEST_DIR/$mode.log" 2>&1
  source "$SCRIPT_DIR/_common.sh"
  [[ "$(_parse_tfvar enable_smithdb)" == true ]]
  [[ "$(_parse_tfvar smithdb_sizing)" == small ]]
  if [[ "$mode" == network ]]; then
    [[ "$(_parse_tfvar smithdb_cache_storage)" == network-disk ]]
    [[ "$(_parse_tfvar smithdb_node_machine_type)" == c3-standard-44 ]]
    [[ "$(_parse_tfvar smithdb_node_min_count)" == 3 ]]
    [[ "$(_parse_tfvar smithdb_node_max_count)" == 7 ]]
    grep -q 'Minimum must be at least 1' "$TEST_DIR/$mode.log"
    grep -q 'Maximum must be at least the minimum' "$TEST_DIR/$mode.log"
  else
    [[ "$(_parse_tfvar smithdb_cache_storage)" == local-ssd ]]
    [[ -z "$(_parse_tfvar smithdb_node_machine_type)" ]]
  fi
  if command -v terraform >/dev/null 2>&1; then
    terraform fmt -write=false "$INFRA_DIR/terraform.tfvars" >/dev/null
  fi
  echo "PASS: QuickStart $mode generates usable SmithDB tfvars"
done
