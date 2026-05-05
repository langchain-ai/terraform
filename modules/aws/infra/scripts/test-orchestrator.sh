#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.

# test-orchestrator.sh — Parallel permutation testing across isolated clusters.
#
# Each permutation gets its own git worktree + unique name_prefix so workers
# never touch each other's AWS resources or the user's existing cluster.
#
# Usage:
#   ./infra/scripts/test-orchestrator.sh                   # all perms, 3 parallel
#   ./infra/scripts/test-orchestrator.sh 1 2 5             # specific perms
#   ./infra/scripts/test-orchestrator.sh --parallel 2      # max 2 at a time
#   ./infra/scripts/test-orchestrator.sh --keep-on-failure # keep worktree when worker fails
#   ./infra/scripts/test-orchestrator.sh --dry-run         # pass --dry-run to all workers
#   make test-parallel ARGS="5 6"
#
# Prerequisites:
#   source infra/scripts/setup-env.sh   # exports TF_VAR_* secrets to env
#   AWS credentials configured (AWS_PROFILE or env vars)
#
# Worker name mapping:
#   P1 → tst1-test-eks    P5 → tst5-test-eks
#   P2 → tst2-test-eks    P6 → tst6-test-eks
#   P3 → tst3-test-eks    P7 → tst7-test-eks
#   P4 → tst4-test-eks    P8 → tst8-test-eks
#
# Your cluster (from terraform.tfvars name_prefix) is never touched.

set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_TS=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="$INFRA_DIR/logs/parallel-${RUN_TS}"

# ── Arg parsing ───────────────────────────────────────────────────────────────

MAX_PARALLEL=3
KEEP_ON_FAILURE=false
DRY_RUN_FLAG=""
SELECTED_PERMS=()

_i=1
while [[ $_i -le $# ]]; do
  arg="${!_i}"
  case "$arg" in
    --parallel)
      _i=$((_i + 1)); MAX_PARALLEL="${!_i:?--parallel requires a number}"
      ;;
    --keep-on-failure) KEEP_ON_FAILURE=true ;;
    --dry-run)         DRY_RUN_FLAG="--dry-run" ;;
    [1-8])             SELECTED_PERMS+=("$arg") ;;
    all)               ;; # default, handled below
    *)                 echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
  _i=$((_i + 1))
done

