#!/usr/bin/env bash

# MIT License - Copyright (c) 2024 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# deploy.sh — Deploy or upgrade LangSmith via Helm on Azure.
#
# Values files loaded (in order, last wins):
#   1. values.yaml                               — base Azure config (always)
#   2. values-overrides.yaml                     — env-specific: hostname, WI, blob (required)
#   3. langsmith-values-sizing-{profile}.yaml    — sizing profile (from sizing_profile in terraform.tfvars)
#   4. langsmith-values-agent-deploys.yaml       — Deployments feature (if enable_deployments = true)
#   5. langsmith-values-agent-builder.yaml       — Agent Builder (if enable_agent_builder = true)
#   6. langsmith-values-insights.yaml            — Insights/Clio (if enable_insights = true)
#   7. langsmith-values-polly.yaml               — Polly (if enable_polly = true)
#
# Generate values files first: make init-values (or: ./helm/scripts/init-values.sh)
# Templates live in helm/values/examples/ — init-values.sh copies them based on your choices.
#
# Usage (from azure/):
#   ./helm/scripts/deploy.sh
#   CHART_VERSION=0.13.29 ./helm/scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"

source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
CHART_VERSION="${CHART_VERSION:-}"

BASE_VALUES_FILE="$VALUES_DIR/values.yaml"
OVERRIDES_FILE="$VALUES_DIR/values-overrides.yaml"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith Azure — Helm Deploy"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Validate required values files ────────────────────────────────────────
if [[ ! -f "$OVERRIDES_FILE" ]]; then
  fail "values-overrides.yaml not found"
  action "make init-values  (generates it from terraform outputs)"
  exit 1
fi

# ── Point kubeconfig at the right cluster ─────────────────────────────────
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw aks_cluster_name 2>/dev/null) || {
  fail "Could not read aks_cluster_name. Is 'terraform apply' complete?"
  exit 1
}
_rg_name=$(terraform -chdir="$INFRA_DIR" output -raw resource_group_name 2>/dev/null) || _rg_name=""

info "Cluster: ${_cluster_name}"
az aks get-credentials --name "$_cluster_name" --resource-group "$_rg_name" \
  --overwrite-existing &>/dev/null
info "Active context: $(kubectl config current-context)"
echo ""

# ── Set DNS label annotation on the ingress LoadBalancer service ──────────
# Azure assigns <dns_label>.<region>.cloudapp.azure.com to the public IP only when
# the annotation service.beta.kubernetes.io/azure-dns-label-name is on the LB service.
# Works for ALL ingress controllers — nginx, istio, istio-addon, envoy-gateway.
# cert-manager's HTTP-01 challenge requires DNS to resolve before cert issuance.
_dns_label=$(_parse_tfvar "dns_label") || _dns_label=""
_location=$(_parse_tfvar "location") || _location="eastus"
_ingress_controller=$(_parse_tfvar "ingress_controller") || _ingress_controller="nginx"
if [[ -n "$_dns_label" ]]; then
  case "$_ingress_controller" in
    nginx)
      _lb_svc="ingress-nginx-controller"
      _lb_ns="ingress-nginx"
      ;;
    istio-addon)
      _lb_svc="aks-istio-ingressgateway-external"
      _lb_ns="aks-istio-ingress"
      ;;
    istio)
      _lb_svc="istio-ingressgateway"
      _lb_ns="istio-system"
      ;;
    envoy-gateway)
      # Envoy Gateway service name follows pattern: envoy-<namespace>-<gateway-name>
      # Default gateway name in our setup is "langsmith"
      _lb_svc="envoy-langsmith-langsmith-gateway"
      _lb_ns="langsmith"
      ;;
    *)
      _lb_svc=""
      _lb_ns=""
      ;;
  esac
  if [[ -n "$_lb_svc" ]] && kubectl get svc "$_lb_svc" -n "$_lb_ns" &>/dev/null; then
    kubectl annotate svc "$_lb_svc" -n "$_lb_ns" \
      "service.beta.kubernetes.io/azure-dns-label-name=${_dns_label}" \
      --overwrite &>/dev/null
    pass "DNS label set (${_ingress_controller}): ${_dns_label}.${_location}.cloudapp.azure.com"
  elif [[ -n "$_lb_svc" ]]; then
    warn "${_lb_svc} not found in ${_lb_ns} — DNS label not set (run make apply first)"
  fi
