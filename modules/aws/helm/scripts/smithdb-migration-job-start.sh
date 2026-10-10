#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# smithdb-migration-job-start.sh — Prepare the SmithDB migration Job, which backfills historical traces into SmithDB.
#
# Asks where TaskDB runs and how large the migration is, stores the TaskDB settings in SSM, writes helm/values/langsmith-values-smithdb-migration.yaml, and sets smithdb_migration_enabled = true in terraform.tfvars (that line only).
# make apply then grants SmithDB read access to the traces bucket, and make deploy syncs the settings into langsmith-config and starts the Job.
#
# Usage (from aws/):
#   make smithdb-migration-job-start
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/../../infra}"
source "$INFRA_DIR/scripts/_common.sh"

NAMESPACE="${NAMESPACE:-langsmith}"
TFVARS_FILE="$INFRA_DIR/terraform.tfvars"
MIGRATION_FILE="$HELM_DIR/values/langsmith-values-smithdb-migration.yaml"

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
_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment=""
_region=$(_parse_tfvar "region") || _region=""
if [[ -z "$_name_prefix" || -z "$_environment" || -z "$_region" ]]; then
  fail "name_prefix, environment, and region must be set in terraform.tfvars"
  exit 1
fi
if ! _tfvar_is_true "enable_smithdb" || ! _tfvar_is_true "smithdb_ingestion_enabled"; then
  fail "The migration needs enable_smithdb = true and smithdb_ingestion_enabled = true, applied and deployed first"
  exit 1
fi
pass "SmithDB and ingestion are on"
_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"

header "2. AWS access"
if ! aws sts get-caller-identity --region "$_region" >/dev/null 2>&1; then
  fail "AWS credentials are missing or expired"
  exit 1
fi
pass "AWS credentials work"

header "3. TaskDB"
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

