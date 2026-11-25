#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _addon-storage.sh — The storage Fleet, Chat and Insights get from 0.18: each its
# own database on the shared RDS and its own DB index on the shared ElastiCache,
# through the Secrets Terraform creates (infra/main.tf). Sourced by deploy.sh,
# which sets these on every deploy so a stale values file cannot point an add-on
# at the chart's in-cluster StatefulSets, and by test-values.sh, which renders them.

# _addon_storage_values <fleet> <chat> <engine-insights-agent>
# Each argument is true or false. Engine and Insights share the
# engineInsightsAgent deployment and its langsmith_insights database.
# Appends --set arguments to the caller's VALUES_ARGS array.
_addon_storage_values() {
  local section secret
  local -a sections=()
  [[ "$1" == true ]] && sections+=("fleet:fleet")
  [[ "$2" == true ]] && sections+=("polly:polly")
  [[ "$3" == true ]] && sections+=("engineInsightsAgent:insights")
  for section in ${sections[@]+"${sections[@]}"}; do
    secret="${section#*:}"
    section="${section%%:*}"
    VALUES_ARGS+=(
      --set "$section.postgres.external.enabled=true"
      --set "$section.postgres.external.existingSecretName=langsmith-$secret-postgres"
      --set "$section.redis.external.enabled=true"
      --set "$section.redis.external.existingSecretName=langsmith-$secret-redis"
    )
  done
}

# A 0.17 install that left polly_storage or insights_storage unset kept that
# add-on in the chart's in-cluster StatefulSets. From 0.18 the same tfvars means
# external, so the next deploy would point the add-on at a new, empty database
# and strand its data. A plan cannot see the live release, so the check runs
# here. Fleet already defaulted to external in 0.17.
# _addon_storage_cutover_check <release> <namespace> <polly|engineInsightsAgent>...
# Checks only the sections given, which the caller passes when the add-on is on
# and terraform.tfvars does not set its *_storage = "external". Returns 0 for a
# new install (no release yet) or a release already on external storage, and 1,
# with the reason, otherwise. A failed lookup returns 1.
_addon_storage_cutover_check() {
  local release="$1" namespace="$2" found live section feature key in_cluster
  shift 2
  (( $# )) || return 0
  found=$(helm list -a -n "$namespace" --filter "^${release}\$" -q) || {
    echo "ERROR: could not list the Helm releases in $namespace, so the add-on storage check cannot run." >&2
    echo "       Check cluster access (make kubeconfig), or set polly_storage / insights_storage = \"external\" in terraform.tfvars." >&2
    return 1
  }
  [[ -n "$found" ]] || return 0
  live=$(helm get values "$release" -n "$namespace" --all -o json) || {
    echo "ERROR: could not read the values of release $release, so the add-on storage check cannot run." >&2
    return 1
  }
  for section in "$@"; do
    case "$section" in
      polly) feature="Chat" key=polly_storage ;;
      *) feature="Insights and Engine" key=insights_storage ;;
    esac
    in_cluster=$(jq -r --arg s "$section" '
      (if $s == "polly" then .polly.enabled
       else (.insights.enabled // false) or (.engine.enabled // false) end) == true
      and (.[$s].postgres.external.enabled // false) != true' <<< "$live") || {
      echo "ERROR: could not read the $feature storage of release $release, so the add-on storage check cannot run." >&2
      return 1
    }
    [[ "$in_cluster" == "true" ]] || continue
    echo "ERROR: release $release keeps $feature data in the cluster, and this deploy would point $feature at a new, empty database on RDS." >&2
    echo "       Move the data first, then set $key = \"external\" in terraform.tfvars to confirm." >&2
    echo "       See \"Move Fleet, Chat or Insights data to RDS\" in README.md." >&2
    return 1
  done
}