[[ ${#SELECTED_PERMS[@]} -eq 0 ]] && SELECTED_PERMS=(1 2 3 4 5 6 7 8)

# ── Validate prerequisites ────────────────────────────────────────────────────

if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  echo "ERROR: terraform.tfvars not found in $INFRA_DIR" >&2
  echo "       Run 'make quickstart' first to generate it." >&2
  exit 1
fi

if ! git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  echo "ERROR: $REPO_ROOT is not a git repo — worktrees require git." >&2
  exit 1
fi

# ── Read shared config from user's terraform.tfvars ───────────────────────────
# Workers inherit these as env vars. Secrets (TF_VAR_*) flow through from
# the calling shell (setup-env.sh must have been sourced before this script).

export WORKER_REGION;         WORKER_REGION="${WORKER_REGION:-$(_parse_tfvar "region" 2>/dev/null || echo "us-west-2")}"
export WORKER_EKS_VERSION;    WORKER_EKS_VERSION="${WORKER_EKS_VERSION:-$(_parse_tfvar "eks_cluster_version" 2>/dev/null || echo "1.31")}"
# Workers always use in-cluster Postgres/Redis — cheap, fast, no per-worker RDS/ElastiCache
# Env var overrides take precedence over terraform.tfvars (useful for one-off domain/email overrides)
export WORKER_DOMAIN;         WORKER_DOMAIN="${WORKER_DOMAIN:-$(_parse_tfvar "langsmith_domain" 2>/dev/null || echo "")}"
export WORKER_LE_EMAIL;       WORKER_LE_EMAIL="${WORKER_LE_EMAIL:-$(_parse_tfvar "letsencrypt_email" 2>/dev/null || echo "")}"
export WORKER_HOSTED_ZONE;    WORKER_HOSTED_ZONE="${WORKER_HOSTED_ZONE:-$(_parse_tfvar "cert_manager_hosted_zone_id" 2>/dev/null || echo "")}"

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
# If HEAD is detached, use the commit SHA so worktree add still works
[[ "$CURRENT_BRANCH" == "HEAD" ]] && CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse HEAD)

mkdir -p "$RESULTS_DIR"

# ── Banner ────────────────────────────────────────────────────────────────────

echo ""
printf '\033[1m════════════════════════════════════════════════════════\033[0m\n'
printf '\033[1m  LangSmith AWS — Parallel Permutation Orchestrator\033[0m\n'
printf '\033[1m════════════════════════════════════════════════════════\033[0m\n'
echo ""
printf "  %-22s %s\n" "Permutations:"    "${SELECTED_PERMS[*]}"
printf "  %-22s %s\n" "Max parallel:"    "${MAX_PARALLEL}"
printf "  %-22s %s\n" "Region:"          "${WORKER_REGION}"
printf "  %-22s %s\n" "EKS version:"     "${WORKER_EKS_VERSION}"
printf "  %-22s %s\n" "Postgres/Redis:"  "in-cluster (light deploy)"
printf "  %-22s %s\n" "Domain:"          "${WORKER_DOMAIN:-<not set>}"
printf "  %-22s %s\n" "Results dir:"     "${RESULTS_DIR}"
printf "  %-22s %s\n" "Your cluster:"    "untouched (workers: tst1–tst7)"
[[ -n "$DRY_RUN_FLAG" ]] && printf "  %-22s %s\n" "Mode:" "DRY RUN"
echo ""

# ── Worktree management ───────────────────────────────────────────────────────

declare -A WORKTREES    # perm → worktree path
declare -A WORKER_PIDS  # perm → background pid
declare -A WORKER_LOGS  # perm → log path
declare -A WORKER_EXIT  # perm → exit code

_create_worktree() {
  local perm="$1"
  local wt_path="/tmp/ls-worker-p${perm}-${RUN_TS}"
  git -C "$REPO_ROOT" worktree add "$wt_path" "$CURRENT_BRANCH" --detach --quiet
  WORKTREES[$perm]="$wt_path"
  printf "  Created worktree P%s → %s\n" "$perm" "$wt_path"
}

_remove_worktree() {
  local perm="$1"
  local wt_path="${WORKTREES[$perm]:-}"
  [[ -z "$wt_path" || ! -d "$wt_path" ]] && return 0
  git -C "$REPO_ROOT" worktree remove "$wt_path" --force 2>/dev/null || rm -rf "$wt_path"
  unset "WORKTREES[$perm]" 2>/dev/null || true
}

cleanup() {
  local perm
  echo ""
  echo "  Cleaning up worktrees..."
  for perm in "${!WORKTREES[@]}"; do
    _remove_worktree "$perm"
  done
}
trap cleanup EXIT INT TERM

# ── Worker launcher ───────────────────────────────────────────────────────────

_launch_worker() {
  local perm="$1"
  local name_prefix="tst${perm}"
  local wt_path="${WORKTREES[$perm]}"
  local aws_dir="${wt_path}/terraform/aws"
  local log="${RESULTS_DIR}/p${perm}-worker.log"

  WORKER_LOGS[$perm]="$log"

  (
    cd "$aws_dir"
    # Ensure scripts are executable in the worktree (git preserves permissions
    # but some copy mechanisms don't)
    chmod +x infra/scripts/*.sh 2>/dev/null || true
    exec ./infra/scripts/test-worker.sh "$perm" "$name_prefix" "$RESULTS_DIR" $DRY_RUN_FLAG
  ) >"$log" 2>&1 &

  WORKER_PIDS[$perm]=$!
  printf "  Launched P%s  pid=%-6s  prefix=%s\n" "$perm" "${WORKER_PIDS[$perm]}" "$name_prefix"
}

# ── Main scheduling loop ──────────────────────────────────────────────────────
# Classic worker-pool: fill slots up to MAX_PARALLEL, poll for completions,
# refill from the pending queue, repeat.

printf '\n── Launching ──\n\n'

PENDING=("${SELECTED_PERMS[@]}")
RUNNING=()

while [[ ${#PENDING[@]} -gt 0 || ${#RUNNING[@]} -gt 0 ]]; do

  # Fill up to MAX_PARALLEL slots
  while [[ ${#RUNNING[@]} -lt $MAX_PARALLEL && ${#PENDING[@]} -gt 0 ]]; do
    perm="${PENDING[0]}"
    PENDING=("${PENDING[@]:1}")
    _create_worktree "$perm"
    _launch_worker   "$perm"
    RUNNING+=("$perm")
  done

  # Check for completed workers (non-blocking poll)
  STILL_RUNNING=()
  for perm in "${RUNNING[@]}"; do
    pid="${WORKER_PIDS[$perm]:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      STILL_RUNNING+=("$perm")
    else
      # Worker finished — collect exit code
      set +e; wait "${pid:-0}" 2>/dev/null; wex=$?; set -e
      WORKER_EXIT[$perm]=$wex

      result="$RESULTS_DIR/p${perm}.json"
      if [[ -f "$result" ]]; then
        status=$(grep '"status"' "$result" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "unknown")
        dur=$(grep '"duration_seconds"' "$result" | sed 's/[^0-9]*\([0-9]*\).*/\1/' || echo "?")
        if [[ "$status" == "passed" ]]; then
          printf "  \033[32m✔\033[0m  P%s  %-8s  %ss\n" "$perm" "$status" "$dur"
        else
          printf "  \033[31m✘\033[0m  P%s  %-8s  %ss  → %s\n" "$perm" "$status" "$dur" "${WORKER_LOGS[$perm]}"
        fi
      else
        printf "  \033[31m✘\033[0m  P%s  no result file  → %s\n" "$perm" "${WORKER_LOGS[$perm]}"
        WORKER_EXIT[$perm]=1
      fi

      # Clean up worktree (unless --keep-on-failure and it failed)
      if [[ "${WORKER_EXIT[$perm]:-1}" -ne 0 && "$KEEP_ON_FAILURE" == "true" ]]; then
        printf "      Worktree kept for inspection: %s\n" "${WORKTREES[$perm]:-}"
      else
        _remove_worktree "$perm"
      fi
    fi
  done

  RUNNING=("${STILL_RUNNING[@]}")

  # Avoid busy-waiting
  [[ ${#PENDING[@]} -gt 0 || ${#RUNNING[@]} -gt 0 ]] && sleep 5

done

# ── Grand summary ─────────────────────────────────────────────────────────────

echo ""
printf '\033[1m════════════════════════════════════════════════════════\033[0m\n'
printf '\033[1m  Grand Summary\033[0m\n'
printf '\033[1m════════════════════════════════════════════════════════\033[0m\n'
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0
PERM_NAMES=(
  [1]="ALB + no TLS"
  [2]="ALB + ACM"
  [3]="ALB + HTTP-01"
  [4]="Istio + no TLS"
  [5]="Istio + DNS-01"
  [6]="Istio + domain change"
  [7]="destroy with DNS-01"
  [8]="Envoy Gateway + no TLS"
)

for perm in "${SELECTED_PERMS[@]}"; do
  result="$RESULTS_DIR/p${perm}.json"
  pname="${PERM_NAMES[$perm]:-P${perm}}"
  if [[ -f "$result" ]]; then
    status=$(grep '"status"'          "$result" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "unknown")
    dur=$(grep '"duration_seconds"'   "$result" | sed 's/[^0-9]*\([0-9]*\).*/\1/' || echo "?")
    if [[ "$status" == "passed" ]]; then
      printf "  \033[32m✔\033[0m  P%s  %-34s  %ss\n" "$perm" "$pname" "$dur"
      TOTAL_PASS=$((TOTAL_PASS + 1))
    else
      printf "  \033[31m✘\033[0m  P%s  %-34s  → see %s\n" "$perm" "$pname" "${WORKER_LOGS[$perm]:-$result}"
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
  else
    printf "  \033[31m✘\033[0m  P%s  %-34s  → no result file\n" "$perm" "$pname"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
done

echo ""
printf "  Results: %s\n" "$RESULTS_DIR"
echo ""

SUMMARY_LINE="parallel-${RUN_TS}  perms=${SELECTED_PERMS[*]}  passed=${TOTAL_PASS}  failed=${TOTAL_FAIL}"
echo "$SUMMARY_LINE" >> "$INFRA_DIR/logs/summary.log" 2>/dev/null || true

if [[ $TOTAL_FAIL -eq 0 ]]; then
  printf '  \033[32mAll %d permutation(s) PASSED\033[0m\n' "$TOTAL_PASS"
else
  printf '  \033[31m%d FAILED  /  %d passed\033[0m\n' "$TOTAL_FAIL" "$TOTAL_PASS"
  echo ""
  echo "  To inspect a failure:"
  echo "    Re-run with: ./infra/scripts/test-orchestrator.sh <N> --keep-on-failure"
  echo "    Then check:  tail -100 <results_dir>/pN-worker.log"
fi

echo ""
[[ $TOTAL_FAIL -eq 0 ]]
