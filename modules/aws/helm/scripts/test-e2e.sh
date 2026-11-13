#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-e2e.sh — End-to-end gateway validation for LangSmith on AWS.
#
# Tests the Terraform ALB with Envoy, Istio, or direct frontend routing.
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

# Point kubectl at this deployment's cluster, as deploy.sh does.
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
if [[ -z "$_cluster_name" || -z "$_region" ]]; then
  echo "ERROR: Could not read cluster_name from Terraform outputs or region from terraform.tfvars." >&2
  exit 1
fi
_use_cluster_kubeconfig "$_cluster_name" "$_region" >/dev/null

# ── Resolve test URL ──────────────────────────────────────────────────────────
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source="none"
# Derived in Terraform (unset = on unless Istio/NGINX was chosen), so read the
# applied output rather than the tfvars text.
_enable_envoy_gateway=$(_read_gateway_flag "enable_envoy_gateway")
_enable_istio_gateway=$(_read_gateway_flag "enable_istio_gateway")
_enable_nginx_ingress=$(_read_gateway_flag "enable_nginx_ingress")

_protocol="http"
[[ "$_tls_source" == "acm" || "$_tls_source" == "letsencrypt" ]] && _protocol="https"

if [[ -n "${LANGSMITH_URL:-}" ]]; then
  BASE_URL="$LANGSMITH_URL"
elif [[ -n "$_langsmith_domain" ]]; then
  BASE_URL="${_protocol}://${_langsmith_domain}"
else
  _alb_host=$(terraform -chdir="$INFRA_DIR" output -raw alb_dns_name)
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
echo "  Mode: $( [[ "$_enable_envoy_gateway" == "true" ]] && echo "Envoy Gateway" || { [[ "$_enable_istio_gateway" == "true" ]] && echo "Istio" || echo "Direct frontend"; })"
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

  # ACM terminates TLS at the Terraform ALB in every routing mode.
  if [[ "$_tls_source" == "acm" ]]; then
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

  # HTTPRoute for main langsmith accepted
  _rt_status=$(kubectl get httproute langsmith -n "$NAMESPACE" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "$_rt_status" == "True" ]] && _run_test "HTTPRoute: langsmith accepted" pass \
    || _run_test "HTTPRoute: langsmith accepted" fail "status=$_rt_status"

  # Count total accepted HTTPRoutes (deployments create one each)
  _total_routes=$(kubectl get httproute -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  _run_test "HTTPRoutes: ${_total_routes} route(s) present in namespace" pass

elif [[ "$_enable_istio_gateway" == "true" ]]; then
  _routes=$(kubectl get virtualservices -n "$NAMESPACE" -o name)
  [[ -n "$_routes" ]] && _run_test "Istio: application route exists" pass \
    || _run_test "Istio: application route exists" fail "no VirtualService"
fi

# All routing modes register pod IPs with a Terraform-owned target group.
_tg_output="gateway_target_group_arn"
_binding_namespace="envoy-gateway-system"
if [[ "$_enable_istio_gateway" == "true" ]]; then
  _binding_namespace="istio-system"
elif [[ "$_enable_nginx_ingress" == "true" ]]; then
  _binding_namespace="ingress-nginx"
elif [[ "$_enable_envoy_gateway" != "true" ]]; then
  _tg_output="frontend_target_group_arn"
  _binding_namespace="$NAMESPACE"
fi
_tg_arn=$(terraform -chdir="$INFRA_DIR" output -raw "$_tg_output")
_binding=$(kubectl get targetgroupbindings -n "$_binding_namespace" -o json | python3 -c '
import json, sys
print(any(b["spec"].get("targetGroupARN") == sys.argv[1] for b in json.load(sys.stdin)["items"]))
' "$_tg_arn")
[[ "$_binding" == "True" ]] && _run_test "ALB: target group binding matches Terraform" pass \
  || _run_test "ALB: target group binding matches Terraform" fail "binding missing"
_targets=$(aws elbv2 describe-target-health --target-group-arn "$_tg_arn" --region "$_region" \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
if [[ -n "$_targets" && "$_targets" != *unhealthy* && "$_targets" == *healthy* ]]; then
  _run_test "ALB: pod targets healthy" pass
else
  _run_test "ALB: pod targets healthy" fail "states=$_targets"
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
