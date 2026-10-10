#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# smithdb-migration-job-end.sh — Remove what make smithdb-migration-job-start set up, once the migration Job is Complete.
#
# Sets smithdb_migration_enabled = false in terraform.tfvars (that line only) and deletes the TaskDB settings from SSM.
# make apply then removes SmithDB's read access to the traces bucket, and make deploy removes the Job, chart-managed TaskDB with its volume, and the TaskDB keys in langsmith-config.
# An external TaskDB Postgres is not deleted; only its connection settings are.
#
# Usage (from aws/):
#   make smithdb-migration-job-end
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/../../infra}"
source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
TFVARS_FILE="$INFRA_DIR/terraform.tfvars"

header "1. Configuration"
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
_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"

header "2. AWS access and cluster"
if ! aws sts get-caller-identity --region "$_region" >/dev/null 2>&1; then
  fail "AWS credentials are missing or expired"
  exit 1
fi
# Point kubectl at this deployment's cluster, as deploy.sh does, so the Job check below reads the right one.
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
if [[ -z "$_cluster_name" ]]; then
  fail "Could not read cluster_name from Terraform outputs. Is terraform apply complete?"
  exit 1
fi
aws eks update-kubeconfig --name "$_cluster_name" --region "$_region" >/dev/null
pass "Cluster: $_cluster_name"

header "3. Migration Job"
# TaskDB holds the migration progress, so ending before the Job is Complete means a later migration starts over.
_job=$(kubectl get jobs -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME" -o name 2>/dev/null | grep -E 'smithdb-migration$' | head -1) || _job=""
if [[ -z "$_job" ]]; then
  warn "No SmithDB migration Job found for release $RELEASE_NAME in namespace $NAMESPACE"
  _confirm "End the migration anyway?" || { fail "Stopped. Nothing was changed."; exit 1; }
elif [[ "$(kubectl get "$_job" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" == "True" ]]; then
  pass "${_job#job.batch/} is Complete"
else
  warn "${_job#job.batch/} is not Complete. If it failed, keep the Job and TaskDB to diagnose it first."
  _confirm "End the migration anyway? Its progress is lost." || { fail "Stopped. Nothing was changed."; exit 1; }
fi

header "4. terraform.tfvars"
_set_tfvar "smithdb_migration_enabled" "false"
pass "smithdb_migration_enabled = false"

header "5. TaskDB settings (SSM)"
for _key in smithdb-taskdb-password smithdb-taskdb-host smithdb-taskdb-database smithdb-taskdb-username; do
  if _err=$(aws ssm delete-parameter --region "$_region" --name "${_ssm_prefix}/${_key}" 2>&1); then
    pass "Deleted: ${_ssm_prefix}/${_key}"
  elif [[ "$_err" != *"(ParameterNotFound)"* ]]; then
    fail "Could not delete ${_ssm_prefix}/${_key}: $_err" >&2
    exit 1
  fi
done

header "Next"
action "make apply          # removes SmithDB's read access to the traces bucket"
action "make init-values    # turns the migration off in the SmithDB values"
action "make deploy         # removes the Job, chart-managed TaskDB with its volume, and the TaskDB keys in langsmith-config"
