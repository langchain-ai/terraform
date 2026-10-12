#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# smithdb-migration-job-end.sh — Remove what make smithdb-migration-job-start set up, once the migration Job is Complete.
#
# Sets smithdb_migration_enabled = false in terraform.tfvars (that line only) and deletes the smithdb-taskdb-external Secret.
# make apply then removes SmithDB's read access to the traces bucket and the migration quota, and make deploy removes
# the Job and the chart-managed TaskDB with its volume.
# An external TaskDB Postgres is not deleted; only its connection settings are.
#
# Usage (from gcp/):
#   make smithdb-migration-job-end
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/../../infra}"
source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
TFVARS_FILE="$INFRA_DIR/terraform.tfvars"
EXTERNAL_SECRET="smithdb-taskdb-external"

header "1. Configuration"
if [[ ! -f "$TFVARS_FILE" ]]; then
  fail "terraform.tfvars not found at $TFVARS_FILE"
  exit 1
fi

header "2. Cluster"
# Point kubectl at this deployment's cluster, as deploy.sh does, so the Job check below reads the right one.
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
if [[ -z "$_cluster_name" ]]; then
  fail "Could not read cluster_name from Terraform outputs. Is terraform apply complete?"
  exit 1
fi
"$SCRIPT_DIR/get-kubeconfig.sh" "$_cluster_name" >/dev/null
pass "Cluster: $_cluster_name"

header "3. Migration Job"
# TaskDB holds the migration progress, so ending before the Job is Complete means a later migration starts over.
# Found by the release label, because the chart prefixes the Job name with the release fullname.
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

header "5. TaskDB settings (Secret)"
if ! kubectl delete secret "$EXTERNAL_SECRET" -n "$NAMESPACE" --ignore-not-found >/dev/null; then
  fail "Could not delete the $EXTERNAL_SECRET Secret in namespace $NAMESPACE" >&2
  exit 1
fi
pass "No $EXTERNAL_SECRET Secret remains"

header "Next"
action "make apply          # removes SmithDB's read access to the traces bucket and the migration quota"
action "make init-values    # turns the migration off in the SmithDB values"
action "make deploy         # removes the Job and the chart-managed TaskDB with its volume"
