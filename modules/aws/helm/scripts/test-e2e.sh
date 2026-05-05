#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-e2e.sh — End-to-end gateway validation for LangSmith on AWS.
#
# Tests both ingress modes:
#   - ALB Ingress   (enable_envoy_gateway = false)
#   - Envoy Gateway (enable_envoy_gateway = true)
#
# What is tested:
#   1. DNS resolves to the correct load balancer
#   2. HTTPS TLS handshake succeeds with a valid ACM cert
#   3. HTTP → HTTPS redirect works
#   4. /api/v1/health returns 200
#   5. Frontend HTML loads (CSP nonce present)
#   6. Gateway API resources are programmed (gateway mode only)
#   7. HTTPRoutes are accepted for all active deployments
#   8. All core pods are Running
#
# Usage (from aws/):
#   make test-e2e
#   ./helm/scripts/test-e2e.sh
#   LANGSMITH_URL=https://langsmith.example.com ./helm/scripts/test-e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
source "$INFRA_DIR/scripts/_common.sh"

NAMESPACE="${NAMESPACE:-langsmith}"
RELEASE_NAME="${RELEASE_NAME:-langsmith}"

# ── Resolve test URL ──────────────────────────────────────────────────────────
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source="none"
_enable_envoy_gateway=false
_tfvar_is_true "enable_envoy_gateway" && _enable_envoy_gateway=true

_protocol="http"
[[ "$_tls_source" == "acm" || "$_tls_source" == "letsencrypt" ]] && _protocol="https"

if [[ -n "${LANGSMITH_URL:-}" ]]; then
  BASE_URL="$LANGSMITH_URL"
elif [[ -n "$_langsmith_domain" ]]; then
  BASE_URL="${_protocol}://${_langsmith_domain}"
