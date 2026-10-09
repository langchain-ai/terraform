#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# smithdb-migration-job-start.sh — Prepare the SmithDB migration Job, which backfills historical traces into SmithDB.
#
# Asks where TaskDB runs and how large the migration is, writes helm/values/langsmith-values-smithdb-migration.yaml,
# and sets smithdb_migration_enabled and smithdb_migration_parallelism in terraform.tfvars (those lines only).
# A chart-managed TaskDB uses the smithdb-taskdb Secret that Terraform creates. An external TaskDB's
# connection settings go into the smithdb-taskdb-external Secret.
# make apply then grants SmithDB read access to the traces bucket and sizes the namespace quota,
# and make deploy starts the Job.
#
# Usage (from gcp/):
#   make smithdb-migration-job-start
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/../../infra}"
source "$INFRA_DIR/scripts/_common.sh"

NAMESPACE="${NAMESPACE:-langsmith}"
TFVARS_FILE="$INFRA_DIR/terraform.tfvars"
MIGRATION_FILE="$HELM_DIR/values/langsmith-values-smithdb-migration.yaml"
EXTERNAL_SECRET="smithdb-taskdb-external"

# Prompts with a default; the answer lands in _REPLY.
_ask() {
  read -r -p "  $1 [$2]: " _REPLY
  _REPLY="${_REPLY:-$2}"
}

_ask_int() {
  while true; do
    _ask "$1" "$2"
    [[ "$_REPLY" =~ ^[0-9]+$ ]] && (( _REPLY > 0 )) && return
    echo "  Enter a whole number greater than 0."
  done
}

header "1. Configuration"
if [[ ! -t 0 ]]; then
  fail "This script asks questions; run it from a terminal"
  exit 1
fi
if [[ ! -f "$TFVARS_FILE" ]]; then
  fail "terraform.tfvars not found at $TFVARS_FILE"
  exit 1
fi
if ! _tfvar_is_true "enable_smithdb" || ! _tfvar_is_true "smithdb_ingestion_enabled"; then
  fail "The migration needs enable_smithdb = true and smithdb_ingestion_enabled = true, applied and deployed first"
  exit 1
fi
pass "SmithDB and ingestion are on"
# The size sets the migration pod resources, so read what the last apply resolved.
_sizing=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_sizing 2>/dev/null) || _sizing=""
if [[ -z "$_sizing" ]]; then
  fail "Could not read smithdb_sizing from Terraform outputs. Is terraform apply complete?"
  exit 1
fi
pass "SmithDB size: $_sizing"
_start_time=$(_parse_tfvar "smithdb_migration_start_time")
info "smithdb_migration_start_time = ${_start_time:-unset (chart default window)}; set it in terraform.tfvars to change the window"

header "2. TaskDB"
echo "  TaskDB is a temporary Postgres that tracks migration progress. Do not use the LangSmith Postgres or the SmithDB metastore."
echo "    1) Chart-managed: runs in the cluster and is removed when the migration ends (recommended)"
echo "    2) External: a Postgres you provide"
_ask "Choose" "1"
case "$_REPLY" in
  1)
    _taskdb_source="chart"
    ;;
  2)
    _taskdb_source="external"
    _ask "Host" ""
    _host="$_REPLY"
    _ask_int "Port" "5432"
    _port="$_REPLY"
    _ask "Database" "smithdb_migration"
    _database="$_REPLY"
    _ask "Username" ""
    _username="$_REPLY"
    read -r -s -p "  Password (hidden): " _password
    echo ""
    _ask "Use SSL (true/false)" "true"
    _use_ssl="$_REPLY"
    if [[ -z "$_host" || -z "$_username" || -z "$_password" || ( "$_use_ssl" != "true" && "$_use_ssl" != "false" ) ]]; then
      fail "Host, username, and password are required, and SSL must be true or false. Nothing was changed."
      exit 1
    fi
    ;;
  *)
    fail "Choose 1 or 2"
    exit 1
    ;;
