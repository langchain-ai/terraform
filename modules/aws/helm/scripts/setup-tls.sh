#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# setup-tls.sh — Install cert-manager and configure Let's Encrypt TLS via Route 53 DNS-01.
#
# Designed for EKS clusters using Istio Gateway as the ingress controller.
# HTTP-01 does NOT work on EKS (NLB hairpin NAT prevents cert-manager self-check).
# DNS-01 via Route 53 IRSA is the correct approach for EKS.
#
# Prerequisites (must be completed before running this script):
#   1. terraform apply with create_cert_manager_irsa = true and cert_manager_hosted_zone_id set
#   2. enable_istio_gateway = true (istiod + istio-ingressgateway installed)
#   3. Istio Gateway resource created in the langsmith namespace
#   4. langsmith_domain set in terraform.tfvars (e.g. langsmith.example.com)
#   5. Your domain's NS records delegated to Route 53
#   6. kubeconfig pointed at the correct cluster (make kubeconfig)
#
# What this script does (in order):
#   1. Reads config from terraform.tfvars and Terraform outputs
#   2. Installs cert-manager via Helm (jetstack/cert-manager)
#   3. Annotates the cert-manager ServiceAccount with the IRSA role ARN
#   4. Creates a ClusterIssuer (Route 53 DNS-01 solver)
#   5. Creates a Certificate resource (triggers cert issuance)
#   6. Waits for the certificate to reach READY=True (~60–120 sec)
#   7. Patches the Istio Gateway for HTTPS with TLS termination + HTTP redirect
#
# After running:
#   - Let's Encrypt issues a cert stored in secret langsmith-tls in istio-system
#   - HTTPS traffic terminates at the Istio ingress gateway NLB
#   - HTTP requests redirect to HTTPS (301)
#   - cert-manager auto-renews the cert before expiry
#
# Usage:
#   make tls
#   # or directly:
#   ./helm/scripts/setup-tls.sh

set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
source "$INFRA_DIR/scripts/_common.sh"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
NAMESPACE="${NAMESPACE:-langsmith}"

# ── Read config from terraform.tfvars ────────────────────────────────────────

_domain=$(_parse_tfvar "langsmith_domain") || _domain=""
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-us-west-2}"
_letsencrypt_email=$(_parse_tfvar "letsencrypt_email") || _letsencrypt_email=""
_hosted_zone_id=$(_parse_tfvar "cert_manager_hosted_zone_id") || _hosted_zone_id=""
_create_irsa=$(_parse_tfvar "create_cert_manager_irsa") || _create_irsa="false"

# ── Validate inputs ───────────────────────────────────────────────────────────

if [[ -z "$_domain" ]]; then
  echo "ERROR: langsmith_domain is not set in terraform.tfvars." >&2
  echo "       Set it to your domain (e.g. langsmith.example.com) and re-run." >&2
  exit 1
fi

if [[ -z "$_letsencrypt_email" ]]; then
  echo "ERROR: letsencrypt_email is not set in terraform.tfvars." >&2
  echo "       Set it to your email address (used for Let's Encrypt expiry notifications)." >&2
  exit 1
fi

if [[ "$_create_irsa" != "true" ]]; then
  echo "ERROR: create_cert_manager_irsa is not true in terraform.tfvars." >&2
  echo "       Set create_cert_manager_irsa = true and run: terraform apply" >&2
  exit 1
fi

if [[ -z "$_hosted_zone_id" ]]; then
  echo "ERROR: cert_manager_hosted_zone_id is not set in terraform.tfvars." >&2
  echo "       Find it: aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]' --output table" >&2
  exit 1
fi

# ── Read IRSA role ARN from Terraform outputs ─────────────────────────────────

echo "Reading Terraform outputs..."
_irsa_role_arn=$(terraform -chdir="$INFRA_DIR" output -raw cert_manager_irsa_role_arn 2>/dev/null) || {
  echo "ERROR: Could not read cert_manager_irsa_role_arn from Terraform outputs." >&2
  echo "       Run: terraform apply  (with create_cert_manager_irsa = true)" >&2
  exit 1
}

if [[ -z "$_irsa_role_arn" || "$_irsa_role_arn" == "null" ]]; then
  echo "ERROR: cert_manager_irsa_role_arn output is empty." >&2
  echo "       Ensure create_cert_manager_irsa = true and terraform apply has been run." >&2
  exit 1
fi