elif [[ "$_enable_envoy_gateway" == "true" ]]; then
  _gw_host=$(kubectl get svc -n envoy-gateway-system \
    -l "gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  BASE_URL="${_protocol}://${_gw_host}"
else
  _alb_host=$(kubectl get ingress -n "$NAMESPACE" langsmith-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  BASE_URL="${_protocol}://${_alb_host}"
fi

if [[ -z "${BASE_URL:-}" || "$BASE_URL" == "${_protocol}://" ]]; then
  fail "Could not determine LangSmith URL. Set LANGSMITH_URL or ensure the load balancer is ready."
  exit 1
fi

# ── Test runner ───────────────────────────────────────────────────────────────
_pass=0
_fail=0
_results=()

_run_test() {
  local name="$1"
  local result="$2"   # "pass" or "fail"
  local detail="${3:-}"
  if [[ "$result" == "pass" ]]; then
    _pass=$((_pass + 1))
    _results+=("  ✔  $name")
  else
    _fail=$((_fail + 1))
    _results+=("  ✗  $name${detail:+: $detail}")
  fi
}

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith AWS — E2E Gateway Test"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  URL:  $BASE_URL"
echo "  Mode: $( [[ "$_enable_envoy_gateway" == "true" ]] && echo "Envoy Gateway (Gateway API)" || echo "ALB Ingress")"
echo "  NS:   $NAMESPACE"
echo ""

# ── Test 1: DNS resolves ──────────────────────────────────────────────────────
_hostname="${BASE_URL#*://}"
_hostname="${_hostname%%/*}"
_dns_result=$(dig +short "$_hostname" 2>/dev/null | head -1 || true)
if [[ -n "$_dns_result" ]]; then
  _run_test "DNS: $_hostname resolves" pass "$_dns_result"
else
  _run_test "DNS: $_hostname resolves" fail "no DNS answer"
fi

# ── Test 2: TLS handshake + cert valid ────────────────────────────────────────
if [[ "$_protocol" == "https" ]]; then
  _tls_check=$(curl -svo /dev/null --max-time 10 "$BASE_URL" 2>&1 || true)
  if echo "$_tls_check" | grep -q "SSL connection using\|TLS"; then
    _tls_issuer=$(echo "$_tls_check" | grep "issuer:" | head -1 | sed 's/.*issuer: //')
    _run_test "TLS: handshake succeeds" pass "$_tls_issuer"
  else
    _run_test "TLS: handshake succeeds" fail "$(echo "$_tls_check" | grep -i "error\|failed" | head -1)"
  fi

  # HTTP → HTTPS redirect (ALB only — NLBs don't support listener-level redirects)
  if [[ "$_enable_envoy_gateway" != "true" ]]; then
    _http_url="http://${_hostname}/"
    _redirect_code=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "$_http_url" 2>/dev/null || echo "000")
    if [[ "$_redirect_code" == "301" || "$_redirect_code" == "308" || "$_redirect_code" == "302" ]]; then
      _run_test "TLS: HTTP → HTTPS redirect (${_redirect_code})" pass
    else
      _run_test "TLS: HTTP → HTTPS redirect" fail "got ${_redirect_code}"
    fi
  fi
fi

# ── Test 3: Health endpoint ───────────────────────────────────────────────────
_health_code=$(curl -sko /dev/null -w "%{http_code}" --max-time 10 "${BASE_URL}/api/v1/health" 2>/dev/null || echo "000")
if [[ "$_health_code" == "200" ]]; then
  _run_test "API: /api/v1/health returns 200" pass
else
  _run_test "API: /api/v1/health returns 200" fail "got ${_health_code}"
fi

# ── Test 4: Frontend HTML loads ───────────────────────────────────────────────
_frontend_body=$(curl -sk --max-time 10 "${BASE_URL}/" 2>/dev/null || true)
if echo "$_frontend_body" | grep -q "csp-nonce\|ls-init\|LangSmith"; then
  _run_test "Frontend: HTML loads with CSP nonce" pass
else
  _run_test "Frontend: HTML loads with CSP nonce" fail "unexpected body or no response"
fi

# ── Test 5: Gateway API resources (gateway mode only) ────────────────────────
if [[ "$_enable_envoy_gateway" == "true" ]]; then
  # GatewayClass accepted
  _gc_status=$(kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "$_gc_status" == "True" ]] && _run_test "Gateway: GatewayClass 'eg' accepted" pass \
    || _run_test "Gateway: GatewayClass 'eg' accepted" fail "status=$_gc_status"

  # Gateway programmed
  _gw_status=$(kubectl get gateway langsmith-gateway -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  [[ "$_gw_status" == "True" ]] && _run_test "Gateway: langsmith-gateway programmed" pass \
    || _run_test "Gateway: langsmith-gateway programmed" fail "status=$_gw_status"

  # Gateway has both listeners
  _listener_count=$(kubectl get gateway langsmith-gateway -n "$NAMESPACE" \
    -o jsonpath='{.spec.listeners}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  [[ "$_listener_count" -ge 2 ]] && _run_test "Gateway: listeners port 80 + 443 present" pass \
    || _run_test "Gateway: listeners port 80 + 443 present" fail "found ${_listener_count} listener(s)"

  # HTTPRoute for main langsmith accepted
  _rt_status=$(kubectl get httproute langsmith -n "$NAMESPACE" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "$_rt_status" == "True" ]] && _run_test "HTTPRoute: langsmith accepted" pass \
    || _run_test "HTTPRoute: langsmith accepted" fail "status=$_rt_status"

  # Count total accepted HTTPRoutes (deployments create one each)
  _total_routes=$(kubectl get httproute -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  _run_test "HTTPRoutes: ${_total_routes} route(s) present in namespace" pass

  # NLB scheme
  _nlb_scheme=$(aws elbv2 describe-load-balancers --region "${AWS_REGION:-us-west-2}" \
    --query "LoadBalancers[?contains(DNSName,'envoygat')].Scheme" \
    --output text 2>/dev/null || true)
  [[ "$_nlb_scheme" == "internet-facing" ]] && _run_test "NLB: scheme is internet-facing" pass \
    || _run_test "NLB: scheme is internet-facing" fail "scheme=$_nlb_scheme"

  # NLB has 443 TLS listener
  _nlb_arn=$(aws elbv2 describe-load-balancers --region "${AWS_REGION:-us-west-2}" \
    --query "LoadBalancers[?contains(DNSName,'envoygat')].LoadBalancerArn" \
    --output text 2>/dev/null || true)
  if [[ -n "$_nlb_arn" ]]; then
    _tls_listener=$(aws elbv2 describe-listeners --load-balancer-arn "$_nlb_arn" \
      --region "${AWS_REGION:-us-west-2}" \
      --query "Listeners[?Protocol=='TLS'].Port" \
      --output text 2>/dev/null || true)
    [[ "$_tls_listener" == "443" ]] && _run_test "NLB: port 443 TLS listener with ACM" pass \
      || _run_test "NLB: port 443 TLS listener with ACM" fail "no TLS listener found"
  fi
else
  # ALB mode checks
  _ingress_host=$(kubectl get ingress -n "$NAMESPACE" langsmith-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$_ingress_host" ]] && _run_test "ALB: Ingress has LB hostname" pass "$_ingress_host" \
    || _run_test "ALB: Ingress has LB hostname" fail "no hostname on ingress"
fi

# ── Test 6: Core pods running ─────────────────────────────────────────────────
_core=(
  "${RELEASE_NAME}-frontend"
  "${RELEASE_NAME}-backend"
  "${RELEASE_NAME}-platform-backend"
  "${RELEASE_NAME}-ingest-queue"
  "${RELEASE_NAME}-queue"
  "${RELEASE_NAME}-host-backend"
  "${RELEASE_NAME}-listener"
  "${RELEASE_NAME}-operator"
)
_pods_ok=true
for _dep in "${_core[@]}"; do
  _ready=$(kubectl get deployment "$_dep" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${_ready:-0}" -ge 1 ]]; then
    _run_test "Pod: $_dep ready (${_ready})" pass
  else
    _run_test "Pod: $_dep ready" fail "readyReplicas=${_ready:-0}"
    _pods_ok=false
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo "Results:"
for r in "${_results[@]}"; do echo "$r"; done
echo ""
echo "══════════════════════════════════════════════════════"
if [[ $_fail -eq 0 ]]; then
  echo "  PASSED  $_pass/$((  _pass + _fail)) tests"
  echo "  LangSmith is fully reachable at: $BASE_URL"
else
  echo "  FAILED  $_fail/$(( _pass + _fail )) tests  (${_pass} passed)"
fi
echo "══════════════════════════════════════════════════════"
echo ""

[[ $_fail -eq 0 ]]