fi

# ── Apply letsencrypt-prod ClusterIssuer ──────────────────────────────────
# kubernetes_manifest in Terraform can't create this on fresh deploy (no cluster
# exists during plan). Applied here instead — idempotent, safe to re-run.
# The ingress class used by the HTTP-01 solver must match the active ingress controller.
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source=""
if [[ "$_tls_source" == "letsencrypt" ]]; then
  _le_email=$(_parse_tfvar "letsencrypt_email") || _le_email=""
  _le_namespace=$(_parse_tfvar "langsmith_namespace") || _le_namespace="langsmith"
  _le_hostname="${_dns_label}.${_location}.cloudapp.azure.com"
  _le_domain=$(_parse_tfvar "langsmith_domain") || _le_domain=""
  [[ -n "$_le_domain" ]] && _le_hostname="$_le_domain"

  if [[ "$_ingress_controller" == "envoy-gateway" ]]; then
    # Envoy Gateway uses Gateway API — cert-manager gatewayHTTPRoute solver
    # requires ExperimentalGatewayAPISupport feature gate on cert-manager controller.
    # deploy.sh enables this gate automatically (kubectl patch).
    kubectl patch deployment cert-manager -n cert-manager --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=ExperimentalGatewayAPISupport=true"}]' &>/dev/null || true
    kubectl apply -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${_le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        gatewayHTTPRoute:
          parentRefs:
          - name: langsmith-gateway
            namespace: ${_le_namespace}
            kind: Gateway
EOF
    pass "ClusterIssuer letsencrypt-prod configured (solver: gatewayHTTPRoute)"
  else
    # Map ingress controller to the class cert-manager uses for HTTP-01 solvers
    case "$_ingress_controller" in
      istio|istio-addon) _acme_ingress_class="istio" ;;
      nginx)             _acme_ingress_class="nginx" ;;
      agic)              _acme_ingress_class="azure-application-gateway" ;;
      *)                 _acme_ingress_class="nginx" ;;
    esac
    kubectl apply -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${_le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          ingressClassName: ${_acme_ingress_class}
EOF
    pass "ClusterIssuer letsencrypt-prod configured (solver class: ${_acme_ingress_class})"
  fi
fi

# ── Self-managed Istio: create IngressClass resource ──────────────────────
# istiod needs an IngressClass named "istio" to exist so it generates listeners
# for the istio-ingressgateway. Without it, LDS push has 0 resources.
if [[ "$_ingress_controller" == "istio" ]]; then
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
EOF
  pass "IngressClass 'istio' created"
fi

# ── Create Istio Gateway resource (istio-addon only) ──────────────────────
# With AKS managed Istio, ingressClassName: istio targets label istio: ingressgateway
# but the AKS external gateway has label istio: aks-istio-ingressgateway-external.
# We create explicit Gateway + VirtualService to route port 80/443 correctly.
if [[ "$_ingress_controller" == "istio-addon" && -n "$_dns_label" ]]; then
  _istio_hostname="${_dns_label}.${_location}.cloudapp.azure.com"
  _langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
  [[ -n "$_langsmith_domain" ]] && _istio_hostname="$_langsmith_domain"
  _namespace=$(_parse_tfvar "langsmith_namespace") || _namespace="langsmith"

  kubectl apply -f - &>/dev/null <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${_namespace}
spec:
  selector:
    istio: aks-istio-ingressgateway-external
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "${_istio_hostname}"
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: langsmith-tls
    hosts:
    - "${_istio_hostname}"
EOF
  pass "Istio Gateway created: ${_istio_hostname} (ports 80 + 443)"
fi

# ── Preflight checks ──────────────────────────────────────────────────────
"$SCRIPT_DIR/preflight-check.sh"

# ── Ensure langsmith-config-secret exists ─────────────────────────────────
info "Verifying langsmith-config-secret..."
if ! kubectl get secret langsmith-config-secret -n "$NAMESPACE" &>/dev/null; then
  warn "langsmith-config-secret not found — creating from Key Vault..."
  bash "$INFRA_DIR/scripts/create-k8s-secrets.sh"
else
  pass "langsmith-config-secret exists"
fi

# Note: langsmith-clickhouse secret not checked here — in-cluster ClickHouse
# is managed by the chart. External ClickHouse requires a separate secret;
# see langsmith-values-insights.yaml for instructions.

# ── Pre-deploy hostname check ─────────────────────────────────────────────
_configured_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
  | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _configured_hostname=""
if [[ -n "$_configured_hostname" && "$_configured_hostname" == *"<"* ]]; then
  warn "config.hostname still contains a placeholder — run: make init-values"
fi

# ── Read feature flags from terraform.tfvars ──────────────────────────────
_sizing_profile=$(_parse_tfvar "sizing_profile") || _sizing_profile="default"
_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true  || true
_tfvar_is_true "enable_agent_builder" && _enable_agent_builder=true || true
_tfvar_is_true "enable_insights"      && _enable_insights=true     || true
_tfvar_is_true "enable_polly"         && _enable_polly=true        || true

# Validate addon dependencies
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  fail "enable_agent_builder = true requires enable_deployments = true in terraform.tfvars"
  exit 1
fi

# ── Build values args ─────────────────────────────────────────────────────
VALUES_ARGS=()

# Base values (optional — provides Azure defaults + production sizing)
if [[ -f "$BASE_VALUES_FILE" ]]; then
  VALUES_ARGS+=(-f "$BASE_VALUES_FILE")
  echo "Values chain:"
  echo "  ✔ values.yaml (base)"
else
  echo "Values chain:"
  echo "  ○ values.yaml (not found — using overrides only)"
fi

VALUES_ARGS+=(-f "$OVERRIDES_FILE")
echo "  ✔ values-overrides.yaml"

# Sizing profile
if [[ "$_sizing_profile" != "default" ]]; then
  _sizing_file="$VALUES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  if [[ -f "$_sizing_file" ]]; then
    VALUES_ARGS+=(-f "$_sizing_file")
    echo "  ✔ langsmith-values-sizing-${_sizing_profile}.yaml (sizing_profile = ${_sizing_profile})"
    if [[ "$_sizing_profile" == "minimum" ]]; then
      echo ""
      echo "  ⚠️  WARNING: sizing_profile = minimum — NOT for production."
      echo "     Use sizing_profile = production for production deployments."
      echo ""
    fi
  else
    echo "  ✗ langsmith-values-sizing-${_sizing_profile}.yaml (not found — run: make init-values)"
  fi
else
  echo "  ○ sizing: base values defaults (sizing_profile = default)"
fi

# Addon overlays
_addon_gate=(
  "agent-deploys:deployments:$_enable_deployments"
  "agent-builder:agent_builder:$_enable_agent_builder"
  "insights:insights:$_enable_insights"
  "polly:polly:$_enable_polly"
)
for entry in "${_addon_gate[@]}"; do
  addon="${entry%%:*}"
  rest="${entry#*:}"
  flag_name="${rest%%:*}"
  enabled="${rest##*:}"
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ "$enabled" == "true" ]]; then
    if [[ -f "$f" ]]; then
      VALUES_ARGS+=(-f "$f")
      echo "  ✔ langsmith-values-${addon}.yaml (enable_${flag_name} = true)"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (enable_${flag_name} = true but file not found — run: make init-values)"
    fi
  else
    if [[ -f "$f" ]]; then
      echo "  ○ langsmith-values-${addon}.yaml (file exists but enable_${flag_name} = false — skipped)"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (not enabled)"
    fi
  fi