header "4. Sizing"
# LangSmith docs: allocated vCPUs = historical runs / 5,000,000 / target days, at 8 vCPU per migration pod by default.
# A fixed 50% headroom is added on top, since the docs call the formula an estimate.
_ask_int "About how many historical runs" ""
_runs="$_REPLY"
while true; do
  _ask "Finish in how many days (fractions allowed, e.g. 0.5)" "1"
  [[ "$_REPLY" =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v d="$_REPLY" 'BEGIN { exit !(d > 0) }' && break
  echo "  Enter a number greater than 0."
done
_days="$_REPLY"
_headroom=50
_suggested=$(awk -v r="$_runs" -v d="$_days" -v h="$_headroom" 'BEGIN { p = r / 5000000 / d / 8 * (1 + h / 100); n = int(p); if (n < p) n++; if (n < 1) n = 1; print n }')
(( _suggested > 20 )) && _suggested=20
info "$_runs runs in $_days days at 5,000,000 runs per vCPU per day, plus ${_headroom}% headroom, at 8 vCPU per pod: $_suggested pod(s)"
_ask_int "Parallelism: migration pods running at once (8 vCPU / 32 GiB / 100 GiB disk each)" "$_suggested"
_parallelism="$_REPLY"
if (( _parallelism > 20 )); then
  warn "Above about 20 pods, raise TaskDB CPU and memory instead of adding pods (chart guidance)"
fi
pass "Parallelism: $_parallelism"
# Same rule of thumb, solved for time, without headroom: the plain estimate for the pod count chosen.
_hours=$(awk -v r="$_runs" -v p="$_parallelism" 'BEGIN { printf "%.1f", r / (5000000 * 8 * p) * 24 }')
info "Estimated time for $_runs runs with $_parallelism pod(s): about $_hours hours (LangSmith rule of thumb; actual time varies with your data)"

header "5. TaskDB settings and values file"
# Confirm before changing SSM so declining preserves credentials as well as values.
if [[ -f "$MIGRATION_FILE" ]]; then
  if ! _confirm "helm/values/langsmith-values-smithdb-migration.yaml exists. Replace it with these answers?"; then
    info "Stopped. Nothing was changed."
    exit 0
  fi
fi

if [[ "$_taskdb_source" == "chart" ]]; then
  _cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
  if [[ -z "$_cluster_name" ]]; then
    fail "Could not read cluster_name from Terraform outputs. Is terraform apply complete?"
    exit 1
  fi
  aws eks update-kubeconfig --name "$_cluster_name" --region "$_region" >/dev/null
  _secret=$(kubectl get secret smithdb-migration-taskdb -n "$NAMESPACE" --ignore-not-found -o name)
  _taskdb_secret="langsmith-config"
  _taskdb_password_key="smithdb_taskdb_password"
  if [[ -n "$_secret" ]]; then
    # Job pod templates are immutable; keep the old reference even after its password is copied to SSM.
    _taskdb_secret="smithdb-migration-taskdb"
    _taskdb_password_key="postgres_password"
  fi
  # Chart-managed TaskDB keeps the first password it was initialized with, so reuse the stored one.
  if _ssm_exists "${_ssm_prefix}/smithdb-taskdb-password" && ! _ssm_exists "${_ssm_prefix}/smithdb-taskdb-host"; then
    pass "Password found in SSM"
  else
    # Older migrations keep their password only in this Kubernetes Secret.
    if [[ -n "$_secret" ]]; then
      _password=$(kubectl get "$_secret" -n "$NAMESPACE" -o jsonpath='{.data.postgres_password}' | base64 --decode)
      if [[ -z "$_password" ]]; then
        fail "smithdb-migration-taskdb has no postgres_password. Restore it before continuing."
        exit 1
      fi
      pass "Reusing the existing TaskDB password"
    else
      _password=$(openssl rand -hex 24)
      pass "Password generated"
    fi
    _ssm_put "${_ssm_prefix}/smithdb-taskdb-password" "$_password"
    unset _password
    pass "Password stored in SSM"
  fi
  # Connection keys from an earlier external choice would make ESO keep syncing them.
  for _key in smithdb-taskdb-host smithdb-taskdb-database smithdb-taskdb-username; do
    aws ssm delete-parameter --region "$_region" --name "${_ssm_prefix}/${_key}" >/dev/null 2>&1 || true
  done
else
  _ssm_put "${_ssm_prefix}/smithdb-taskdb-host" "$_host"
  _ssm_put "${_ssm_prefix}/smithdb-taskdb-database" "$_database"
  _ssm_put "${_ssm_prefix}/smithdb-taskdb-username" "$_username"
  _ssm_put "${_ssm_prefix}/smithdb-taskdb-password" "$_password"
  unset _password
  pass "Connection settings stored in SSM"
fi

# The block mirrors the LangSmith docs' sample: resources stay at chart defaults, written out so they can be edited in one place.
{
  echo "# Written by make smithdb-migration-job-start; rerun it to change these answers."
  echo "# Resources are chart defaults; change them only when scaling (LangSmith docs: Migrate ClickHouse history to SmithDB)."
  echo "smithdb:"
  echo "  migration:"
  echo "    job:"
  echo "      parallelism: $_parallelism"
  echo "      resources:   # per migration pod; 32Gi memory is a practical minimum"
  echo "        requests:"
  echo "          cpu: \"8\""
  echo "          memory: \"32Gi\""
  echo "          ephemeral-storage: \"100Gi\""
  echo "        limits:"
  echo "          cpu: \"8\""
  echo "          memory: \"32Gi\""
  echo "          ephemeral-storage: \"100Gi\""
  echo "    taskdb:"
  echo "      postgres:"
  echo "        maxConnectionsPerMigrationPod: 10   # server limit is (parallelism + 1) x this"
  if [[ "$_taskdb_source" == "chart" ]]; then
    echo "        auth:"
    echo "          existingSecretName: \"$_taskdb_secret\""
    echo "          passwordSecretKey: \"$_taskdb_password_key\""
    echo "        statefulSet:"
    echo "          resources:   # raise for high parallelism"
    echo "            requests:"
    echo "              cpu: \"2\""
    echo "              memory: \"4Gi\""
    echo "            limits:"
    echo "              cpu: \"4\""
    echo "              memory: \"8Gi\""
  else
    echo "        external:"
    echo "          enabled: true"
    echo "          port: \"$_port\""
    echo "          useSsl: $_use_ssl"
    echo "          existingSecretName: \"langsmith-config\""
    echo "          hostSecretKey: \"smithdb_taskdb_host\""
    echo "          databaseSecretKey: \"smithdb_taskdb_database\""
    echo "          usernameSecretKey: \"smithdb_taskdb_username\""
    echo "          passwordSecretKey: \"smithdb_taskdb_password\""
  fi
} > "$MIGRATION_FILE"
pass "Written: helm/values/langsmith-values-smithdb-migration.yaml"
info "To change migration pod or TaskDB resources, edit that file before make deploy"
info "If migration pods are OOMKilled (very large traces), raise memory there (keep requests = limits)"
info "Preserve TaskDB and its PVC, delete only the failed migration Job, then rerun make deploy to resume from saved progress"

header "6. terraform.tfvars"
_set_tfvar "smithdb_migration_enabled" "true"
pass "smithdb_migration_enabled = true"

header "Next"
action "make apply          # grants SmithDB read access to the traces bucket"
action "make init-values    # turns the migration on in the SmithDB values"
action "make deploy         # syncs TaskDB settings into langsmith-config and starts the migration Job"
action "kubectl get jobs -n langsmith   # watch the Job; run make smithdb-migration-job-end once it is Complete"