esac

header "3. Sizing"
# LangSmith docs: allocated vCPUs = historical runs / 5,000,000 / target days, at 8 vCPU per migration pod by default.
# A fixed 50% headroom is added on top, since the docs call the formula an estimate.
# minimal runs SmithDB on the general node pool with 1-2 vCPU migration pods, so it suggests 1 pod.
_pod_vcpu=8
_pod_shape="8 vCPU / 32 GiB / 100 GiB disk each"
if [[ "$_sizing" == "minimal" ]]; then
  _pod_vcpu=1
  _pod_shape="1-2 vCPU / 4-8 GiB / 10-20 GiB disk each"
fi
_ask_int "About how many historical runs" ""
_runs="$_REPLY"
while true; do
  _ask "Finish in how many days (fractions allowed, e.g. 0.5)" "1"
  [[ "$_REPLY" =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v d="$_REPLY" 'BEGIN { exit !(d > 0) }' && break
  echo "  Enter a number greater than 0."
done
_days="$_REPLY"
_headroom=50
_suggested=$(awk -v r="$_runs" -v d="$_days" -v h="$_headroom" -v c="$_pod_vcpu" 'BEGIN { p = r / 5000000 / d / c * (1 + h / 100); n = int(p); if (n < p) n++; if (n < 1) n = 1; print n }')
(( _suggested > 20 )) && _suggested=20
if [[ "$_sizing" == "minimal" ]]; then
  info "SmithDB size minimal: the general node pool runs the migration, so 1 pod is suggested"
  _suggested=1
else
  info "$_runs runs in $_days days at 5,000,000 runs per vCPU per day, plus ${_headroom}% headroom, at 8 vCPU per pod: $_suggested pod(s)"
fi
_ask_int "Parallelism: migration pods running at once ($_pod_shape)" "$_suggested"
_parallelism="$_REPLY"
if (( _parallelism > 30 )); then
  fail "Use 30 pods or fewer: above 30, the namespace quota for large goes over its limit. Nothing was changed."
  exit 1
fi
if (( _parallelism > 20 )); then
  warn "Above about 20 pods, raise TaskDB CPU and memory instead of adding pods (chart guidance)"
fi
if (( _parallelism > 1 )) && [[ "$_sizing" != "minimal" ]]; then
  info "Migration pods run on the SmithDB cache pool. If the pool cannot add nodes for $_parallelism pods, raise smithdb_instance_store_max_nodes"
fi
pass "Parallelism: $_parallelism"
# Same rule of thumb, solved for time, without headroom: the plain estimate for the pod count chosen.
_hours=$(awk -v r="$_runs" -v p="$_parallelism" -v c="$_pod_vcpu" 'BEGIN { printf "%.1f", r / (5000000 * c * p) * 24 }')
info "Estimated time for $_runs runs with $_parallelism pod(s): about $_hours hours (LangSmith rule of thumb; actual time varies with your data)"

header "4. TaskDB settings and values file"
# Confirm before changing a Secret so declining preserves credentials as well as values.
if [[ -f "$MIGRATION_FILE" ]]; then
  if ! _confirm "helm/values/langsmith-values-smithdb-migration.yaml exists. Replace it with these answers?"; then
    info "Stopped. Nothing was changed."
    exit 0
  fi
fi

_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
if [[ -z "$_cluster_name" ]]; then
  fail "Could not read cluster_name from Terraform outputs. Is terraform apply complete?"
  exit 1
fi
"$SCRIPT_DIR/get-kubeconfig.sh" "$_cluster_name" >/dev/null

if [[ "$_taskdb_source" == "chart" ]]; then
  # Terraform creates this Secret with a stable password whenever enable_smithdb = true.
  _taskdb_secret=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_taskdb_secret_name 2>/dev/null) || _taskdb_secret=""
  _taskdb_secret="${_taskdb_secret:-smithdb-taskdb}"
  pass "Chart-managed TaskDB uses the $_taskdb_secret Secret (Terraform-managed)"
  # Connection settings from an earlier external choice are no longer used.
  kubectl delete secret "$EXTERNAL_SECRET" -n "$NAMESPACE" --ignore-not-found >/dev/null
else
  # Each value goes through a private file so the password never appears in the process list or shell history.
  _secret_dir="$(mktemp -d)"
  trap 'rm -rf "$_secret_dir"' EXIT
  chmod 700 "$_secret_dir"
  printf '%s' "$_host" > "$_secret_dir/smithdb_taskdb_host"
  printf '%s' "$_database" > "$_secret_dir/smithdb_taskdb_database"
  printf '%s' "$_username" > "$_secret_dir/smithdb_taskdb_username"
  printf '%s' "$_password" > "$_secret_dir/smithdb_taskdb_password"
  unset _password
  # Server-side apply replaces the Secret in one step and keeps no copy of the data in an annotation.
  if ! kubectl create secret generic "$EXTERNAL_SECRET" -n "$NAMESPACE" --from-file="$_secret_dir" --dry-run=client -o yaml \
      | kubectl apply --server-side --force-conflicts --field-manager=smithdb-migration-job-start -f - >/dev/null; then
    fail "Could not write the $EXTERNAL_SECRET Secret in namespace $NAMESPACE"
    exit 1
  fi
  rm -rf "$_secret_dir"
  pass "Connection settings stored in the $EXTERNAL_SECRET Secret"
fi

# Migration pod and TaskDB resources are not in this file on GCP: the SmithDB size
# sets them, and Terraform sizes the namespace quota for the same values.
{
  echo "# Written by make smithdb-migration-job-start; rerun it to change these answers."
  echo "# Migration pod and TaskDB resources come from the SmithDB size (langsmith-values-smithdb-sizing.yaml) and the chart defaults."
  echo "# Keep parallelism equal to smithdb_migration_parallelism in terraform.tfvars; Terraform sizes the namespace quota from it."
  echo "smithdb:"
  echo "  migration:"
  echo "    job:"
  echo "      parallelism: $_parallelism"
  echo "    taskdb:"
  echo "      postgres:"
  echo "        maxConnectionsPerMigrationPod: 10   # server limit is (parallelism + 1) x this"
  if [[ "$_taskdb_source" == "chart" ]]; then
    echo "        auth:"
    echo "          existingSecretName: \"$_taskdb_secret\""
    echo "          passwordSecretKey: \"postgres_password\""
  else
    echo "        external:"
    echo "          enabled: true"
    echo "          port: \"$_port\""
    echo "          useSsl: $_use_ssl"
    echo "          existingSecretName: \"$EXTERNAL_SECRET\""
    echo "          hostSecretKey: \"smithdb_taskdb_host\""
    echo "          databaseSecretKey: \"smithdb_taskdb_database\""
    echo "          usernameSecretKey: \"smithdb_taskdb_username\""
    echo "          passwordSecretKey: \"smithdb_taskdb_password\""
  fi
} > "$MIGRATION_FILE"
pass "Written: helm/values/langsmith-values-smithdb-migration.yaml"
info "If migration pods are OOMKilled (very large traces), see SMITHDB.md (Troubleshooting: OOMKilled migration pods)"
info "Preserve TaskDB and its PVC, delete only the failed migration Job, then rerun make deploy to resume from saved progress"

header "5. terraform.tfvars"
_set_tfvar "smithdb_migration_enabled" "true"
pass "smithdb_migration_enabled = true"
_set_tfvar "smithdb_migration_parallelism" "$_parallelism"
pass "smithdb_migration_parallelism = $_parallelism"

header "Next"
action "make apply          # grants SmithDB read access to the traces bucket and sizes the namespace quota"
action "make init-values    # turns the migration on in the SmithDB values"
action "make deploy         # starts the migration Job"
action "kubectl get jobs -n $NAMESPACE   # watch the Job; run make smithdb-migration-job-end once it is Complete"