done
echo ""

# ── Chart version ─────────────────────────────────────────────────────────
# Read from terraform.tfvars first, then env var, then prompt (interactive only)
if [[ -z "$CHART_VERSION" ]]; then
  CHART_VERSION=$(_parse_tfvar "langsmith_helm_chart_version") || CHART_VERSION=""
fi

if [[ -z "$CHART_VERSION" ]]; then
  helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
  helm repo update langchain &>/dev/null
  echo "Available chart versions:"
  helm search repo langchain/langsmith --versions | head -6
  echo ""
  if [[ -t 0 ]]; then
    # Interactive terminal — prompt for version
    printf "  Chart version to deploy (e.g. 0.13.29, or press Enter for latest): "
    read -r CHART_VERSION
  else
    # Non-interactive — default to latest
    info "Non-interactive mode: deploying latest chart version"
  fi
fi

# ── Pending-upgrade guard ─────────────────────────────────────────────────
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
if [[ "$_release_status" == "pending-upgrade" ]]; then
  warn "Helm release '${RELEASE_NAME}' is in 'pending-upgrade' state (interrupted upgrade)."
  info "Rolling back to clear the lock..."
  helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
  echo ""
elif [[ "$_release_status" == "failed" ]]; then
  warn "Helm release '${RELEASE_NAME}' is in 'failed' state."
  info "This is usually caused by a hook timeout — proceeding with upgrade."
  echo ""