echo "  Domain:        $_domain"
echo "  Email:         $_letsencrypt_email"
echo "  Hosted Zone:   $_hosted_zone_id"
echo "  Region:        $_region"
echo "  IRSA Role ARN: $_irsa_role_arn"
echo ""

# ── Step 1: Install cert-manager ──────────────────────────────────────────────

header "Step 1/6 — Installing cert-manager ${CERT_MANAGER_VERSION}"

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo update >/dev/null

if helm status cert-manager -n cert-manager &>/dev/null; then
  echo "  cert-manager already installed — upgrading..."
fi

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --set crds.enabled=true \
  --wait \
  --timeout 5m

pass "cert-manager installed"

# ── Step 2: Annotate cert-manager ServiceAccount with IRSA role ───────────────

header "Step 2/6 — Annotating cert-manager ServiceAccount with IRSA role"

kubectl annotate serviceaccount cert-manager \
  -n cert-manager \
  "eks.amazonaws.com/role-arn=${_irsa_role_arn}" \
  --overwrite

# Restart cert-manager to pick up the new annotation
kubectl rollout restart deployment/cert-manager -n cert-manager
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s

pass "cert-manager ServiceAccount annotated and restarted"

# ── Step 3: Create ClusterIssuer (Route 53 DNS-01) ───────────────────────────

header "Step 3/6 — Creating ClusterIssuer (Route 53 DNS-01)"

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${_letsencrypt_email}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        route53:
          region: ${_region}
          hostedZoneID: ${_hosted_zone_id}
EOF

pass "ClusterIssuer letsencrypt-prod created"

# ── Step 4: Create Certificate ────────────────────────────────────────────────

header "Step 4/6 — Creating Certificate for ${_domain}"

# TLS secret must be in istio-system — istiod reads credentialName from there
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: langsmith-tls
  namespace: istio-system
spec:
  secretName: langsmith-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "${_domain}"
EOF

pass "Certificate langsmith-tls created in istio-system"

# ── Step 5: Wait for certificate to be issued ─────────────────────────────────

header "Step 5/6 — Waiting for certificate to be issued (DNS propagation ~60-120s)"

echo "  Watching Certificate status (Ctrl-C to skip and run manually later)..."
echo "  Manual check: kubectl get certificate langsmith-tls -n istio-system"
echo ""

_timeout=300
_interval=10
_elapsed=0

while [[ $_elapsed -lt $_timeout ]]; do
  _ready=$(kubectl get certificate langsmith-tls -n istio-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

  if [[ "$_ready" == "True" ]]; then
    pass "Certificate issued — secret langsmith-tls ready in istio-system"
    break
  fi

  _reason=$(kubectl get certificate langsmith-tls -n istio-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Pending")
  echo "  [$_elapsed/${_timeout}s] Certificate status: ${_reason:-Pending}..."

  sleep $_interval
  _elapsed=$(( _elapsed + _interval ))
done

if [[ "$_ready" != "True" ]]; then
  warn "Certificate not yet ready after ${_timeout}s."
  echo ""
  echo "  Check status:    kubectl describe certificate langsmith-tls -n istio-system"
  echo "  Check challenge: kubectl describe challenge -n istio-system"
  echo "  Check orders:    kubectl get orders -n istio-system"
  echo ""
  echo "  Common cause: DNS not yet delegated to Route 53."
  echo "  Verify delegation: dig NS ${_domain} +short"
  echo ""
  echo "  Once the cert is ready, re-run this script (Step 6 is idempotent)."
  exit 0
fi

# ── Step 6: Patch Istio Gateway for HTTPS + HTTP redirect ────────────────────

header "Step 6/6 — Patching Istio Gateway for HTTPS + HTTP redirect"

kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${NAMESPACE}
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "${_domain}"
    tls:
      httpsRedirect: true
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: langsmith-tls
    hosts:
    - "${_domain}"
EOF

pass "Istio Gateway patched for HTTPS with HTTP redirect"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "  TLS setup complete."
echo ""
echo "  LangSmith URL:    https://${_domain}"
echo "  Certificate:      kubectl get certificate langsmith-tls -n istio-system"
echo "  TLS Secret:       kubectl get secret langsmith-tls -n istio-system"
echo "  Expiry:           kubectl get certificate langsmith-tls -n istio-system -o jsonpath='{.status.notAfter}'"
echo ""
echo "  cert-manager auto-renews the certificate 30 days before expiry."
echo ""
