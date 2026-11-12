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
for scenario in small medium local-ssd disabled standby active older autopilot; do
  mkdir "$TEST_DIR/$scenario"
  export INFRA_DIR="$TEST_DIR/$scenario"
  case "$scenario" in
    older) printf 'project_id = "langsmith-fixture"\n' > "$INFRA_DIR/terraform.tfvars" ;;
    disabled|standby|active)
      _enabled=true; _ingestion=false; _migration=false; _query=false
      [[ "$scenario" != disabled ]] || _enabled=false
      if [[ "$scenario" == active ]]; then _ingestion=true; _migration=true; _query=true; fi
      cat > "$INFRA_DIR/terraform.tfvars" <<VALUES
enable_smithdb = $_enabled
smithdb_ingestion_enabled = $_ingestion
smithdb_migration_enabled = $_migration
smithdb_query_enabled = $_query
smithdb_sizing = "large"
smithdb_cache_storage = "local-ssd"
smithdb_node_machine_type = "c3-standard-44"
smithdb_node_min_count = 3
smithdb_node_max_count = 7
smithdb_transition_mode = true
smithdb_instance_store_local_ssd_count = 8
smithdb_metastore_deletion_protection = true
smithdb_bucket_force_destroy = false
smithdb_node_locations = [
  "us-west2-a",
  "us-west2-b",
]
sizing_profile = "production-large"
VALUES
      ;;
  esac
  {
    case "$scenario" in disabled|standby|active|older) printf 'y\n' ;; esac
    if [[ "$scenario" == autopilot ]]; then
      # Production with Autopilot, in-cluster backends, no TLS or addons.
      printf '2\n\n\n\n\n\n\n\n\ny\nn\nn\n1\n3\nn\nn\n\n\n'
    else
      # Dev, default identity/nodes, in-cluster backends/ClickHouse, no TLS.
      printf '1\n\n\n\n\n\n\n\n\n\n\n\n\n2\n1\n3\n'
      case "$scenario" in
        small) printf '2\n1\n0\n3\n2\n7\n' ;;
        medium) printf '3\n1\n\n\n' ;;
        local-ssd) printf '2\n2\n' ;;
      esac
    fi
  } | bash "$SCRIPT_DIR/quickstart.sh" > "$TEST_DIR/$scenario.log" 2>&1
  source "$SCRIPT_DIR/_common.sh"
  case "$scenario" in
    small|medium|local-ssd)
      [[ "$(_parse_tfvar enable_smithdb)" == true ]]
      [[ "$(_parse_tfvar smithdb_ingestion_enabled)" == true ]]
      [[ "$(_parse_tfvar smithdb_migration_enabled)" == false ]]
      [[ "$(_parse_tfvar smithdb_query_enabled)" == false ]]
      [[ -z "$(_parse_tfvar smithdb_node_machine_type)" ]]
      if [[ "$scenario" == local-ssd ]]; then
        [[ "$(_parse_tfvar smithdb_cache_storage)" == local-ssd ]]
      else
        [[ "$(_parse_tfvar smithdb_cache_storage)" == network-disk ]]
        if [[ "$scenario" == small ]]; then
          [[ "$(_parse_tfvar smithdb_node_min_count)" == 3 ]]
          [[ "$(_parse_tfvar smithdb_node_max_count)" == 7 ]]
          grep -q 'Minimum must be at least 1' "$TEST_DIR/$scenario.log"
          grep -q 'Maximum must be at least the minimum' "$TEST_DIR/$scenario.log"
        else
          [[ "$(_parse_tfvar smithdb_sizing)" == medium ]]
          [[ "$(_parse_tfvar smithdb_node_max_count)" == 10 ]]
        fi
      fi
      ;;
    disabled|standby|active)
      [[ "$(_parse_tfvar enable_smithdb)" == "$_enabled" ]]
      [[ "$(_parse_tfvar smithdb_ingestion_enabled)" == "$_ingestion" ]]
      [[ "$(_parse_tfvar smithdb_migration_enabled)" == "$_migration" ]]
      [[ "$(_parse_tfvar smithdb_query_enabled)" == "$_query" ]]
      [[ "$(_parse_tfvar smithdb_sizing)" == large ]]
      [[ "$(_parse_tfvar smithdb_cache_storage)" == local-ssd ]]
      [[ "$(_parse_tfvar smithdb_node_machine_type)" == c3-standard-44 ]]
      [[ "$(_parse_tfvar smithdb_node_min_count)" == 3 && "$(_parse_tfvar smithdb_node_max_count)" == 7 ]]
      [[ "$(_parse_tfvar smithdb_transition_mode)" == true ]]
      [[ "$(_parse_tfvar smithdb_instance_store_local_ssd_count)" == 8 ]]
      [[ "$(_parse_tfvar smithdb_metastore_deletion_protection)" == true ]]
      [[ "$(_parse_tfvar smithdb_bucket_force_destroy)" == false ]]
      [[ "$(_parse_tfvar sizing_profile)" == production-large ]]
      grep -q '"us-west2-a"' "$INFRA_DIR/terraform.tfvars"
      grep -q '"us-west2-b"' "$INFRA_DIR/terraform.tfvars"
      ;;
    older|autopilot)
      [[ "$(_parse_tfvar enable_smithdb)" == false ]]
      [[ "$(_parse_tfvar smithdb_ingestion_enabled)" == false ]]
      [[ "$(_parse_tfvar smithdb_migration_enabled)" == false ]]
      [[ "$(_parse_tfvar smithdb_query_enabled)" == false ]]
      ;;
  esac
  if command -v terraform >/dev/null 2>&1; then
    terraform fmt -write=false "$INFRA_DIR/terraform.tfvars" >/dev/null
  fi
  echo "PASS: QuickStart $scenario generates usable SmithDB tfvars"
done