fi

# ── Deploy ────────────────────────────────────────────────────────────────
info "Deploying LangSmith (sizing: ${_sizing_profile})..."
info "(waiting for pods — 5-15 min on a cold cluster)"
echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain &>/dev/null

helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  "${VALUES_ARGS[@]}" \
  ${EXTRA_HELM_ARGS:+$EXTRA_HELM_ARGS} \
  --server-side=false \
  --timeout 20m

echo ""
pass "LangSmith deployed. Waiting for core pods..."
echo ""

# ── Wait for core components ──────────────────────────────────────────────
_core_deployments=(
  "${RELEASE_NAME}-frontend"
  "${RELEASE_NAME}-backend"
  "${RELEASE_NAME}-platform-backend"
  "${RELEASE_NAME}-ingest-queue"
  "${RELEASE_NAME}-queue"
)
if [[ "$_enable_deployments" == "true" ]]; then
  _core_deployments+=(
    "${RELEASE_NAME}-host-backend"
    "${RELEASE_NAME}-listener"
    "${RELEASE_NAME}-operator"
  )
fi

_all_ready=true
for dep in "${_core_deployments[@]}"; do
  if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    warn "$dep not ready within 5m (may still be starting)"
    _all_ready=false
  fi
done

if [[ "$_all_ready" == "true" ]]; then
  pass "All core deployments ready"
else
  warn "Some deployments are still rolling out — check with: kubectl get pods -n $NAMESPACE"
fi
echo ""

# ── Post-deploy Envoy Gateway routing ─────────────────────────────────────
# Envoy Gateway uses Gateway API (GatewayClass → Gateway → HTTPRoute).
# The LangSmith Helm chart ingress is disabled (ingress.enabled: false).
# We create the Gateway API resources here so make deploy is fully automated.
if [[ "$_ingress_controller" == "envoy-gateway" ]]; then
  _eg_namespace=$(_parse_tfvar "langsmith_namespace") || _eg_namespace="langsmith"
  _eg_hostname="${_dns_label}.${_location}.cloudapp.azure.com"
  _eg_domain=$(_parse_tfvar "langsmith_domain") || _eg_domain=""
  [[ -n "$_eg_domain" ]] && _eg_hostname="$_eg_domain"
  _eg_release=$(_parse_tfvar "langsmith_release_name") || _eg_release="langsmith"

  # GatewayClass — points to the Envoy Gateway controller
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: langsmith-eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

  # Gateway — creates the Envoy proxy LB with TLS termination
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${_eg_namespace}
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  gatewayClassName: langsmith-eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "${_eg_hostname}"
    tls:
      mode: Terminate
      certificateRefs:
      - name: langsmith-tls
    allowedRoutes:
      namespaces:
        from: Same
