#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# patch-lgp-resources.sh — Right-size operator-managed LGP resources.
#
# The LangSmith operator deploys agent pods (agent-builder, clio, polly) with
# hardcoded resource requests that assume production scale: 1 CPU / 2Gi for
# each redis sidecar, 1 CPU / 3.8Gi for each database, and maxReplicas 5-10
# for KEDA ScaledObjects. On a dev/test cluster this eats 12+ CPU and 24+ Gi
# for sidecars alone.
#
# This script patches the LGP custom resources directly. The operator
# reconciles downstream objects (Deployments, StatefulSets, ScaledObjects)
# from the LGP spec, so patching the CR is the correct (and only durable)
# approach — patching the Deployments directly gets overwritten.
#
# Adapted from langsmith-local/scripts/cluster/patch-scaledobjects.sh.
#
# Usage:
#   ./patch-lgp-resources.sh [--profile minimum]
#
# Called automatically by deploy.sh when sizing_profile is minimum.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/../../infra}"
source "$INFRA_DIR/scripts/_common.sh"

NAMESPACE="${NAMESPACE:-langsmith}"
PROFILE="${1:-minimum}"

# Strip --profile flag if passed
[[ "$PROFILE" == "--profile" ]] && PROFILE="${2:-minimum}"

case "$PROFILE" in
  minimum|*)
    # Absolute floor — sized from kubectl-top on idle cluster. Will OOM under load.
    MAX_WORKERS=1
    MAX_QUEUES=1
    REDIS_CPU_REQ="10m";   REDIS_MEM_REQ="16Mi";    REDIS_CPU_LIM="200m";  REDIS_MEM_LIM="64Mi"
    DB_CPU_REQ="25m";      DB_MEM_REQ="128Mi";      DB_CPU_LIM="500m";     DB_MEM_LIM="256Mi"
    SERVER_CPU_REQ="25m";  SERVER_MEM_REQ="256Mi";   SERVER_CPU_LIM="1";    SERVER_MEM_LIM="512Mi"
    QUEUE_CPU_REQ="25m";   QUEUE_MEM_REQ="256Mi";    QUEUE_CPU_LIM="1";     QUEUE_MEM_LIM="512Mi"
    ;;
esac

echo "==> Patching LGP resources (profile: $PROFILE)"
echo "    workers → maxReplicas=${MAX_WORKERS}, queues → maxReplicas=${MAX_QUEUES}"
echo ""

# ── Desired spec (JSON for comparison) ─────────────────────────────────────
_desired_spec="{
  \"autoscaling\": {
    \"maxReplicas\": ${MAX_WORKERS},
    \"queueMaxReplicas\": ${MAX_QUEUES}
  },
  \"redis\": {
    \"resources\": {
      \"requests\": { \"cpu\": \"${REDIS_CPU_REQ}\",  \"memory\": \"${REDIS_MEM_REQ}\"  },
      \"limits\":   { \"cpu\": \"${REDIS_CPU_LIM}\", \"memory\": \"${REDIS_MEM_LIM}\" }
    }
  },
  \"database\": {
    \"resources\": {
      \"requests\": { \"cpu\": \"${DB_CPU_REQ}\",  \"memory\": \"${DB_MEM_REQ}\"  },
      \"limits\":   { \"cpu\": \"${DB_CPU_LIM}\", \"memory\": \"${DB_MEM_LIM}\" }
    }
  },
  \"serverSpec\": {
    \"resources\": {
      \"requests\": { \"cpu\": \"${SERVER_CPU_REQ}\", \"memory\": \"${SERVER_MEM_REQ}\" },
      \"limits\":   { \"cpu\": \"${SERVER_CPU_LIM}\", \"memory\": \"${SERVER_MEM_LIM}\" }
    },
    \"queueResources\": {
      \"requests\": { \"cpu\": \"${QUEUE_CPU_REQ}\", \"memory\": \"${QUEUE_MEM_REQ}\" },
      \"limits\":   { \"cpu\": \"${QUEUE_CPU_LIM}\", \"memory\": \"${QUEUE_MEM_LIM}\" }
    }
  }
}"

