#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
export AWS_PAGER=""

# tls.sh — BYO ACM: request + DNS-validate an ACM cert, create Route53 A alias.
#
# Usage:
#   make tls        (from aws/)
#   ./helm/scripts/tls.sh
#
# Reads from terraform.tfvars:
#   langsmith_domain    — domain to certify, e.g. dz-envoy-dev.workshop.langchain.com
#   acm_certificate_arn — if already set, skip cert request and just update DNS
#   region              — AWS region
#
# Reads from terraform outputs (infra/):
#   alb_dns_name        — ALB DNS for Route53 alias
#
# After running:
#   - ACM cert is ISSUED and validated
#   - Route53 A alias record points to the ALB
#   - acm_certificate_arn is written into terraform.tfvars automatically
#   - Run: make apply && make init-values && make deploy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../../infra"
source "$INFRA_DIR/scripts/_common.sh"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith AWS — TLS / ACM + Route53 setup"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Read config ───────────────────────────────────────────────────────────────
_domain=$(_parse_tfvar "langsmith_domain") || _domain=""
_existing_arn=$(_parse_tfvar "acm_certificate_arn") || _existing_arn=""
_region=$(_parse_tfvar "region") || _region="${AWS_DEFAULT_REGION:-us-east-1}"

if [[ -z "$_domain" ]]; then
  echo "ERROR: langsmith_domain is not set in terraform.tfvars." >&2
  echo "       Add: langsmith_domain = \"your.domain.com\"" >&2
  exit 1
fi

echo "Domain:  $_domain"
echo "Region:  $_region"
echo ""

# ── Resolve ALB DNS from Terraform outputs ────────────────────────────────────
echo "Reading Terraform outputs..."
ALB_DNS=$(terraform -chdir="$INFRA_DIR" output -raw alb_dns_name 2>/dev/null) || {
  echo "ERROR: Could not read alb_dns_name. Run 'make apply' first." >&2
  exit 1
}
echo "  alb_dns_name = $ALB_DNS"

# Get the ALB's canonical hosted zone ID (needed for Route53 alias target).
ALB_NAME=$(echo "$ALB_DNS" | cut -d. -f1 | sed 's/-[0-9]*$//')
ALB_HZ=$(aws elbv2 describe-load-balancers \
  --region "$_region" \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].CanonicalHostedZoneId | [0]" \
  --output text 2>/dev/null) || ALB_HZ=""

if [[ -z "$ALB_HZ" || "$ALB_HZ" == "None" ]]; then
  # Fallback: look up by name prefix
  ALB_HZ=$(aws elbv2 describe-load-balancers \
    --region "$_region" \
    --query "LoadBalancers[?contains(DNSName,'${ALB_DNS}')].CanonicalHostedZoneId | [0]" \
    --output text 2>/dev/null) || ALB_HZ=""
fi

if [[ -z "$ALB_HZ" || "$ALB_HZ" == "None" ]]; then
  echo "ERROR: Could not resolve ALB canonical hosted zone ID for $ALB_DNS" >&2
  exit 1
fi
echo "  alb_hosted_zone_id = $ALB_HZ"
echo ""

# ── Find Route53 hosted zone for the domain ───────────────────────────────────
# Walk up the domain labels until we find a matching hosted zone.
# e.g. dz-envoy-dev.workshop.langchain.com → try workshop.langchain.com → langchain.com
_find_zone() {
  local domain="$1"
  local parts
  IFS='.' read -ra parts <<< "$domain"
  local n=${#parts[@]}
  for (( i=1; i<n-1; i++ )); do
    local candidate="${parts[*]:$i}"
    candidate="${candidate// /.}"
    local zone_id
    zone_id=$(aws route53 list-hosted-zones \
      --query "HostedZones[?Name=='${candidate}.'].Id | [0]" \
      --output text 2>/dev/null | sed 's|/hostedzone/||') || true
    if [[ -n "$zone_id" && "$zone_id" != "None" ]]; then
      echo "$zone_id $candidate"
      return 0
    fi
  done
  return 1
}

echo "Resolving Route53 hosted zone..."
_zone_info=$(_find_zone "$_domain") || {
  echo "ERROR: No Route53 hosted zone found for any parent of $_domain" >&2
  echo "       Available zones:" >&2
  aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]' --output table >&2
  exit 1
}
ZONE_ID=$(echo "$_zone_info" | cut -d' ' -f1)
ZONE_NAME=$(echo "$_zone_info" | cut -d' ' -f2)
echo "  zone: $ZONE_NAME ($ZONE_ID)"
echo ""