EOF
  pass "Envoy Gateway GatewayClass + Gateway created"

  # HTTPRoute — routes all traffic to LangSmith frontend
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: langsmith
  namespace: ${_eg_namespace}
spec:
  parentRefs:
  - name: langsmith-gateway
    namespace: ${_eg_namespace}
  hostnames:
  - "${_eg_hostname}"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: ${_eg_release}-frontend
      port: 80
EOF
  pass "Envoy Gateway HTTPRoute created: ${_eg_hostname}"

  # Wait for Gateway LB service and annotate with DNS label.
  # Envoy Gateway creates the LB in envoy-gateway-system namespace with label:
  #   gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway
  info "Waiting for Envoy Gateway LoadBalancer IP..."
  _eg_svc_name=""
  for i in $(seq 1 30); do
    _eg_svc_name=$(kubectl get svc -n "envoy-gateway-system" \
      -l "gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$_eg_svc_name" ]] && break
    sleep 5
  done

  if [[ -n "$_eg_svc_name" && -n "$_dns_label" ]]; then
    kubectl annotate svc "$_eg_svc_name" -n "envoy-gateway-system" \
      "service.beta.kubernetes.io/azure-dns-label-name=${_dns_label}" --overwrite &>/dev/null
    pass "DNS label '${_dns_label}' set on envoy-gateway-system/${_eg_svc_name}"
  else
    warn "Could not find Envoy Gateway LB service — DNS label not set. Run: make deploy again after pods are ready"
  fi
fi

# ── Post-deploy self-managed Istio TLS sync ───────────────────────────────
# istiod reads the TLS secret via SDS using kubernetes:// scheme.
# For self-managed Istio, the secret must exist in istio-system namespace
# (the gateway pod namespace) — istiod serves it to the gateway via ADS/SDS.
# Without this sync, the gateway returns "no peer certificate available".
if [[ "$_ingress_controller" == "istio" && "$_tls_source" == "letsencrypt" ]]; then
  _istio_ns=$(_parse_tfvar "langsmith_namespace") || _istio_ns="langsmith"
  info "Waiting for TLS certificate langsmith-tls in ${_istio_ns}..."
  _cert_ready=false
  for i in $(seq 1 18); do
    if kubectl get secret langsmith-tls -n "$_istio_ns" &>/dev/null 2>&1; then
      _cert_ready=true; break
    fi
    sleep 10
  done
  if [[ "$_cert_ready" == "true" ]]; then
    kubectl get secret langsmith-tls -n "$_istio_ns" -o json 2>/dev/null | \
      python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'istio-system'
for k in ['resourceVersion','uid','creationTimestamp']:
    s['metadata'].pop(k, None)
s['metadata']['annotations'] = {}
print(json.dumps(s))
" | kubectl apply -f - &>/dev/null
    pass "TLS secret synced to istio-system namespace"
  else
    warn "TLS certificate not ready within 3 min — sync skipped. Re-run: make deploy"
  fi
fi

