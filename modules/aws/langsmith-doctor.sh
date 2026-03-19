#!/usr/bin/env bash
# shellcheck disable=SC2059
# langsmith-doctor.sh — Shell script fallback for langsmith-doctor.
#
# A single-file diagnostic tool for LangSmith self-hosted deployments.
# Covers ~80% of the Go binary's checks using only kubectl + bash.
#
# Dependencies:
#   Required: bash (4+), kubectl
#   Recommended: jq (graceful degradation without it)
#   Optional: openssl (TLS cert checks), curl (beacon check)
#
# Usage:
#   ./langsmith-doctor.sh                          # diagnose (default)
#   ./langsmith-doctor.sh diagnose                 # same
#   ./langsmith-doctor.sh diagnose app             # app-level checks
#   ./langsmith-doctor.sh bundle                   # support bundle
#   ./langsmith-doctor.sh --namespace myns diagnose

set -euo pipefail

# ── Cleanup Trap ──────────────────────────────────────────────────────────────

_CLEANUP_FILES=()
_CLEANUP_DIRS=()

cleanup() {
  for f in "${_CLEANUP_FILES[@]+"${_CLEANUP_FILES[@]}"}"; do
    rm -f "$f" 2>/dev/null || true
  done
  for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
    rm -rf "$d" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# ── Constants & Defaults ─────────────────────────────────────────────────────

NAMESPACE="langsmith"
RELEASE_NAME="langsmith"
KUBECONFIG_FLAG=""
CONTEXT_FLAG=""
VERBOSE=false
# Respect NO_COLOR env var convention (https://no-color.org/)
if [[ -n "${NO_COLOR+set}" ]]; then
  NO_COLOR=true
else
  NO_COLOR=false
fi
NO_REDACT=false
SKIP_HELM=false
SKIP_JOBS=false
SKIP_SERVICES=false
SKIP_INGRESS=false
SKIP_CLOUD=false
TAIL_LINES=1000
INCLUDE_LOGS=true
COMMAND=""
SUBCOMMAND=""

VERSION="0.1.0"

# Thresholds (match Go binary)
RESTART_THRESHOLD_WARN=5
RESTART_THRESHOLD_FAIL=20
MIN_K8S_MINOR=23

DOCS_BASE="https://docs.langchain.com/langsmith"

# Bad pod reasons (match k8s/pods.go)
BAD_POD_REASONS="CrashLoopBackOff ImagePullBackOff ErrImagePull CreateContainerConfigError"

# Core component definitions: "Name:Selector:ExpectedPort"
# Keep in sync with pkg/components/langsmith.go
CORE_COMPONENTS=(
  "Backend:app.kubernetes.io/component=langsmith-backend:1984"
  "Frontend:app.kubernetes.io/component=langsmith-frontend:8080"
  "Queue:app.kubernetes.io/component=langsmith-queue:8080"
  "Platform Backend:app.kubernetes.io/component=langsmith-platform-backend:1986"
  "ACE Backend:app.kubernetes.io/component=langsmith-ace-backend:1987"
  "Playground:app.kubernetes.io/component=langsmith-playground:1988"
  "ClickHouse:app.kubernetes.io/component=langsmith-clickhouse:8123"
  "Postgres:app.kubernetes.io/component=langsmith-postgres:5432"
  "Redis:app.kubernetes.io/component=langsmith-redis:6379"
)

# Addon definitions: "Name:Selector"
ADDON_COMPONENTS=(
  "Operator:app.kubernetes.io/component=langsmith-operator"
  "Listener:app.kubernetes.io/component=langsmith-listener"
  "Host Backend:app.kubernetes.io/component=langsmith-host-backend"
  "Ingest Queue:app.kubernetes.io/component=langsmith-ingest-queue"
  "Agent Builder Tool Server:app.kubernetes.io/component=langsmith-agent-builder-tool-server"
  "Agent Builder Trigger Server:app.kubernetes.io/component=langsmith-agent-builder-trigger-server"
)

# ── Color / Output Helpers ───────────────────────────────────────────────────

# Initialize to empty so set -u doesn't crash if warn()/error() are called
# before setup_colors (e.g. during parse_args).
RED="" GREEN="" YELLOW="" BOLD="" DIM="" RESET=""

setup_colors() {
  if [[ "$NO_COLOR" == true ]] || [[ ! -t 1 ]]; then
    RED="" GREEN="" YELLOW="" BOLD="" DIM="" RESET=""
  else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
  fi
}

info()    { printf "${BOLD}==> %s${RESET}\n" "$*"; }
warn()    { printf "${YELLOW}WARN:${RESET} %s\n" "$*" >&2; }
error()   { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; }

# Check result counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

record_pass() {
  ((PASS_COUNT++)) || true
  printf "  ${GREEN}OK${RESET}    %s: %s\n" "$1" "$2"
}

record_fail() {
  local name="$1" message="$2" remediation="${3:-}" docs="${4:-}"
  ((FAIL_COUNT++)) || true
  printf "  ${RED}FAIL${RESET}  %s: %s\n" "$name" "$message"
  if [[ -n "$remediation" ]]; then
    printf "  ${YELLOW}      → %s${RESET}\n" "$remediation"
  fi
  if [[ -n "$docs" ]]; then
    printf "  ${DIM}      See: %s${RESET}\n" "$docs"
  fi
}

record_warn() {
  local name="$1" message="$2" remediation="${3:-}" docs="${4:-}"
  ((WARN_COUNT++)) || true
  printf "  ${YELLOW}WARN${RESET}  %s: %s\n" "$name" "$message"
  if [[ -n "$remediation" ]]; then
    printf "  ${YELLOW}      → %s${RESET}\n" "$remediation"
  fi
  if [[ -n "$docs" ]]; then
    printf "  ${DIM}      See: %s${RESET}\n" "$docs"
  fi
}

record_detail() {
  printf "  ${DIM}      %s${RESET}\n" "$1"
}

section() {
  printf "\n${BOLD}%s${RESET}\n" "$1"
}

print_summary() {
  local elapsed="${1:-}"
  local total=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
  echo
  if [[ -n "$elapsed" ]]; then
    printf "${BOLD}--- Summary (%s) ---${RESET}\n" "$elapsed"
  else
    printf "${BOLD}--- Summary ---${RESET}\n"
  fi
  printf "  Passed: %d/%d\n" "$PASS_COUNT" "$total"
  if [[ $FAIL_COUNT -gt 0 ]]; then
    printf "  ${RED}Failed: %d${RESET}\n" "$FAIL_COUNT"
  fi
  if [[ $WARN_COUNT -gt 0 ]]; then
    printf "  ${YELLOW}Warnings: %d${RESET}\n" "$WARN_COUNT"
  fi
}

# ── Dependency Detection ─────────────────────────────────────────────────────

HAS_JQ=false
HAS_OPENSSL=false
HAS_CURL=false

detect_dependencies() {
  command -v kubectl >/dev/null 2>&1 || { error "kubectl is required but not found in PATH"; exit 1; }
  command -v jq >/dev/null 2>&1 && HAS_JQ=true
  command -v openssl >/dev/null 2>&1 && HAS_OPENSSL=true
  command -v curl >/dev/null 2>&1 && HAS_CURL=true

  _detect_base64
  if [[ -z "$_BASE64_DECODE_CMD" ]]; then
    warn "No working base64 decoder found — TLS certificate checks will be skipped."
  fi

  if [[ "$HAS_JQ" == false ]]; then
    warn "jq not found — some checks will use degraded parsing. Install jq for best results."
  fi
}

# Portable base64 decode
#
# Platform landscape:
#   GNU coreutils (Linux, WSL):  base64 -d
#   BusyBox (Alpine, minimal):   base64 -d
#   BSD/macOS (older, <13):      base64 -D   (-d not recognized)
#   BSD/macOS (Ventura+ >=13):   base64 -d   (both -d and -D work)
#   openssl (everywhere):        openssl base64 -d
#
# Strategy: probe once with a known value at startup, cache the working
# flag, and reuse it. This avoids the fragile `cmd1 || cmd2` pattern where
# the first command's behavior with stdin on failure is platform-dependent.
_BASE64_DECODE_CMD=""

_detect_base64() {
  local test_input="dGVzdA=="  # "test" in base64
  # Prefer base64 (faster, no openssl dep for non-TLS paths)
  if echo "$test_input" | base64 -d 2>/dev/null | grep -q "^test$"; then
    _BASE64_DECODE_CMD="base64 -d"
  elif echo "$test_input" | base64 -D 2>/dev/null | grep -q "^test$"; then
    _BASE64_DECODE_CMD="base64 -D"
  elif echo "$test_input" | openssl base64 -d 2>/dev/null | grep -q "^test$"; then
    _BASE64_DECODE_CMD="openssl base64 -d"
  fi
}

base64_decode() {
  if [[ -n "$_BASE64_DECODE_CMD" ]]; then
    $_BASE64_DECODE_CMD
  else
    # Should not happen — _detect_base64 covers all known platforms.
    # Last-resort fallback preserving old behavior.
    base64 -d 2>/dev/null || base64 -D 2>/dev/null
  fi
}

# ── kubectl Helpers ──────────────────────────────────────────────────────────

# Build kubectl base args into KUBECTL_ARGS array (space-safe)
build_kubectl_args() {
  KUBECTL_ARGS=()
  if [[ -n "$KUBECONFIG_FLAG" ]]; then
    KUBECTL_ARGS+=("--kubeconfig=$KUBECONFIG_FLAG")
  fi
  if [[ -n "$CONTEXT_FLAG" ]]; then
    KUBECTL_ARGS+=("--context=$CONTEXT_FLAG")
  fi
}

# Run kubectl with common flags
kube() {
  kubectl ${KUBECTL_ARGS[@]+"${KUBECTL_ARGS[@]}"} "$@"
}

# Run kubectl and capture stderr for permission detection
kube_get_json() {
  local errfile
  errfile=$(mktemp)
  _CLEANUP_FILES+=("$errfile")
  local result
  if result=$(kubectl ${KUBECTL_ARGS[@]+"${KUBECTL_ARGS[@]}"} "$@" -o json 2>"$errfile"); then
    rm -f "$errfile"
    echo "$result"
    return 0
  else
    local err
    err=$(cat "$errfile")
    rm -f "$errfile"
    if echo "$err" | grep -qi "forbidden"; then
      echo "PERMISSION_DENIED"
      return 1
    fi
    echo "ERROR: $err"
    return 1
  fi
}

# Resolve selectors: replace "langsmith-" with "${RELEASE_NAME}-" if non-default
resolve_selector() {
  local selector="$1"
  if [[ "$RELEASE_NAME" == "langsmith" ]]; then
    echo "$selector"
  else
    echo "${selector//langsmith-/${RELEASE_NAME}-}"
  fi
}

# ── Status Overview ──────────────────────────────────────────────────────────

run_status() {
  section "LangSmith"

  # Cluster connectivity
  if ! kube cluster-info >/dev/null 2>&1; then
    printf "  %-20s ${RED}%s${RESET}\n" "Cluster" "offline"
    record_fail "cluster_connectivity" "Cluster API unreachable" \
      "Ensure the Kubernetes cluster is running and accessible. Verify your kubeconfig and network connectivity." \
      "$DOCS_BASE/diagnostics-self-hosted"
    return 0
  fi
  CLUSTER_ONLINE=true
  printf "  %-20s ${GREEN}%s${RESET}\n" "Cluster" "online"

  # K8s version
  local k8s_version
  if [[ "$HAS_JQ" == true ]]; then
    k8s_version=$(kube version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"') || k8s_version="unknown"
  else
    # Without jq, extract gitVersion with grep/sed fallback
    k8s_version=$(kube version -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | head -1 | sed 's/.*"gitVersion": *"//;s/"//') || k8s_version="unknown"
    [[ -z "$k8s_version" ]] && k8s_version="unknown"
  fi
  printf "  %-20s %s\n" "K8s Version" "$k8s_version"

  # Cloud provider (best-effort from node labels)
  if [[ "$SKIP_CLOUD" == false ]]; then
    local cloud="unknown"
    local node_json
    node_json=$(kube_get_json get nodes 2>/dev/null) || true
    if [[ -n "$node_json" && "$node_json" != "PERMISSION_DENIED" && "$node_json" != ERROR* && "$HAS_JQ" == true ]]; then
      local provider_id
      provider_id=$(echo "$node_json" | jq -r '.items[0].spec.providerID // ""' 2>/dev/null) || true
      if [[ "$provider_id" == aws* ]]; then cloud="AWS (EKS)"
      elif [[ "$provider_id" == gce* ]]; then cloud="GCP (GKE)"
      elif [[ "$provider_id" == azure* ]]; then cloud="Azure (AKS)"
      elif echo "$node_json" | jq -e '.items[0].metadata.labels["node.openshift.io/os_id"]' >/dev/null 2>&1; then cloud="OpenShift"
      fi
    fi
    if [[ "$cloud" != "unknown" ]]; then
      printf "  %-20s %s\n" "Cloud" "$cloud"
    fi
  fi

  # Helm release (requires secrets RBAC)
  if [[ "$SKIP_HELM" == false ]]; then
    local helm_json
    helm_json=$(kube_get_json get secrets -n "$NAMESPACE" -l "owner=helm,name=${RELEASE_NAME}" 2>/dev/null) || true
    if [[ "$helm_json" == "PERMISSION_DENIED" ]]; then
      printf "  %-20s ${YELLOW}%s${RESET}\n" "Helm" "permission denied (secrets access required)"
    elif [[ -n "$helm_json" && "$HAS_JQ" == true ]]; then
      local helm_count
      helm_count=$(echo "$helm_json" | jq '.items | length' 2>/dev/null) || helm_count=0
      if [[ "$helm_count" -gt 0 ]]; then
        local helm_status
        helm_status=$(echo "$helm_json" | jq -r '.items[-1].metadata.labels.status // "unknown"' 2>/dev/null) || helm_status="unknown"
        local helm_version
        helm_version=$(echo "$helm_json" | jq -r '.items[-1].metadata.labels.version // "?"' 2>/dev/null) || helm_version="?"
        printf "  %-20s ${GREEN}%s${RESET}\n" "Helm" "release found (status=$helm_status, revision=$helm_version)"
      else
        printf "  %-20s ${RED}%s${RESET}\n" "Helm" "no release found"
      fi
    fi
  fi

  # Core component pod counts
  section "Components"
  for comp in "${CORE_COMPONENTS[@]}"; do
    local name selector _port
    IFS=: read -r name selector _port <<< "$comp"
    selector=$(resolve_selector "$selector")
    local pod_json
    pod_json=$(kube_get_json get pods -n "$NAMESPACE" -l "$selector" 2>/dev/null) || true
    if [[ -z "$pod_json" || "$pod_json" == "PERMISSION_DENIED" || "$pod_json" == ERROR* ]]; then
      printf "  %-20s ${DIM}%s${RESET}\n" "$name" "n/a"
      continue
    fi
    if [[ "$HAS_JQ" == true ]]; then
      local total running pending failed
      total=$(echo "$pod_json" | jq '.items | length' 2>/dev/null) || total=0
      running=$(echo "$pod_json" | jq '[.items[] | select(.status.phase == "Running" or .status.phase == "Succeeded")] | length' 2>/dev/null) || running=0
      pending=$(echo "$pod_json" | jq '[.items[] | select(.status.phase == "Pending")] | length' 2>/dev/null) || pending=0
      failed=$(echo "$pod_json" | jq "[.items[] | select(.status.phase != \"Running\" and .status.phase != \"Succeeded\" and .status.phase != \"Pending\")] | length" 2>/dev/null) || failed=0

      if [[ "$total" -eq 0 ]]; then
        printf "  %-20s ${YELLOW}%s${RESET}\n" "$name" "no pods"
      elif [[ "$failed" -gt 0 || "$running" -eq 0 ]]; then
        local text="$running/$total Running"
        [[ "$pending" -gt 0 ]] && text="$text, $pending Pending"
        [[ "$failed" -gt 0 ]] && text="$text, $failed Failed/Error"
        printf "  %-20s ${RED}%s${RESET}\n" "$name" "$text"
        # Show anomalies
        echo "$pod_json" | jq -r --arg bad "$BAD_POD_REASONS" --arg red "$RED" --arg reset "$RESET" '
          .items[] |
          (.status.containerStatuses // []) + (.status.initContainerStatuses // []) |
          .[] | select(.state.waiting.reason != null) |
          select(($bad | split(" ")) as $reasons | .state.waiting.reason as $r | $reasons | any(. == $r)) |
          "    " + $red + "↳ " + .name + ": " + .state.waiting.reason + $reset
        ' 2>/dev/null || true
      elif [[ "$pending" -gt 0 ]]; then
        printf "  %-20s ${YELLOW}%d/%d Running, %d Pending${RESET}\n" "$name" "$running" "$total" "$pending"
      else
        printf "  %-20s ${GREEN}%d/%d Running${RESET}\n" "$name" "$running" "$total"
      fi
    else
      # Degraded mode without jq — count "phase" keys as a proxy for pod count
      local count
      count=$(echo "$pod_json" | grep -c '"phase"' 2>/dev/null) || count=0
      printf "  %-20s %s pods\n" "$name" "$count"
    fi
  done

  # Addon components
  local any_addon=false
  for comp in "${ADDON_COMPONENTS[@]}"; do
    local name selector
    IFS=: read -r name selector <<< "$comp"
    selector=$(resolve_selector "$selector")
    local pod_count
    pod_count=$(kube get pods -n "$NAMESPACE" -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ') || pod_count=0
    if [[ "$pod_count" -gt 0 ]]; then
      if [[ "$any_addon" == false ]]; then
        section "Addons"
        any_addon=true
      fi
      printf "  %-20s ${GREEN}%d pod(s)${RESET}\n" "$name" "$pod_count"
    fi
  done
}

# ── Workload Checks ─────────────────────────────────────────────────────────

check_cluster_connectivity() {
  if kube cluster-info >/dev/null 2>&1; then
    record_pass "cluster_connectivity" "Cluster API reachable"
    return 0
  else
    record_fail "cluster_connectivity" "Cluster API unreachable" \
      "Ensure the Kubernetes cluster is running and accessible. Verify your kubeconfig and network connectivity." \
      "$DOCS_BASE/diagnostics-self-hosted"
    return 1
  fi
}

check_namespace() {
  local ns_exists
  ns_exists=$(kube get namespace "$NAMESPACE" -o jsonpath='{.metadata.name}' 2>/dev/null) || true
  if [[ -z "$ns_exists" ]]; then
    record_fail "namespace" "Namespace \"$NAMESPACE\" not found" \
      "Verify the namespace exists: kubectl get namespace $NAMESPACE. Use --namespace to specify a different namespace." \
      "$DOCS_BASE/diagnostics-self-hosted"
    return 1
  fi

  # Namespace exists — check if it has any LangSmith pods at all.
  # Distinguish RBAC failures from genuinely empty namespaces.
  local pod_output
  pod_output=$(kube get pods -n "$NAMESPACE" --no-headers 2>&1) || true
  if echo "$pod_output" | grep -qi "forbidden"; then
    record_warn "namespace" "Namespace \"$NAMESPACE\" exists (pod listing requires additional RBAC)" \
      "Apply deploy/rbac.yaml to grant pod list permissions, or use --skip to bypass checks that need it." \
      "$DOCS_BASE/diagnostics-self-hosted"
  else
    local pod_count
    pod_count=$(echo "$pod_output" | grep -Ecv '^$|^No resources found' 2>/dev/null) || pod_count=0
    if [[ "$pod_count" -eq 0 ]]; then
      record_warn "namespace" "Namespace \"$NAMESPACE\" exists but contains no pods" \
        "Is this the right namespace? Use --namespace to target a different one." \
        "$DOCS_BASE/diagnostics-self-hosted"
    else
      record_pass "namespace" "Namespace \"$NAMESPACE\" exists ($pod_count pods)"
    fi
  fi
  return 0
}

check_cluster_version() {
  if [[ "$HAS_JQ" == false ]]; then
    record_warn "cluster_version" "Unable to check version (jq not available)" ""
    return
  fi
  local version_json
  version_json=$(kube version -o json 2>/dev/null) || true
  if [[ -z "$version_json" ]]; then
    record_warn "cluster_version" "Unable to determine Kubernetes server version" \
      "Verify the cluster is healthy and the API server is responding." \
      "$DOCS_BASE/kubernetes"
    return
  fi
  local minor
  minor=$(echo "$version_json" | jq -r '.serverVersion.minor // "0"' | tr -dc '0-9') || minor=0
  if [[ -z "$minor" || "$minor" -eq 0 ]]; then
    record_warn "cluster_version" "Unable to parse Kubernetes server version" \
      "Verify the cluster is healthy." "$DOCS_BASE/kubernetes"
  elif [[ "$minor" -lt "$MIN_K8S_MINOR" ]]; then
    record_warn "cluster_version" "Kubernetes v1.${minor} is below minimum recommended v1.${MIN_K8S_MINOR}" \
      "Upgrade to Kubernetes v1.23 or later. LangSmith is tested on v1.23+." \
      "$DOCS_BASE/kubernetes"
  else
    record_pass "cluster_version" "Kubernetes v1.${minor} (>= v1.${MIN_K8S_MINOR})"
  fi
}

check_deployments() {
  local deploy_json
  deploy_json=$(kube_get_json get deployments -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$deploy_json" == "PERMISSION_DENIED" ]]; then
    record_fail "deployments" "Permission denied listing deployments" \
      "Verify RBAC permissions allow listing deployments in the target namespace." \
      "$DOCS_BASE/diagnostics-self-hosted"
    return
  fi
  if [[ -z "$deploy_json" || "$deploy_json" == ERROR* ]]; then
    record_fail "deployments" "Error listing deployments" \
      "Verify RBAC permissions." "$DOCS_BASE/diagnostics-self-hosted"
    return
  fi
  if [[ "$HAS_JQ" == false ]]; then
    record_warn "deployments" "Deployment checks require jq" ""
    return
  fi

  while IFS=$'\t' read -r name replicas available ready generation observed; do
    [[ -z "$name" ]] && continue
    if [[ "$replicas" -eq 0 ]]; then
      record_warn "deployment:$NAMESPACE/$name" "Scaled to 0 replicas — deployment is inactive" \
        "This deployment has 0 desired replicas. If this is unintentional, scale it back up: kubectl scale deployment $name -n $NAMESPACE --replicas=1" \
        "$DOCS_BASE/diagnostics-self-hosted"
    elif [[ "$available" -ge "$replicas" ]]; then
      if [[ "$VERBOSE" == true ]]; then
        record_pass "deployment:$NAMESPACE/$name" "${available}/${replicas} available, generation ${observed}/${generation}"
      fi
    else
      record_fail "deployment:$NAMESPACE/$name" "${available}/${replicas} available, generation ${observed}/${generation}" \
        "Check pod status and logs for the failing deployment." \
        "$DOCS_BASE/diagnostics-self-hosted"
    fi
  done < <(echo "$deploy_json" | jq -r '.items[] | [.metadata.name, (.spec.replicas // 0 | tostring), (.status.availableReplicas // 0 | tostring), (.status.readyReplicas // 0 | tostring), (.metadata.generation // 0 | tostring), (.status.observedGeneration // 0 | tostring)] | @tsv' 2>/dev/null)
}

check_statefulsets() {
  local sts_json
  sts_json=$(kube_get_json get statefulsets -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$sts_json" == "PERMISSION_DENIED" ]]; then
    record_fail "statefulsets" "Permission denied listing statefulsets" \
      "Verify RBAC permissions." "$DOCS_BASE/diagnostics-self-hosted"
    return
  fi
  if [[ -z "$sts_json" || "$sts_json" == ERROR* ]]; then
    record_fail "statefulsets" "Error listing statefulsets" "" ""
    return
  fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  while IFS=$'\t' read -r name replicas ready updated; do
    [[ -z "$name" ]] && continue
    if [[ "$replicas" -eq 0 ]]; then
      record_warn "statefulset:$NAMESPACE/$name" "Scaled to 0 replicas — statefulset is inactive" \
        "This statefulset has 0 desired replicas. If this is unintentional, scale it back up: kubectl scale statefulset $name -n $NAMESPACE --replicas=1" \
        "$DOCS_BASE/diagnostics-self-hosted"
    elif [[ "$ready" -ge "$replicas" ]]; then
      if [[ "$VERBOSE" == true ]]; then
        record_pass "statefulset:$NAMESPACE/$name" "${ready}/${replicas} ready, ${updated}/${replicas} updated"
      fi
    else
      record_fail "statefulset:$NAMESPACE/$name" "${ready}/${replicas} ready, ${updated}/${replicas} updated" \
        "Check pod status and logs for the failing statefulset." \
        "$DOCS_BASE/diagnostics-self-hosted"
    fi
  done < <(echo "$sts_json" | jq -r '.items[] | [.metadata.name, (.spec.replicas // 0 | tostring), (.status.readyReplicas // 0 | tostring), (.status.updatedReplicas // 0 | tostring)] | @tsv' 2>/dev/null)
}

check_daemonsets() {
  local ds_json
  ds_json=$(kube_get_json get daemonsets -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$ds_json" == "PERMISSION_DENIED" ]]; then return; fi
  if [[ -z "$ds_json" || "$ds_json" == ERROR* ]]; then return; fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  while IFS=$'\t' read -r name desired ready; do
    [[ -z "$name" ]] && continue
    if [[ "$desired" -eq 0 ]]; then
      record_warn "daemonset:$NAMESPACE/$name" "Desired 0 pods — no matching nodes" \
        "This daemonset has 0 desired pods. Verify nodeSelector/tolerations if this is unexpected." \
        "$DOCS_BASE/diagnostics-self-hosted"
    elif [[ "$ready" -ge "$desired" ]]; then
      [[ "$VERBOSE" == true ]] && record_pass "daemonset:$NAMESPACE/$name" "${ready}/${desired} ready"
    else
      record_fail "daemonset:$NAMESPACE/$name" "${ready}/${desired} ready" \
        "Check pod status and logs for the failing daemonset." \
        "$DOCS_BASE/diagnostics-self-hosted"
    fi
  done < <(echo "$ds_json" | jq -r '.items[] | [.metadata.name, (.status.desiredNumberScheduled // 0 | tostring), (.status.numberReady // 0 | tostring)] | @tsv' 2>/dev/null)
}

check_pods() {
  local pods_json
  pods_json=$(kube_get_json get pods -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$pods_json" == "PERMISSION_DENIED" ]]; then
    record_fail "pods" "Permission denied listing pods" \
      "Verify RBAC permissions." "$DOCS_BASE/diagnostics-self-hosted"
    return
  fi
  if [[ -z "$pods_json" || "$pods_json" == ERROR* ]]; then
    record_fail "pods" "Error listing pods" "" ""
    return
  fi
  if [[ "$HAS_JQ" == false ]]; then
    # Degraded: just check for obvious bad states in raw output
    if echo "$pods_json" | grep -q "CrashLoopBackOff\|ImagePullBackOff\|ErrImagePull"; then
      record_fail "pods" "Bad pod state(s) detected (install jq for details)" "" ""
    fi
    return
  fi

  # Check each pod for bad states, readiness, and restart counts
  while IFS=$'\t' read -r pod phase bad_state ready; do
    [[ -z "$pod" ]] && continue
    if [[ "$bad_state" != "none" ]]; then
      record_fail "pod:$NAMESPACE/$pod" "Bad state: $bad_state" \
        "Check pod events and container logs: kubectl describe pod $pod -n $NAMESPACE && kubectl logs $pod -n $NAMESPACE" \
        "$DOCS_BASE/diagnostics-self-hosted"
    elif [[ "$ready" == "false" && "$phase" == "Running" ]]; then
      record_fail "pod:$NAMESPACE/$pod" "Running but not ready" \
        "Check readiness probe configuration: kubectl describe pod $pod -n $NAMESPACE" \
        "$DOCS_BASE/diagnostics-self-hosted"
    elif [[ "$ready" == "true" ]]; then
      [[ "$VERBOSE" == true ]] && record_pass "pod:$NAMESPACE/$pod" "Running and ready"
    else
      record_fail "pod:$NAMESPACE/$pod" "Phase: $phase" \
        "Investigate pod events and scheduling: kubectl describe pod $pod -n $NAMESPACE" \
        "$DOCS_BASE/diagnostics-self-hosted"
    fi
  done < <(echo "$pods_json" | jq -r '
    .items[] |
    select(.status.phase != "Succeeded") |
    .metadata.name as $pod |
    (
      [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]] |
      map(select(.state.waiting.reason != null)) |
      map(select(.state.waiting.reason == "CrashLoopBackOff" or
                  .state.waiting.reason == "ImagePullBackOff" or
                  .state.waiting.reason == "ErrImagePull" or
                  .state.waiting.reason == "CreateContainerConfigError")) |
      if length > 0 then .[0].state.waiting.reason else null end
    ) as $bad_state |
    (
      [(.status.conditions // [])[] | select(.type == "Ready" and .status == "True")] | length > 0
    ) as $ready |
    .status.phase as $phase |
    [$pod, ($phase // "Unknown"), (if $bad_state then $bad_state else "none" end), (if $ready then "true" else "false" end)] | @tsv
  ' 2>/dev/null)

  # Container restart counts
  while IFS=$'\t' read -r pod container restarts kind; do
    [[ -z "$pod" ]] && continue
    local check_name="pod_restarts:$NAMESPACE/$pod/$container"
    if [[ "$restarts" -gt "$RESTART_THRESHOLD_FAIL" ]]; then
      record_fail "$check_name" "$kind \"$container\" has restarted $restarts times" \
        "Restart count exceeds failure threshold; the container is likely crash-looping."
    else
      record_warn "$check_name" "$kind \"$container\" has restarted $restarts times" \
        "Elevated restart count may indicate intermittent crashes."
    fi
  done < <(echo "$pods_json" | jq -r '
    .items[] |
    select(.status.phase != "Succeeded") |
    .metadata.name as $pod |
    (
      [
        ((.status.containerStatuses // [])[] | {name: .name, restarts: .restartCount, init: false}),
        ((.status.initContainerStatuses // [])[] | {name: .name, restarts: .restartCount, init: true})
      ] |
      .[] | select(.restarts > '"$RESTART_THRESHOLD_WARN"') |
      [$pod, .name, (.restarts | tostring), (if .init then "init container" else "container" end)]
    ) | @tsv
  ' 2>/dev/null)

  # Init container failures (terminated with non-zero exit only;
  # waiting-state failures are already caught by the pod-level check above)
  while IFS=$'\t' read -r pod container reason _message; do
    [[ -z "$pod" ]] && continue
    local code="${reason#exited:}"
    record_fail "init_container:$NAMESPACE/$pod/$container" "Init container $container exited with code $code" \
      "Check init container logs: kubectl logs $pod -c $container -n $NAMESPACE" \
      "$DOCS_BASE/diagnostics-self-hosted"
  done < <(echo "$pods_json" | jq -r '
    .items[] |
    select(.status.phase != "Succeeded") |
    .metadata.name as $pod |
    (.status.initContainerStatuses // [])[] |
    if .state.terminated != null and .state.terminated.exitCode != 0
    then
      [$pod, .name, ("exited:" + (.state.terminated.exitCode | tostring)), (.state.terminated.message // "")] | @tsv
    else
      empty
    end
  ' 2>/dev/null)
}

check_jobs() {
  if [[ "$SKIP_JOBS" == true ]]; then return; fi

  local jobs_json
  jobs_json=$(kube_get_json get jobs -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$jobs_json" == "PERMISSION_DENIED" ]]; then
    record_fail "jobs" "Permission denied listing jobs" \
      "Verify RBAC permissions." "$DOCS_BASE/self-host-upgrades"
    return
  fi
  if [[ -z "$jobs_json" || "$jobs_json" == ERROR* ]]; then return; fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  while IFS=$'\t' read -r name completions succeeded failed complete; do
    [[ -z "$name" ]] && continue
    local msg="${succeeded}/${completions} succeeded"
    [[ "$failed" -gt 0 ]] && msg="$msg, $failed failed"

    if [[ "$complete" == "true" ]]; then
      [[ "$VERBOSE" == true ]] && record_pass "job:$NAMESPACE/$name" "$msg"
    else
      # Migration-specific remediation
      local remediation=""
      case "$name" in
        *-backend-migrations*) remediation="This is the Postgres (Alembic) migration Job. Services will crash-loop until migrations complete. Check logs: kubectl logs -l job-name=$name -n $NAMESPACE" ;;
        *-ch-migrations*) remediation="This is the ClickHouse migration Job. Trace ingestion may fail until complete. Check logs: kubectl logs -l job-name=$name -n $NAMESPACE" ;;
        *-config-migrations*) remediation="This is the feedback config migration Job. Check logs: kubectl logs -l job-name=$name -n $NAMESPACE" ;;
        *-fb-migrations*) remediation="This is the feedback data migration Job. Check logs: kubectl logs -l job-name=$name -n $NAMESPACE" ;;
        *) remediation="Check the Job's pod logs: kubectl logs -l job-name=$name -n $NAMESPACE" ;;
      esac
      record_fail "job:$NAMESPACE/$name" "$msg" "$remediation" "$DOCS_BASE/self-host-upgrades"
    fi
  done < <(echo "$jobs_json" | jq -r '
    .items[] |
    [
      .metadata.name,
      (.spec.completions // 1 | tostring),
      (.status.succeeded // 0 | tostring),
      (.status.failed // 0 | tostring),
      (if (.status.succeeded // 0) >= (.spec.completions // 1) then "true" else "false" end)
    ] | @tsv
  ' 2>/dev/null)
}

run_workload_checks() {
  section "Workload Checks"
  check_deployments
  check_statefulsets
  check_daemonsets
  check_pods
  check_jobs
}

# ── Helm & Config Checks ────────────────────────────────────────────────────

check_helm_release() {
  if [[ "$SKIP_HELM" == true ]]; then return; fi

  local helm_json
  helm_json=$(kube_get_json get secrets -n "$NAMESPACE" -l "owner=helm,name=${RELEASE_NAME}" 2>/dev/null) || true

  if [[ "$helm_json" == "PERMISSION_DENIED" ]]; then
    record_warn "helm_release:$RELEASE_NAME" "Helm release check skipped: permission denied" \
      "Apply deploy/rbac-full.yaml to grant secrets access for Helm release detection."
    return
  fi
  if [[ -z "$helm_json" || "$helm_json" == ERROR* ]]; then
    record_fail "helm_release:$RELEASE_NAME" "Error checking Helm release" \
      "Verify the Helm release exists in the target namespace." \
      "$DOCS_BASE/kubernetes"
    return
  fi

  if [[ "$HAS_JQ" == false ]]; then
    # Without jq we know the secret list was returned (passed checks above)
    # but can't parse the count — report a degraded pass
    record_pass "helm_release:$RELEASE_NAME" "Helm release secret(s) found (install jq for details)"
    return
  fi

  local count=0
  count=$(echo "$helm_json" | jq '.items | length' 2>/dev/null) || count=0

  if [[ "$count" -gt 0 ]]; then
    record_pass "helm_release:$RELEASE_NAME" "Helm release found"
  else
    record_fail "helm_release:$RELEASE_NAME" "Helm release not found" \
      "Install LangSmith using the Helm chart, or verify the release name and namespace are correct." \
      "$DOCS_BASE/kubernetes"
  fi
}

check_configmap() {
  local cm_name="${RELEASE_NAME}-config"
  local cm_json
  cm_json=$(kube_get_json get configmap "$cm_name" -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$cm_json" == "PERMISSION_DENIED" ]]; then
    record_warn "configmap:$cm_name" "Error reading ConfigMap $cm_name: permission denied" \
      "Verify RBAC permissions allow reading configmaps in the target namespace." \
      "$DOCS_BASE/kubernetes"
    return
  fi
  if [[ -z "$cm_json" || "$cm_json" == ERROR* ]]; then
    record_warn "configmap:$cm_name" "ConfigMap $cm_name not found" \
      "Verify the Helm release is installed and the release name matches." \
      "$DOCS_BASE/kubernetes"
    return
  fi
  if [[ "$HAS_JQ" == false ]]; then
    record_pass "configmap:$cm_name" "ConfigMap $cm_name exists (install jq for value validation)"
    return
  fi

  local had_issues=false

  # AUTH_TYPE
  local auth_type
  auth_type=$(echo "$cm_json" | jq -r '.data.AUTH_TYPE // ""' 2>/dev/null) || auth_type=""
  if [[ -n "$auth_type" && "$auth_type" != "none" && "$auth_type" != "oauth" && "$auth_type" != "mixed" ]]; then
    record_warn "configmap:$cm_name:AUTH_TYPE" "AUTH_TYPE is \"$auth_type\" (expected one of: none, oauth, mixed)" \
      "Check your Helm values under config.authType and config.oauth.enabled." \
      "$DOCS_BASE/kubernetes"
    had_issues=true
  fi

  # IS_SELF_HOSTED
  local is_self_hosted
  is_self_hosted=$(echo "$cm_json" | jq -r '.data.IS_SELF_HOSTED // ""' 2>/dev/null) || is_self_hosted=""
  if [[ -n "$is_self_hosted" && "$is_self_hosted" != "true" ]]; then
    record_warn "configmap:$cm_name:IS_SELF_HOSTED" "IS_SELF_HOSTED is \"$is_self_hosted\" (expected \"true\")" \
      "Set IS_SELF_HOSTED=true. This is normally set automatically by the Helm chart." \
      "$DOCS_BASE/kubernetes"
    had_issues=true
  fi

  # Critical endpoints
  for key in GO_ENDPOINT SMITH_BACKEND_ENDPOINT; do
    local val
    val=$(echo "$cm_json" | jq -r ".data.${key} // \"\"" 2>/dev/null) || val=""
    if [[ -z "$val" ]]; then
      record_warn "configmap:$cm_name:$key" "ConfigMap $cm_name is missing or empty for $key" \
        "$key is required for inter-service communication. Verify the Helm chart is generating this value correctly." \
        "$DOCS_BASE/kubernetes"
      had_issues=true
    fi
  done

  if [[ "$had_issues" == false ]]; then
    record_pass "configmap:$cm_name" "ConfigMap $cm_name exists with expected keys"
  fi
}

run_helm_config_checks() {
  section "Helm & Configuration"
  check_helm_release
  check_configmap
}

# ── Networking Checks ────────────────────────────────────────────────────────

check_services() {
  if [[ "$SKIP_SERVICES" == true ]]; then return; fi

  local svc_json
  svc_json=$(kube_get_json get services -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$svc_json" == "PERMISSION_DENIED" ]]; then
    record_fail "services" "Permission denied listing services" \
      "Verify RBAC permissions." "$DOCS_BASE/self-host-ingress"
    return
  fi
  if [[ -z "$svc_json" || "$svc_json" == ERROR* ]]; then return; fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  # Get endpoints to check service health
  local ep_json
  ep_json=$(kube_get_json get endpoints -n "$NAMESPACE" 2>/dev/null) || ep_json=""
  local ep_usable=false
  if [[ -n "$ep_json" && "$ep_json" != "PERMISSION_DENIED" && "$ep_json" != ERROR* ]]; then
    ep_usable=true
  fi

  while IFS=$'\t' read -r name svc_type _cluster_ip; do
    [[ -z "$name" ]] && continue
    # Check if endpoints exist
    local has_endpoints=false
    if [[ "$HAS_JQ" == true && "$ep_usable" == true ]]; then
      local ep_count
      ep_count=$(echo "$ep_json" | jq -r --arg name "$name" '[.items[] | select(.metadata.name == $name) | (.subsets // [])[] | (.addresses // []) | length] | add // 0' 2>/dev/null) || ep_count=0
      [[ -n "$ep_count" && "$ep_count" -gt 0 ]] && has_endpoints=true
    fi

    local ready=true
    if [[ "$has_endpoints" == false && "$ep_usable" == true && "$svc_type" != "ExternalName" ]]; then
      ready=false
    fi

    if [[ "$ready" == true ]]; then
      if [[ "$svc_type" == "ExternalName" ]]; then
        [[ "$VERBOSE" == true ]] && record_pass "service:$NAMESPACE/$name" "type=ExternalName (no endpoints expected)"
      elif [[ "$ep_usable" == true ]]; then
        [[ "$VERBOSE" == true ]] && record_pass "service:$NAMESPACE/$name" "type=$svc_type, endpoints=$has_endpoints"
      else
        [[ "$VERBOSE" == true ]] && record_pass "service:$NAMESPACE/$name" "type=$svc_type (endpoint check skipped)"
      fi
    elif [[ "$svc_type" == "LoadBalancer" ]]; then
      # Check for pending LB address
      local has_address
      has_address=$(echo "$svc_json" | jq -r --arg name "$name" '.items[] | select(.metadata.name == $name) | if (.status.loadBalancer.ingress // []) | length > 0 then "true" else "false" end' 2>/dev/null) || has_address="false"
      if [[ "$has_address" == "false" ]]; then
        record_warn "service:$NAMESPACE/$name" "type=LoadBalancer, address=pending" \
          "Install a LoadBalancer provisioner (e.g. MetalLB) or switch to ingress/NodePort." \
          "$DOCS_BASE/self-host-ingress"
      else
        record_fail "service:$NAMESPACE/$name" "type=$svc_type, endpoints=$has_endpoints" \
          "Verify the service has backing pods with ready endpoints." \
          "$DOCS_BASE/self-host-ingress"
      fi
    else
      record_fail "service:$NAMESPACE/$name" "type=$svc_type, endpoints=$has_endpoints" \
        "Verify the service has backing pods with ready endpoints." \
        "$DOCS_BASE/self-host-ingress"
    fi
  done < <(echo "$svc_json" | jq -r '.items[] | [.metadata.name, .spec.type, .spec.clusterIP] | @tsv' 2>/dev/null)
}

check_ingresses() {
  if [[ "$SKIP_INGRESS" == true ]]; then return; fi

  local ing_json
  ing_json=$(kube_get_json get ingresses -n "$NAMESPACE" 2>/dev/null) || true

  if [[ "$ing_json" == "PERMISSION_DENIED" ]]; then
    record_fail "ingresses" "Permission denied listing ingresses" \
      "Verify RBAC permissions." "$DOCS_BASE/self-host-ingress"
    return
  fi
  if [[ -z "$ing_json" || "$ing_json" == ERROR* ]]; then return; fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  local ing_count
  ing_count=$(echo "$ing_json" | jq '.items | length' 2>/dev/null) || ing_count=0
  if [[ "$ing_count" -eq 0 ]]; then return; fi

  # Check each ingress for address and annotations
  while IFS=$'\t' read -r name has_address ingress_class proxy_timeout proxy_body proxy_buffering; do
    [[ -z "$name" ]] && continue
    # Address check
    if [[ "$has_address" == "true" ]]; then
      [[ "$VERBOSE" == true ]] && record_pass "ingress:$NAMESPACE/$name" "address=true"
    else
      record_fail "ingress:$NAMESPACE/$name" "address=false" \
        "Check ingress controller logs and verify the ingress resource configuration." \
        "$DOCS_BASE/self-host-ingress"
    fi

    # Annotation checks (nginx only)
    local cls
    cls=$(echo "$ingress_class" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$cls" && "$cls" != *nginx* ]]; then
      continue  # explicitly non-nginx, skip annotation checks
    fi

    local prefix="ingress_config:$name"
    # Detect nginx: either the class says "nginx", or no class is set but
    # nginx-specific annotations are present (common when relying on the
    # cluster's default IngressClass).
    local is_nginx=false
    if [[ -n "$cls" ]]; then
      is_nginx=true
    elif [[ -n "$proxy_timeout" || -n "$proxy_body" || -n "$proxy_buffering" ]]; then
      is_nginx=true
    fi

    # proxy-read-timeout (need >= 3600)
    if [[ -n "$proxy_timeout" ]]; then
      if [[ "$proxy_timeout" =~ ^[0-9]+$ ]] && [[ "$proxy_timeout" -lt 3600 ]]; then
        record_warn "$prefix:proxy-read-timeout" "Ingress $name proxy-read-timeout is ${proxy_timeout}s (recommend >= 3600)" \
          "Set nginx.ingress.kubernetes.io/proxy-read-timeout to \"3600\" or higher for exports and streaming." \
          "$DOCS_BASE/self-host-ingress"
      fi
    elif [[ "$is_nginx" == true ]]; then
      record_warn "$prefix:proxy-read-timeout" "Ingress $name is missing proxy-read-timeout annotation" \
        "Set nginx.ingress.kubernetes.io/proxy-read-timeout to \"3600\" for long-running operations." \
        "$DOCS_BASE/self-host-ingress"
    fi

    # proxy-body-size (should be "0" for unlimited)
    if [[ -n "$proxy_body" ]]; then
      if [[ "$proxy_body" != "0" ]]; then
        record_warn "$prefix:proxy-body-size" "Ingress $name proxy-body-size is \"$proxy_body\" (recommend \"0\" for unlimited)" \
          "Set nginx.ingress.kubernetes.io/proxy-body-size to \"0\" for trace ingestion." \
          "$DOCS_BASE/self-host-ingress"
      fi
    elif [[ "$is_nginx" == true ]]; then
      record_warn "$prefix:proxy-body-size" "Ingress $name is missing proxy-body-size annotation (nginx default is 1m)" \
        "Set nginx.ingress.kubernetes.io/proxy-body-size to \"0\". Default (1m) is too small for LangSmith." \
        "$DOCS_BASE/self-host-ingress"
    fi

    # proxy-buffering (should be "off")
    if [[ -n "$proxy_buffering" && "$proxy_buffering" != "off" ]]; then
      record_warn "$prefix:proxy-buffering" "Ingress $name proxy-buffering is \"$proxy_buffering\" (recommend \"off\")" \
        "Set nginx.ingress.kubernetes.io/proxy-buffering to \"off\" for SSE/streaming." \
        "$DOCS_BASE/self-host-ingress"
    fi
  done < <(echo "$ing_json" | jq -r '.items[] | [
    .metadata.name,
    (if (.status.loadBalancer.ingress // []) | length > 0 then "true" else "false" end),
    (.spec.ingressClassName // (.metadata.annotations["kubernetes.io/ingress.class"] // "")),
    (.metadata.annotations["nginx.ingress.kubernetes.io/proxy-read-timeout"] // ""),
    (.metadata.annotations["nginx.ingress.kubernetes.io/proxy-body-size"] // ""),
    (.metadata.annotations["nginx.ingress.kubernetes.io/proxy-buffering"] // "")
  ] | @tsv' 2>/dev/null)
}

check_tls_certificates() {
  if [[ "$SKIP_INGRESS" == true ]]; then return; fi
  if [[ "$HAS_OPENSSL" == false ]]; then
    [[ "$VERBOSE" == true ]] && record_warn "tls_certificates" "TLS checks skipped (openssl not available)" ""
    return
  fi
  if [[ -z "$_BASE64_DECODE_CMD" ]]; then
    [[ "$VERBOSE" == true ]] && record_warn "tls_certificates" "TLS checks skipped (no base64 decoder available)" ""
    return
  fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  # Find TLS secrets referenced by ingresses
  local ing_json
  ing_json=$(kube_get_json get ingresses -n "$NAMESPACE" 2>/dev/null) || return

  if [[ -z "$ing_json" || "$ing_json" == ERROR* || "$ing_json" == "PERMISSION_DENIED" ]]; then return; fi

  local tls_secrets
  tls_secrets=$(echo "$ing_json" | jq -r '.items[].spec.tls[]?.secretName // empty' 2>/dev/null | sort -u) || return

  for secret_name in $tls_secrets; do
    [[ -z "$secret_name" ]] && continue

    local cert_data
    cert_data=$(kube get secret "$secret_name" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null) || true

    if [[ -z "$cert_data" ]]; then
      record_warn "tls:$secret_name" "TLS secret $secret_name not found or missing tls.crt" \
        "Verify the TLS secret exists and contains a valid certificate." \
        "$DOCS_BASE/self-host-ingress"
      continue
    fi

    # Decode cert once to a temp file to avoid triple base64 decode
    local cert_pem
    cert_pem=$(mktemp)
    _CLEANUP_FILES+=("$cert_pem")
    if ! echo "$cert_data" | base64_decode > "$cert_pem" 2>/dev/null || [[ ! -s "$cert_pem" ]]; then
      record_warn "tls:$secret_name" "Unable to decode TLS certificate in $secret_name" \
        "Verify the certificate is valid and properly encoded." \
        "$DOCS_BASE/self-host-ingress"
      rm -f "$cert_pem"
      continue
    fi

    local expiry
    expiry=$(openssl x509 -enddate -noout -in "$cert_pem" 2>/dev/null) || true

    if [[ -z "$expiry" ]]; then
      record_warn "tls:$secret_name" "Unable to parse TLS certificate in $secret_name" \
        "Verify the certificate is valid and properly encoded." \
        "$DOCS_BASE/self-host-ingress"
      rm -f "$cert_pem"
      continue
    fi

    # Check if cert expires within 30 days
    local expiry_date="${expiry#notAfter=}"
    if openssl x509 -checkend 2592000 -noout -in "$cert_pem" 2>/dev/null; then
      [[ "$VERBOSE" == true ]] && record_pass "tls:$secret_name" "Certificate valid (expires: $expiry_date)"
    else
      if openssl x509 -checkend 0 -noout -in "$cert_pem" 2>/dev/null; then
        record_warn "tls:$secret_name" "Certificate expires within 30 days ($expiry_date)" \
          "Renew the TLS certificate before it expires." \
          "$DOCS_BASE/self-host-ingress"
      else
        record_fail "tls:$secret_name" "Certificate has EXPIRED ($expiry_date)" \
          "Replace the expired TLS certificate immediately." \
          "$DOCS_BASE/self-host-ingress"
      fi
    fi
    rm -f "$cert_pem"
  done
}

check_beacon() {
  if [[ "$HAS_CURL" == false ]]; then
    record_warn "beacon_reachability" "Beacon check skipped (curl not available)" ""
    return
  fi

  local beacon_url="https://beacon.langchain.com"
  if curl -sf --max-time 10 "$beacon_url" >/dev/null 2>&1; then
    record_pass "beacon_reachability" "Beacon API reachable from this machine ($beacon_url)"
    record_detail "Note: this tests connectivity from your workstation, not from inside the cluster."
    record_detail "Cluster pods may still be unable to reach the beacon if egress is restricted."
  else
    record_fail "beacon_reachability" "Beacon API unreachable from this machine" \
      "Ensure egress to $beacon_url is allowed for billing." \
      "$DOCS_BASE/self-host-egress"
    record_detail "Note: this tests connectivity from your workstation, not from inside the cluster."
  fi
}

run_networking_checks() {
  section "Networking"
  check_services
  check_ingresses
  check_tls_certificates
  check_beacon
}

# ── Infrastructure Checks ───────────────────────────────────────────────────

check_node_conditions() {
  if [[ "$SKIP_CLOUD" == true ]]; then return; fi

  local nodes_json
  nodes_json=$(kube_get_json get nodes 2>/dev/null) || true

  if [[ "$nodes_json" == "PERMISSION_DENIED" ]]; then
    record_warn "node_conditions" "Node condition checks skipped: permission denied" \
      "Apply deploy/rbac-full.yaml to grant cluster-scoped RBAC for node access." \
      "$DOCS_BASE/kubernetes"
    return
  fi
  if [[ -z "$nodes_json" || "$nodes_json" == ERROR* ]]; then return; fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  local unhealthy=0
  local total_nodes
  total_nodes=$(echo "$nodes_json" | jq '.items | length' 2>/dev/null) || total_nodes=0

  # Check for unhealthy conditions
  local bad_conditions
  bad_conditions=$(echo "$nodes_json" | jq -r '
    .items[] |
    .metadata.name as $node |
    .status.conditions[] |
    select(
      (.type == "Ready" and .status != "True") or
      (.type != "Ready" and .status == "True" and
       (.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure" or .type == "NetworkUnavailable"))
    ) |
    [$node, .type, .status, (.message // "")] | @tsv
  ' 2>/dev/null) || bad_conditions=""

  if [[ -n "$bad_conditions" ]]; then
    while IFS=$'\t' read -r node cond_type cond_status message; do
      [[ -z "$node" ]] && continue
      ((unhealthy++)) || true
      record_fail "node:$node:$cond_type" "Node $node has $cond_type=$cond_status" \
        "Investigate the unhealthy node: kubectl describe node $node" \
        "$DOCS_BASE/kubernetes"
    done <<< "$bad_conditions"
  fi

  if [[ "$unhealthy" -eq 0 && "$total_nodes" -gt 0 ]]; then
    record_pass "node_conditions" "All $total_nodes nodes are healthy"
  fi
}

check_resource_quotas() {
  local quota_json
  quota_json=$(kube_get_json get resourcequotas -n "$NAMESPACE" 2>/dev/null) || true

  if [[ -z "$quota_json" || "$quota_json" == ERROR* || "$quota_json" == "PERMISSION_DENIED" ]]; then return; fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  local quota_count
  quota_count=$(echo "$quota_json" | jq '.items | length' 2>/dev/null) || quota_count=0
  if [[ "$quota_count" -eq 0 ]]; then return; fi

  record_pass "resource_quotas:$NAMESPACE" "$quota_count ResourceQuota(s) present"
}

run_infra_checks() {
  section "Infrastructure"
  check_node_conditions
  check_resource_quotas
}

# ── DNS Checks ───────────────────────────────────────────────────────────────

check_coredns() {
  local dns_pods
  dns_pods=$(kube get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null) || true

  if [[ -z "$dns_pods" ]]; then
    # Try alternate label
    dns_pods=$(kube get pods -n kube-system -l app=coredns --no-headers 2>/dev/null) || true
  fi

  if [[ -z "$dns_pods" ]]; then
    record_warn "dns:coredns" "Could not find CoreDNS pods in kube-system" \
      "Verify CoreDNS is running. It may use different labels in your cluster." \
      "$DOCS_BASE/diagnostics-self-hosted"
    return
  fi

  local total running
  total=$(echo "$dns_pods" | wc -l | tr -d ' ')
  running=$(echo "$dns_pods" | grep -c "Running" || true)

  if [[ "$running" -ge "$total" && "$total" -gt 0 ]]; then
    record_pass "dns:coredns" "CoreDNS healthy ($running/$total pods Running)"
  else
    record_fail "dns:coredns" "CoreDNS unhealthy ($running/$total pods Running)" \
      "Check CoreDNS pods in kube-system: kubectl get pods -n kube-system -l k8s-app=kube-dns" \
      "$DOCS_BASE/diagnostics-self-hosted"
  fi
}

run_dns_checks() {
  section "DNS"
  check_coredns
}

# ── Database Checks ─────────────────────────────────────────────────────────

find_pod_by_selector() {
  local selector="$1"
  selector=$(resolve_selector "$selector")
  kube get pods -n "$NAMESPACE" -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

check_clickhouse_disk() {
  local ch_selector="app.kubernetes.io/component=langsmith-clickhouse"
  local ch_pod
  ch_pod=$(find_pod_by_selector "$ch_selector")

  if [[ -z "$ch_pod" ]]; then
    record_warn "clickhouse_disk_usage" "No running ClickHouse pod found" \
      "Verify ClickHouse is running." "$DOCS_BASE/self-host-external-clickhouse"
    return
  fi

  local disk_info
  disk_info=$(kube exec "$ch_pod" -n "$NAMESPACE" -- clickhouse-client --query "SELECT name, path, formatReadableSize(free_space) as free, formatReadableSize(total_space) as total, round(100 - (free_space / total_space * 100), 1) as pct_used FROM system.disks FORMAT TabSeparated" 2>/dev/null) || true

  if [[ -z "$disk_info" ]]; then
    record_warn "clickhouse_disk_usage" "Unable to query ClickHouse disk info (exec may require elevated RBAC)" \
      "Apply deploy/rbac-full.yaml for pod exec permissions." \
      "$DOCS_BASE/self-host-external-clickhouse"
    return
  fi

  while IFS=$'\t' read -r disk_name _disk_path free total pct_used; do
    [[ -z "$disk_name" ]] && continue
    # Remove decimal for comparison
    local pct_int="${pct_used%.*}"
    if ! [[ "$pct_int" =~ ^[0-9]+$ ]]; then
      record_warn "clickhouse_disk:$disk_name" "Unable to parse disk usage for $disk_name (got: $pct_used)"
      continue
    fi
    if [[ "$pct_int" -ge 90 ]]; then
      record_fail "clickhouse_disk:$disk_name" "Disk $disk_name is ${pct_used}% full ($free free of $total)" \
        "ClickHouse disk is critically full. Expand storage or reduce retention." \
        "$DOCS_BASE/self-host-external-clickhouse"
    elif [[ "$pct_int" -ge 80 ]]; then
      record_warn "clickhouse_disk:$disk_name" "Disk $disk_name is ${pct_used}% full ($free free of $total)" \
        "ClickHouse disk usage is high. Consider expanding storage or adjusting TTLs." \
        "$DOCS_BASE/self-host-external-clickhouse"
    else
      record_pass "clickhouse_disk:$disk_name" "Disk $disk_name is ${pct_used}% full ($free free of $total)"
    fi
  done <<< "$disk_info"
}

check_clickhouse_version() {
  local ch_selector="app.kubernetes.io/component=langsmith-clickhouse"
  local ch_pod
  ch_pod=$(find_pod_by_selector "$ch_selector")

  if [[ -z "$ch_pod" ]]; then return; fi

  local version
  version=$(kube exec "$ch_pod" -n "$NAMESPACE" -- clickhouse-client --query "SELECT version()" 2>/dev/null) || true

  if [[ -n "$version" ]]; then
    record_pass "clickhouse_version" "ClickHouse version: $version"
  fi
}

check_pg_connections() {
  local pg_selector="app.kubernetes.io/component=langsmith-postgres"
  local pg_pod
  pg_pod=$(find_pod_by_selector "$pg_selector")

  if [[ -z "$pg_pod" ]]; then
    record_warn "postgres_connections" "No running Postgres pod found" \
      "Verify Postgres is running." "$DOCS_BASE/kubernetes"
    return
  fi

  # Detect PG user from configmap connection string, fall back to "postgres"
  local pg_user="postgres"
  if [[ "$HAS_JQ" == true ]]; then
    local pg_conn
    pg_conn=$(kube get configmap "${RELEASE_NAME}-config" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.data.PG_RR_CONNECTION_STRING // .data.PG_CONNECTION_STRING // ""' 2>/dev/null) || true
    if [[ "$pg_conn" =~ ://([^:@]+)(:|@) ]]; then
      pg_user="${BASH_REMATCH[1]}"
    fi
  fi

  local max_conn
  max_conn=$(kube exec "$pg_pod" -n "$NAMESPACE" -- psql -U "$pg_user" -tAc "SHOW max_connections" 2>/dev/null) || true
  local active_conn
  active_conn=$(kube exec "$pg_pod" -n "$NAMESPACE" -- psql -U "$pg_user" -tAc "SELECT count(*) FROM pg_stat_activity" 2>/dev/null) || true

  if [[ -z "$max_conn" || -z "$active_conn" ]]; then
    record_warn "postgres_connections" "Unable to query Postgres connections (exec may require elevated RBAC)" \
      "Apply deploy/rbac-full.yaml for pod exec permissions." \
      "$DOCS_BASE/kubernetes"
    return
  fi

  max_conn=$(echo "$max_conn" | tr -d '[:space:]')
  active_conn=$(echo "$active_conn" | tr -d '[:space:]')

  # Validate numeric before arithmetic
  if ! [[ "$max_conn" =~ ^[0-9]+$ && "$active_conn" =~ ^[0-9]+$ ]]; then
    record_warn "postgres_connections" "Unable to parse Postgres connection stats (max=$max_conn, active=$active_conn)" \
      "Verify Postgres is accessible and the user has sufficient privileges." \
      "$DOCS_BASE/kubernetes"
    return
  fi

  if [[ "$max_conn" -gt 0 ]]; then
    local pct=$((active_conn * 100 / max_conn))
    if [[ "$pct" -ge 90 ]]; then
      record_fail "postgres_connections" "Connection utilization at ${pct}% ($active_conn/$max_conn)" \
        "Postgres is near connection limit. Increase max_connections or investigate connection leaks." \
        "$DOCS_BASE/kubernetes"
    elif [[ "$pct" -ge 80 ]]; then
      record_warn "postgres_connections" "Connection utilization at ${pct}% ($active_conn/$max_conn)" \
        "Postgres connection usage is high. Consider increasing max_connections." \
        "$DOCS_BASE/kubernetes"
    else
      record_pass "postgres_connections" "Connection utilization at ${pct}% ($active_conn/$max_conn)"
    fi
  fi

  # Idle in transaction
  local idle_count
  idle_count=$(kube exec "$pg_pod" -n "$NAMESPACE" -- psql -U "$pg_user" -tAc "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction'" 2>/dev/null) || true
  idle_count=$(echo "$idle_count" | tr -d '[:space:]')

  if [[ -n "$idle_count" && "$idle_count" =~ ^[0-9]+$ && "$idle_count" -ge 5 ]]; then
    record_warn "postgres_idle_in_transaction" "$idle_count connections idle in transaction" \
      "Investigate long-running transactions. These hold locks and consume connection slots."
  fi
}

run_database_checks() {
  section "Databases"
  check_clickhouse_disk
  check_clickhouse_version
  check_pg_connections
}

# ── Cloud Checks ─────────────────────────────────────────────────────────────

check_cloud_provider() {
  if [[ "$SKIP_CLOUD" == true ]]; then return; fi

  local nodes_json
  nodes_json=$(kube_get_json get nodes 2>/dev/null) || true

  if [[ "$nodes_json" == "PERMISSION_DENIED" ]]; then
    record_warn "cloud" "Cloud checks skipped: permission denied" \
      "Apply deploy/rbac-full.yaml for node access, or use --skip cloud." ""
    return
  fi
  if [[ -z "$nodes_json" || "$nodes_json" == ERROR* ]]; then return; fi
  if [[ "$HAS_JQ" == false ]]; then return; fi

  local provider_id
  provider_id=$(echo "$nodes_json" | jq -r '.items[0].spec.providerID // ""' 2>/dev/null) || provider_id=""

  if [[ "$provider_id" == aws* ]]; then
    record_pass "cloud:provider" "Detected cloud provider: AWS"
  elif [[ "$provider_id" == gce* ]]; then
    record_pass "cloud:provider" "Detected cloud provider: GCP"
  elif [[ "$provider_id" == azure* ]]; then
    record_pass "cloud:provider" "Detected cloud provider: Azure"
  elif echo "$nodes_json" | jq -e '.items[0].metadata.labels["node.openshift.io/os_id"]' >/dev/null 2>&1; then
    record_pass "cloud:provider" "Detected platform: OpenShift"
  else
    record_warn "cloud:provider" "Cloud provider not detected (bare metal, k3s, or non-standard cluster)" \
      "Ensure your storage provisioner and ingress controller are configured for your environment." ""
  fi
}

run_cloud_checks() {
  section "Cloud"
  check_cloud_provider
}

# ── App Diagnostics ──────────────────────────────────────────────────────────

run_app_diagnostics() {
  section "Application Diagnostics"

  # ClickHouse queries
  local ch_selector="app.kubernetes.io/component=langsmith-clickhouse"
  local ch_pod
  ch_pod=$(find_pod_by_selector "$ch_selector")

  if [[ -n "$ch_pod" ]]; then
    info "ClickHouse diagnostics (pod: $ch_pod)"
    echo

    # Disk status
    printf "${BOLD}  Disk Status:${RESET}\n"
    kube exec "$ch_pod" -n "$NAMESPACE" -- clickhouse-client --query \
      "SELECT name, path, formatReadableSize(free_space) as free, formatReadableSize(total_space) as total, round(100 - (free_space / total_space * 100), 1) as pct_used FROM system.disks FORMAT PrettyCompact" 2>/dev/null || echo "    (query failed)"
    echo

    # Version
    printf "${BOLD}  Version:${RESET}\n"
    printf "    %s\n" "$(kube exec "$ch_pod" -n "$NAMESPACE" -- clickhouse-client --query "SELECT version()" 2>/dev/null || echo "(query failed)")"
    echo

    # System metrics
    printf "${BOLD}  System Metrics:${RESET}\n"
    kube exec "$ch_pod" -n "$NAMESPACE" -- clickhouse-client --query \
      "SELECT metric, value FROM system.metrics WHERE metric IN ('Query', 'Merge', 'PartMutation', 'ReplicatedFetch', 'ReplicatedSend', 'GlobalThread', 'LocalThread', 'TCPConnection', 'HTTPConnection') ORDER BY metric FORMAT PrettyCompact" 2>/dev/null || echo "    (query failed)"
    echo

    # Query exceptions (last 7 days)
    printf "${BOLD}  Query Exceptions (7d):${RESET}\n"
    kube exec "$ch_pod" -n "$NAMESPACE" -- clickhouse-client --query \
      "SELECT type, count() as cnt, any(last_error_message) as example FROM system.query_log WHERE event_date >= today() - 7 AND exception != '' GROUP BY type ORDER BY cnt DESC LIMIT 10 FORMAT PrettyCompact" 2>/dev/null || echo "    (query failed or no exceptions)"
    echo
  else
    record_warn "clickhouse_diagnostics" "No running ClickHouse pod found" \
      "Verify ClickHouse is running." "$DOCS_BASE/self-host-external-clickhouse"
  fi

  # Postgres queries
  local pg_selector="app.kubernetes.io/component=langsmith-postgres"
  local pg_pod
  pg_pod=$(find_pod_by_selector "$pg_selector")

  # Detect PG user from configmap connection string, fall back to "postgres"
  local pg_user="postgres"
  if [[ "$HAS_JQ" == true ]]; then
    local pg_conn
    pg_conn=$(kube get configmap "${RELEASE_NAME}-config" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.data.PG_RR_CONNECTION_STRING // .data.PG_CONNECTION_STRING // ""' 2>/dev/null) || true
    if [[ "$pg_conn" =~ ://([^:@]+)(:|@) ]]; then
      pg_user="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -n "$pg_pod" ]]; then
    info "Postgres diagnostics (pod: $pg_pod)"
    echo

    # Connection stats
    printf "${BOLD}  Connection Stats:${RESET}\n"
    kube exec "$pg_pod" -n "$NAMESPACE" -- psql -U "$pg_user" -c \
      "SELECT state, count(*) FROM pg_stat_activity GROUP BY state ORDER BY count DESC" 2>/dev/null || echo "    (query failed)"
    echo

    # Database sizes
    printf "${BOLD}  Database Sizes:${RESET}\n"
    kube exec "$pg_pod" -n "$NAMESPACE" -- psql -U "$pg_user" -c \
      "SELECT datname, pg_size_pretty(pg_database_size(datname)) as size FROM pg_database WHERE datname NOT IN ('template0','template1') ORDER BY pg_database_size(datname) DESC" 2>/dev/null || echo "    (query failed)"
    echo
  else
    record_warn "postgres_diagnostics" "No running Postgres pod found" \
      "Verify Postgres is running." "$DOCS_BASE/kubernetes"
  fi
}

# ── Support Bundle ───────────────────────────────────────────────────────────

redact_logs() {
  if [[ "$NO_REDACT" == true ]]; then
    cat
  else
    sed -E \
      -e 's/sk-[a-zA-Z0-9]{20,}/[REDACTED]/g' \
      -e 's/ls-[a-zA-Z0-9]{20,}/[REDACTED]/g' \
      -e 's/ghp_[a-zA-Z0-9]{20,}/[REDACTED]/g' \
      -e 's/gho_[a-zA-Z0-9]{20,}/[REDACTED]/g' \
      -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
      -e 's/([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[a-zA-Z0-9_.~+/=-]+/\1[REDACTED]/g' \
      -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Kk][Ee][Yy]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]?)([[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/g' \
      -e 's#([Pp][Oo][Ss][Tt][Gg][Rr][Ee][Ss]|[Mm][Yy][Ss][Qq][Ll]|[Rr][Ee][Dd][Ii][Ss]|[Mm][Oo][Nn][Gg][Oo][Dd][Bb]|[Cc][Ll][Ii][Cc][Kk][Hh][Oo][Uu][Ss][Ee]|[Cc][Hh]|[Aa][Mm][Qq][Pp][Ss]?|[Rr][Aa][Bb][Bb][Ii][Tt][Mm][Qq])://[^:]+:[^@]+@#\1://[REDACTED]:[REDACTED]@#g' \
      -e 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[REDACTED]/g'
  fi
}

collect_bundle() {
  local bundle_dir
  bundle_dir=$(mktemp -d "${TMPDIR:-/tmp}/langsmith-doctor-XXXXXXXXXX")
  _CLEANUP_DIRS+=("$bundle_dir")
  mkdir -p "$bundle_dir/logs"

  section "Support Bundle Collection"
  info "Collecting to $bundle_dir"

  # Resource YAML dumps (redact sensitive values from configmaps)
  for resource in pods deployments statefulsets daemonsets services jobs; do
    info "Collecting ${resource}..."
    kube get "$resource" -n "$NAMESPACE" -o yaml 2>/dev/null | redact_logs > "$bundle_dir/${resource}.yaml" || true
  done
  info "Collecting configmaps..."
  kube get configmaps -n "$NAMESPACE" -o yaml 2>/dev/null | redact_logs > "$bundle_dir/configmaps.yaml" || true

  # PVCs
  kube get pvc -n "$NAMESPACE" -o yaml 2>/dev/null | redact_logs > "$bundle_dir/pvcs.yaml" || rm -f "$bundle_dir/pvcs.yaml"

  # StorageClasses (cluster-scoped)
  kube get storageclasses -o yaml 2>/dev/null | redact_logs > "$bundle_dir/storageclasses.yaml" || rm -f "$bundle_dir/storageclasses.yaml"

  # Events (human-readable)
  info "Collecting events..."
  kube get events -n "$NAMESPACE" --sort-by='.metadata.creationTimestamp' 2>/dev/null | redact_logs > "$bundle_dir/events.txt" || true
  kube get events -n "$NAMESPACE" -o yaml 2>/dev/null | redact_logs > "$bundle_dir/events.yaml" || true

  # Nodes (cluster-scoped, may fail)
  info "Collecting nodes..."
  if ! kube get nodes -o yaml > "$bundle_dir/nodes.yaml" 2>/dev/null; then
    rm -f "$bundle_dir/nodes.yaml"
    warn "Skipping nodes (permission denied or unavailable)"
  fi

  # Helm release metadata (strip .data.release to avoid leaking rendered values/secrets)
  if [[ "$SKIP_HELM" == false ]]; then
    info "Collecting Helm info..."
    if [[ "$HAS_JQ" == true ]]; then
      kube get secrets -n "$NAMESPACE" -l "owner=helm,name=${RELEASE_NAME}" -o json 2>/dev/null | \
        jq 'if .items then .items |= map(.data.release = "[REDACTED]") else .data.release = "[REDACTED]" end' | \
        redact_logs > "$bundle_dir/helm-release.json" || true
    else
      # Without jq, collect only metadata (no -o yaml which would include secret data)
      kube get secrets -n "$NAMESPACE" -l "owner=helm,name=${RELEASE_NAME}" -o custom-columns=NAME:.metadata.name,STATUS:.metadata.labels.status,VERSION:.metadata.labels.version > "$bundle_dir/helm-release.txt" 2>/dev/null || true
    fi
  fi

  # Pod logs
  if [[ "$INCLUDE_LOGS" == true ]]; then
    info "Collecting pod logs..."
    if [[ "$HAS_JQ" == true ]]; then
      local pods_json
      pods_json=$(kube_get_json get pods -n "$NAMESPACE" 2>/dev/null) || pods_json=""

      if [[ -n "$pods_json" && "$pods_json" != ERROR* && "$pods_json" != "PERMISSION_DENIED" ]]; then
        while IFS=$'\t' read -r pod container; do
          [[ -z "$pod" ]] && continue
          kube logs "$pod" -c "$container" -n "$NAMESPACE" --tail="$TAIL_LINES" 2>/dev/null | \
            redact_logs > "$bundle_dir/logs/${pod}_${container}_current.log" || true
          kube logs "$pod" -c "$container" -n "$NAMESPACE" --previous --tail="$TAIL_LINES" 2>/dev/null | \
            redact_logs > "$bundle_dir/logs/${pod}_${container}_previous.log" 2>/dev/null || true
          # Remove empty previous logs
          [[ ! -s "$bundle_dir/logs/${pod}_${container}_previous.log" ]] && rm -f "$bundle_dir/logs/${pod}_${container}_previous.log"
        done < <(echo "$pods_json" | jq -r '.items[] | .metadata.name as $pod | ((.spec.containers[].name), (.spec.initContainers[]?.name)) | . as $c | [$pod, $c] | @tsv' 2>/dev/null)
      fi
    else
      # Without jq, just get logs for all pods
      kube get pods -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | \
      while read -r pod; do
        [[ -z "$pod" ]] && continue
        kube logs "$pod" -n "$NAMESPACE" --all-containers --tail="$TAIL_LINES" 2>/dev/null | \
          redact_logs > "$bundle_dir/logs/${pod}_all.log" || true
      done
    fi
  fi

  # Create archive
  local bundle_basename
  bundle_basename=$(basename "$bundle_dir")
  local bundle_parent
  bundle_parent=$(dirname "$bundle_dir")
  local archive="${bundle_dir}.tar.gz"
  if tar czf "$archive" -C "$bundle_parent" "$bundle_basename" 2>/dev/null; then
    # Archive succeeded — remove bundle_dir from cleanup (keep the .tar.gz)
    local new_cleanup=()
    for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
      [[ "$d" == "$bundle_dir" ]] && continue
      new_cleanup+=("$d")
    done
    _CLEANUP_DIRS=("${new_cleanup[@]+"${new_cleanup[@]}"}")
    rm -rf "$bundle_dir"

    echo
    info "Bundle saved to: $archive"
    local size
    size=$(du -h "$archive" 2>/dev/null | cut -f1)
    info "Size: $size"
  else
    echo
    error "Failed to create archive at $archive"
    info "Uncompressed bundle directory preserved at: $bundle_dir"
    # Remove from cleanup so the directory actually survives for the user
    local new_cleanup=()
    for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
      [[ "$d" == "$bundle_dir" ]] && continue
      new_cleanup+=("$d")
    done
    _CLEANUP_DIRS=("${new_cleanup[@]+"${new_cleanup[@]}"}")
  fi
}

# ── Arg Parsing ──────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [COMMAND]

Shell-based diagnostic tool for LangSmith self-hosted deployments.

Commands:
  diagnose          Infrastructure health checks (default)
  diagnose app      Application-level checks (ClickHouse, Postgres)
  bundle            Collect support bundle (tar.gz)
  help              Show this help message

Options:
  --namespace <ns>       Target namespace (default: langsmith)
  --release-name <name>  Helm release name (default: langsmith)
  --kubeconfig <path>    Path to kubeconfig
  --context <name>       Kubernetes context
  --skip <categories>    Comma-separated skip list: helm,jobs,services,ingress,cloud
  --verbose              Show passing checks too
  --no-redact            Disable log redaction in bundle
  --no-color             Disable color output
  --tail-lines <n>       Max log lines per container in bundle (default: 1000)
  --help                 Show this help message
  --version              Show version

Examples:
  $(basename "$0")                                    # quick health check
  $(basename "$0") bundle                             # full diagnostic bundle
  $(basename "$0") --namespace myapp diagnose          # custom namespace
  $(basename "$0") --skip helm,cloud diagnose          # skip certain checks
EOF
  exit 0
}

require_arg() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    error "$1 requires a value"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)     require_arg "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
      --release-name)  require_arg "$1" "${2:-}"; RELEASE_NAME="$2"; shift 2 ;;
      --kubeconfig)    require_arg "$1" "${2:-}"; KUBECONFIG_FLAG="$2"; shift 2 ;;
      --context)       require_arg "$1" "${2:-}"; CONTEXT_FLAG="$2"; shift 2 ;;
      --skip)
        require_arg "$1" "${2:-}"
        IFS=',' read -ra SKIP_LIST <<< "$2"
        for skip in "${SKIP_LIST[@]}"; do
          case "$skip" in
            helm)     SKIP_HELM=true ;;
            jobs)     SKIP_JOBS=true ;;
            services) SKIP_SERVICES=true ;;
            ingress)  SKIP_INGRESS=true ;;
            cloud)    SKIP_CLOUD=true ;;
            *) warn "Unknown skip category: $skip" ;;
          esac
        done
        shift 2 ;;
      --verbose|-v)    VERBOSE=true; shift ;;
      --no-redact)     NO_REDACT=true; shift ;;
      --no-color)      NO_COLOR=true; shift ;;
      --tail-lines)
        require_arg "$1" "${2:-}"
        if ! [[ "$2" =~ ^[0-9]+$ ]]; then
          error "--tail-lines requires a numeric value, got: $2"
          exit 1
        fi
        TAIL_LINES="$2"; shift 2 ;;
      --help|-h)       usage ;;
      --version)       echo "langsmith-doctor $VERSION"; exit 0 ;;
      diagnose)        COMMAND="diagnose"; shift ;;
      app)
        if [[ -n "$COMMAND" && "$COMMAND" != "diagnose" ]]; then
          warn "'app' subcommand is only valid with 'diagnose' — ignoring"
        else
          COMMAND="diagnose"
          SUBCOMMAND="app"
        fi
        shift ;;
      bundle)          COMMAND="bundle"; shift ;;
      help)            usage ;;
      *)               warn "Unknown argument: $1"; shift ;;
    esac
  done

  # Default command
  if [[ -z "$COMMAND" ]]; then
    COMMAND="diagnose"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

print_banner() {
  printf "${BOLD}langsmith-doctor${RESET} %s (shell)\n" "$VERSION"
  printf "${DIM}Namespace: %s | Release: %s${RESET}\n" "$NAMESPACE" "$RELEASE_NAME"
  if [[ "$HAS_JQ" == false ]]; then
    printf "${YELLOW}(degraded mode — install jq for full diagnostics)${RESET}\n"
  fi
}

CLUSTER_ONLINE=false

run_diagnose() {
  section "Validation"

  # Gate: cluster connectivity (skip if run_status already verified)
  if [[ "$CLUSTER_ONLINE" != true ]]; then
    if ! check_cluster_connectivity; then
      return 0
    fi
    CLUSTER_ONLINE=true
  else
    record_pass "cluster_connectivity" "Cluster API reachable"
  fi
  check_cluster_version

  # Gate: namespace must exist to proceed with meaningful checks
  if ! check_namespace; then
    return 0
  fi

  # Check groups (sequential in v1)
  run_workload_checks
  run_helm_config_checks
  run_networking_checks
  run_infra_checks
  run_dns_checks
  run_database_checks
  run_cloud_checks
}

main() {
  parse_args "$@"
  setup_colors
  build_kubectl_args
  detect_dependencies
  print_banner

  local start_time
  start_time=$(date +%s)

  case "$COMMAND" in
    diagnose)
      run_status
      if [[ "$CLUSTER_ONLINE" == true ]]; then
        if [[ "$SUBCOMMAND" == "app" ]]; then
          # App diagnostics still need a valid namespace to exec into pods
          section "Validation"
          if check_namespace; then
            run_app_diagnostics
          fi
        else
          run_diagnose
        fi
      fi
      local end_time elapsed
      end_time=$(date +%s)
      elapsed="$((end_time - start_time))s"
      print_summary "$elapsed"
      ;;
    bundle)
      run_status
      if [[ "$CLUSTER_ONLINE" == true ]]; then
        run_diagnose
        collect_bundle
      fi
      local end_time elapsed
      end_time=$(date +%s)
      elapsed="$((end_time - start_time))s"
      print_summary "$elapsed"
      ;;
    *)
      usage
      ;;
  esac

  # Exit non-zero if any checks failed
  [[ $FAIL_COUNT -eq 0 ]] || exit 1
}

main "$@"