# ── ACM certificate ───────────────────────────────────────────────────────────
CERT_ARN=""

if [[ -n "$_existing_arn" ]]; then
  echo "BYO cert detected (acm_certificate_arn in tfvars):"
  echo "  $_existing_arn"
  # Verify it's still valid
  _status=$(aws acm describe-certificate \
    --certificate-arn "$_existing_arn" \
    --region "$_region" \
    --query 'Certificate.Status' --output text 2>/dev/null) || _status="UNKNOWN"
  echo "  status: $_status"
  if [[ "$_status" == "ISSUED" ]]; then
    pass "Certificate already issued — skipping request."
    CERT_ARN="$_existing_arn"
  else
    warn "Certificate status is $_status — requesting a fresh one."
  fi
fi

if [[ -z "$CERT_ARN" ]]; then
  echo "Requesting ACM certificate for: $_domain"
  CERT_ARN=$(aws acm request-certificate \
    --domain-name "$_domain" \
    --validation-method DNS \
    --region "$_region" \
    --query 'CertificateArn' --output text)
  echo "  ARN: $CERT_ARN"
  echo "  Waiting for ACM to generate validation records (5s)..."
  sleep 5
fi

# ── DNS validation CNAME ──────────────────────────────────────────────────────
echo ""
echo "Creating DNS validation CNAME in Route53..."
_val_record=$(aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --region "$_region" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
  --output json 2>/dev/null)

_val_name=$(echo "$_val_record" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Name'])" 2>/dev/null) || _val_name=""
_val_value=$(echo "$_val_record" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Value'])" 2>/dev/null) || _val_value=""

if [[ -z "$_val_name" || -z "$_val_value" ]]; then
  echo "ERROR: Could not read ACM validation CNAME. The cert may still be pending." >&2
  echo "       Wait a few seconds and re-run: make tls" >&2
  exit 1
fi

aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "$(cat <<JSON
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${_val_name}",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "${_val_value}"}]
    }
  }]
}
JSON
)" \
  --query 'ChangeInfo.Status' --output text
pass "Validation CNAME upserted."

# ── Route53 A alias for the domain → ALB ─────────────────────────────────────
echo ""
echo "Creating Route53 A alias: $_domain → $ALB_DNS"
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "$(cat <<JSON
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${_domain}.",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${ALB_HZ}",
        "DNSName": "${ALB_DNS}",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
JSON
)" \
  --query 'ChangeInfo.Status' --output text
pass "A alias record upserted."

# ── Wait for cert validation ──────────────────────────────────────────────────
echo ""
echo "Waiting for ACM certificate to be issued (DNS propagation ~60s)..."
aws acm wait certificate-validated \
  --certificate-arn "$CERT_ARN" \
  --region "$_region"
pass "Certificate ISSUED: $CERT_ARN"

# ── Write acm_certificate_arn back into terraform.tfvars ─────────────────────
echo ""
TFVARS="$INFRA_DIR/terraform.tfvars"
if grep -qE '^\s*acm_certificate_arn\s*=' "$TFVARS" 2>/dev/null; then
  sed -i.bak "s|acm_certificate_arn\s*=.*|acm_certificate_arn    = \"${CERT_ARN}\"|" "$TFVARS" \
    && rm -f "${TFVARS}.bak"
  pass "Updated acm_certificate_arn in terraform.tfvars"
else
  # Insert after tls_certificate_source line
  sed -i.bak "/^tls_certificate_source/a\\
acm_certificate_arn    = \"${CERT_ARN}\"" "$TFVARS" && rm -f "${TFVARS}.bak"
  pass "Added acm_certificate_arn to terraform.tfvars"
fi

echo ""
echo "══════════════════════════════════════════════════════"
pass "TLS setup complete."
echo ""
echo "  Domain:  https://$_domain"
echo "  Cert:    $CERT_ARN"
echo ""
echo "  Next steps:"
echo "    make apply        # add HTTPS listener to ALB"
echo "    make init-values  # update Helm values with https:// URL"
echo "    make deploy       # redeploy LangSmith"
echo "══════════════════════════════════════════════════════"
echo ""