# ── Post-deploy Istio routing (istio-addon only) ──────────────────────────
# After cert-manager issues the TLS cert, copy the secret to aks-istio-ingress
# so the Gateway can load it via SDS (credentialName lookup uses gateway pod namespace).
# Also create the LangSmith VirtualService to route traffic through the Gateway.
if [[ "$_ingress_controller" == "istio-addon" && -n "$_dns_label" ]]; then
  _namespace=$(_parse_tfvar "langsmith_namespace") || _namespace="langsmith"
  _langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
  _istio_hostname="${_dns_label}.${_location}.cloudapp.azure.com"
  [[ -n "$_langsmith_domain" ]] && _istio_hostname="$_langsmith_domain"

  # Wait for TLS cert to be ready (max 3 min) then sync to gateway namespace
  info "Waiting for TLS certificate langsmith-tls..."
  _cert_ready=false
  for i in $(seq 1 18); do
    if kubectl get secret langsmith-tls -n "$_namespace" &>/dev/null 2>&1; then
      _cert_ready=true
      break
    fi
    sleep 10
  done

  if [[ "$_cert_ready" == "true" ]]; then
    # Sync TLS secret to aks-istio-ingress namespace (required for Gateway credentialName)
    kubectl get secret langsmith-tls -n "$_namespace" -o json 2>/dev/null | \
      python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'aks-istio-ingress'
for k in ['resourceVersion','uid','creationTimestamp']:
    s['metadata'].pop(k, None)
s['metadata']['annotations'] = {}
print(json.dumps(s))
" | kubectl apply -f - &>/dev/null
    pass "TLS secret synced to aks-istio-ingress namespace"
  else
    warn "TLS certificate not ready within 3 min — sync skipped. Re-run: make deploy"
  fi

  # Create VirtualService for LangSmith routing through the Istio Gateway
  _release=$(_parse_tfvar "langsmith_release_name") || _release="langsmith"
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: langsmith
  namespace: ${_namespace}
spec:
  hosts:
  - "${_istio_hostname}"
  gateways:
  - langsmith-gateway
  http:
  - match:
    - uri:
        prefix: "/.well-known/acme-challenge/"
    route:
    - destination:
        host: $(kubectl get svc -n "$_namespace" -l acme.cert-manager.io/http01-solver=true \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "cm-acme-http-solver").${_namespace}.svc.cluster.local
        port:
          number: $(kubectl get svc -n "$_namespace" -l acme.cert-manager.io/http01-solver=true \
            -o jsonpath='{.items[0].spec.ports[0].port}' 2>/dev/null || echo "8089")
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: ${_release}-frontend.${_namespace}.svc.cluster.local
        port:
          number: 80
EOF
  pass "VirtualService configured for ${_istio_hostname}"
fi

# ── Ensure langsmith-ksa carries the WI annotation ───────────────────────
# langsmith-ksa is used by operator-spawned agent deployment pods.
# It is created by the operator on first use (not part of Helm release).
_wi_client_id=$(terraform -chdir="$INFRA_DIR" output -raw storage_account_k8s_managed_identity_client_id 2>/dev/null || true)
if [[ -n "$_wi_client_id" ]]; then
  kubectl create serviceaccount langsmith-ksa -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
  kubectl annotate serviceaccount langsmith-ksa -n "$NAMESPACE" \
    azure.workload.identity/client-id="$_wi_client_id" --overwrite &>/dev/null
  pass "langsmith-ksa WI annotation: ${_wi_client_id}"
fi

# ── Post-deploy access info ───────────────────────────────────────────────
_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
  | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
_kv_name=$(terraform -chdir="$INFRA_DIR" output -raw keyvault_name 2>/dev/null || true)
_admin_email=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_admin_email 2>/dev/null || true)

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith deployed"
echo "══════════════════════════════════════════════════════"
echo ""
[[ -n "$_hostname" ]] && echo "  URL      : https://${_hostname}"
[[ -n "$_admin_email" ]] && echo "  Login    : ${_admin_email}"
[[ -n "$_kv_name" ]] && echo "  Password : az keyvault secret show --vault-name ${_kv_name} --name langsmith-admin-password --query value -o tsv"
echo ""
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get ingress -n ${NAMESPACE}"
echo "  kubectl get certificate -n ${NAMESPACE}"
echo ""
echo "  make status   # for a full health check"
echo ""