# jsonpath template to extract the fields we compare.
# Produces a single line: maxReplicas|queueMaxReplicas|redisCpuReq|redisMemReq|...
_jp='{.spec.autoscaling.maxReplicas}|{.spec.autoscaling.queueMaxReplicas}'
_jp+='|{.spec.redis.resources.requests.cpu}|{.spec.redis.resources.requests.memory}'
_jp+='|{.spec.redis.resources.limits.cpu}|{.spec.redis.resources.limits.memory}'
_jp+='|{.spec.database.resources.requests.cpu}|{.spec.database.resources.requests.memory}'
_jp+='|{.spec.database.resources.limits.cpu}|{.spec.database.resources.limits.memory}'
_jp+='|{.spec.serverSpec.resources.requests.cpu}|{.spec.serverSpec.resources.requests.memory}'
_jp+='|{.spec.serverSpec.resources.limits.cpu}|{.spec.serverSpec.resources.limits.memory}'
_jp+='|{.spec.serverSpec.queueResources.requests.cpu}|{.spec.serverSpec.queueResources.requests.memory}'
_jp+='|{.spec.serverSpec.queueResources.limits.cpu}|{.spec.serverSpec.queueResources.limits.memory}'

_desired_fingerprint="${MAX_WORKERS}|${MAX_QUEUES}"
_desired_fingerprint+="|${REDIS_CPU_REQ}|${REDIS_MEM_REQ}|${REDIS_CPU_LIM}|${REDIS_MEM_LIM}"
_desired_fingerprint+="|${DB_CPU_REQ}|${DB_MEM_REQ}|${DB_CPU_LIM}|${DB_MEM_LIM}"
_desired_fingerprint+="|${SERVER_CPU_REQ}|${SERVER_MEM_REQ}|${SERVER_CPU_LIM}|${SERVER_MEM_LIM}"
_desired_fingerprint+="|${QUEUE_CPU_REQ}|${QUEUE_MEM_REQ}|${QUEUE_CPU_LIM}|${QUEUE_MEM_LIM}"

# ── Patch LGP custom resources ──────────────────────────────────────────────
lgp_patched=0
lgp_skipped=0

while IFS= read -r lgp_name; do
  [[ -z "$lgp_name" ]] && continue

  # Compare current spec to desired — skip if already correct.
  _current=$(kubectl get lgp "$lgp_name" -n "$NAMESPACE" -o jsonpath="$_jp" 2>/dev/null) || _current=""

  if [[ "$_current" == "$_desired_fingerprint" ]]; then
    echo "    ${lgp_name} — already at ${PROFILE} sizing, skipping"
    (( lgp_skipped++ )) || true
    continue
  fi

  kubectl patch lgp "$lgp_name" \
    -n "$NAMESPACE" \
    --type=merge \
    -p "{ \"spec\": $_desired_spec }"

  echo "    ${lgp_name}"
  echo "      redis:    req=${REDIS_CPU_REQ}/${REDIS_MEM_REQ}  lim=${REDIS_CPU_LIM}/${REDIS_MEM_LIM}"
  echo "      database: req=${DB_CPU_REQ}/${DB_MEM_REQ}  lim=${DB_CPU_LIM}/${DB_MEM_LIM}"
  echo "      workers:  req=${SERVER_CPU_REQ}/${SERVER_MEM_REQ}  lim=${SERVER_CPU_LIM}/${SERVER_MEM_LIM}"
  echo "      queues:   req=${QUEUE_CPU_REQ}/${QUEUE_MEM_REQ}  lim=${QUEUE_CPU_LIM}/${QUEUE_MEM_LIM}"
  (( lgp_patched++ )) || true
done < <(kubectl get lgp -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

if [[ "$lgp_patched" -eq 0 && "$lgp_skipped" -eq 0 ]]; then
  echo "    No LGP resources found (agent add-ons may not be enabled)."
fi

# ── Wait for operator to reconcile ──────────────────────────────────────────
if [[ "$lgp_patched" -gt 0 ]]; then
  echo ""
  echo "    Waiting for operator to reconcile..."
  sleep 10
  echo ""
  kubectl get scaledobject -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,MIN:.spec.minReplicaCount,MAX:.spec.maxReplicaCount' 2>/dev/null || true
fi

echo ""
echo "==> LGP patch complete (${lgp_patched} patched, ${lgp_skipped} already correct)"
