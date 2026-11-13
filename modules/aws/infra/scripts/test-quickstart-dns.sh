#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-quickstart-dns.sh — Regression tests for QuickStart Route 53 choices.
#
# Runs the full AWS wizard against temp directories with scripted answers. It
# covers new-zone and existing-zone output, invalid existing zone IDs, update
# mode preserving both existing-zone answers, and the existing-ACM path that
# does not activate the DNS module. No AWS, Terraform, credentials, or state.
#
# Usage:
#   ./infra/scripts/test-quickstart-dns.sh
#
# Also available as: make test-quickstart
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/quickstart.sh"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS  $1"
}

bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL  $1"
}

has_line() {
  local name="$1" file="$2" expected="$3"
  if grep -Fqx "$expected" "$file"; then
    ok "$name"
  else
    bad "$name (missing '$expected')"
  fi
}

lacks_key() {
  local name="$1" file="$2" key="$3"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    bad "$name ($key was written)"
  else
    ok "$name"
  fi
}

log_has() {
  local name="$1" file="$2" expected="$3"
  if grep -Fq "$expected" "$file"; then
    ok "$name"
  else
    bad "$name (log is missing '$expected')"
  fi
}

log_lacks() {
  local name="$1" file="$2" unexpected="$3"
  if grep -Fq "$unexpected" "$file"; then
    bad "$name (log contains '$unexpected')"
  else
    ok "$name"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Write answers for a fresh dev deployment using ALB + ACM. When acm_arn is
# blank, the DNS module activates and dns_choice is consumed (1=new, 2=reuse).
write_fresh_answers() {
  local file="$1" acm_arn="$2" domain="$3" dns_choice="${4:-}"
  local invalid_zone_id="${5:-}" zone_id="${6:-}"
  local gateway="${7-3}" deployments="${8:-}" sandboxes="${9:-}"
  {
    printf '%s\n' "1"             # Deployment profile: dev
    printf '\n'                    # Name prefix
    printf '\n'                    # Environment
    printf '\n'                    # Region
    printf '\n'                    # Owner
    printf '\n'                    # Cost center
    printf '%s\n' "admin@example.com" # Initial org admin email
    printf '\n'                    # Create VPC: yes
    printf '\n'                    # EKS version
    printf '\n'                    # Node instance type
    printf '\n'                    # Node min
    printf '\n'                    # Node max
    printf '%s\n' "2"             # PostgreSQL: in-cluster
    printf '%s\n' "2"             # Redis: in-cluster
    printf '\n'                    # ClickHouse: in-cluster
    printf '\n'                    # SmithDB: disabled
    printf '%s\n' "$gateway"    # Gateway: default Envoy or explicit selection
    printf '%s\n' "203.0.113.10/32,198.51.100.0/24" # ALB client CIDRs
    printf '%s\n' "$domain"       # Custom domain
    printf '%s\n' "1"             # TLS: ACM
    if [[ -n "$acm_arn" ]]; then
      printf '%s\n' "2"           # Certificate: externally managed
      printf '%s\n' "$acm_arn"    # Existing ACM ARN
    else
      printf '%s\n' "1"           # Certificate: Terraform-managed
    fi
    if [[ -z "$acm_arn" ]]; then
      printf '%s\n' "$dns_choice" # Route 53: new or reuse
      if [[ "$dns_choice" == "2" ]]; then
        [[ -n "$invalid_zone_id" ]] && printf '%s\n' "$invalid_zone_id"
        printf '%s\n' "$zone_id"
      fi
    fi
    printf '\n'                    # Sizing: dev
    printf '%s\n' "$deployments" # Deployments
    printf '\n'                    # Fleet: no
    printf '\n'                    # LangSmith Chat: no
    printf '\n'                    # Insights: no
    printf '%s\n' "$sandboxes"   # Sandboxes
    printf '\n'                    # Write configuration: yes
  } > "$file"
}

# Every answer is accepted from terraform.tfvars in update mode. Keeping this
# list explicit makes a newly inserted prompt fail the test instead of silently
# shifting later answers onto the wrong questions.
write_update_defaults() {
  local file="$1"
  {
    printf '\n' # Update existing file
    printf '\n' # Deployment profile
    printf '\n' # Owner
    printf '\n' # Cost center
    printf '\n' # Initial org admin email
    printf '\n' # EKS version
    printf '\n' # Node instance type
    printf '\n' # Node min
    printf '\n' # Node max
    printf '\n' # PostgreSQL
    printf '\n' # Redis
    printf '\n' # ClickHouse
    printf '\n' # SmithDB
    printf '\n' # Gateway
    printf '\n' # ALB client CIDRs
    printf '\n' # TLS
    printf '\n' # Certificate management
    printf '\n' # Route 53 choice
    printf '\n' # Existing zone ID
    printf '\n' # Sizing
    printf '\n' # Deployments
    printf '\n' # Fleet
    printf '\n' # LangSmith Chat
    printf '\n' # Insights
    printf '\n' # Sandboxes
    printf '\n' # Write configuration
  } > "$file"
}

run_wizard() {
  local name="$1" infra_dir="$2" answers="$3" log="$4"
  mkdir -p "$infra_dir"
  if INFRA_DIR="$infra_dir" bash "$SRC" < "$answers" > "$log" 2>&1; then
    ok "$name"
  else
    bad "$name (wizard exited non-zero; see $log)"
  fi
}

echo "1. Reusing an existing zone validates and writes both DNS answers"
REUSE_INFRA="$TMP/reuse"
write_fresh_answers "$TMP/reuse.answers" "" "langsmith.example.com" \
  "2" "not-a-zone" "Z1ABCDEF123456"
run_wizard "fresh existing-zone run completes" "$REUSE_INFRA" \
  "$TMP/reuse.answers" "$TMP/reuse.log"
has_line "reuse choice is written" "$REUSE_INFRA/terraform.tfvars" \
  "dns_create_zone        = false"
has_line "existing zone ID is written" "$REUSE_INFRA/terraform.tfvars" \
  "dns_existing_zone_id   = \"Z1ABCDEF123456\""
has_line "admin email is written" "$REUSE_INFRA/terraform.tfvars" \
  "langsmith_admin_email = \"admin@example.com\""
log_has "invalid zone ID is rejected" "$TMP/reuse.log" \
  "ERROR: enter a valid Route 53 hosted zone ID starting with Z."
log_has "summary shows reused zone" "$TMP/reuse.log" \
  "existing (Z1ABCDEF123456)"

has_line "ALB CIDRs are written" "$REUSE_INFRA/terraform.tfvars" 'alb_allowed_cidr_blocks = ["203.0.113.10/32", "198.51.100.0/24"]'
log_has "summary includes both ALB CIDRs" "$TMP/reuse.log" "203.0.113.10/32,198.51.100.0/24"

echo "2. Update mode preserves the zone choice, the zone ID, and SSO"
# Turn SSO on the way `make sso` does: by editing only that line.
sed 's/^enable_sso_oidc[[:space:]]*=.*/enable_sso_oidc = true/' "$REUSE_INFRA/terraform.tfvars" > "$TMP/sso.tfvars"
mv "$TMP/sso.tfvars" "$REUSE_INFRA/terraform.tfvars"
sed '/^alb_allowed_cidr_blocks[[:space:]]*=/d' "$REUSE_INFRA/terraform.tfvars" > "$TMP/cidrs.tfvars"
cat >> "$TMP/cidrs.tfvars" <<'TFVARS'
alb_allowed_cidr_blocks = [
  "203.0.113.10/32",
  "198.51.100.0/24",
]
TFVARS
mv "$TMP/cidrs.tfvars" "$REUSE_INFRA/terraform.tfvars"
write_update_defaults "$TMP/update.answers"
run_wizard "existing-zone update run completes" "$REUSE_INFRA" \
  "$TMP/update.answers" "$TMP/update.log"
has_line "reuse choice survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  "dns_create_zone        = false"
has_line "existing zone ID survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  "dns_existing_zone_id   = \"Z1ABCDEF123456\""
has_line "SSO setting survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  "enable_sso_oidc         = true"
has_line "admin email survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  "langsmith_admin_email = \"admin@example.com\""

has_line "all ALB CIDRs survive rerun" "$REUSE_INFRA/terraform.tfvars" 'alb_allowed_cidr_blocks = ["203.0.113.10/32", "198.51.100.0/24"]'

echo "3. Creating a new zone writes the choice without an existing ID"
NEW_INFRA="$TMP/new"
write_fresh_answers "$TMP/new.answers" "" "new.example.com" "1"
run_wizard "fresh new-zone run completes" "$NEW_INFRA" \
  "$TMP/new.answers" "$TMP/new.log"
has_line "new-zone choice is written" "$NEW_INFRA/terraform.tfvars" \
  "dns_create_zone        = true"
lacks_key "new-zone mode omits an existing ID" "$NEW_INFRA/terraform.tfvars" \
  "dns_existing_zone_id"
log_has "summary shows newly created zone" "$TMP/new.log" \
  "Terraform-managed (new.example.com)"

echo "4. A supplied ACM ARN keeps the DNS module questions disabled"
ACM_INFRA="$TMP/acm"
write_fresh_answers "$TMP/acm.answers" \
  "arn:aws:acm:us-west-2:123456789012:certificate/abc123" \
  "acm.example.com"
run_wizard "existing-ACM run completes" "$ACM_INFRA" \
  "$TMP/acm.answers" "$TMP/acm.log"
lacks_key "existing ACM omits dns_create_zone" "$ACM_INFRA/terraform.tfvars" \
  "dns_create_zone"
lacks_key "existing ACM omits dns_existing_zone_id" "$ACM_INFRA/terraform.tfvars" \
  "dns_existing_zone_id"
log_lacks "existing ACM skips the Route 53 question" "$TMP/acm.log" \
  "Route 53 hosted zone for acm.example.com:"

echo "5. Fresh configurations default to Envoy"
DEFAULT_INFRA="$TMP/default"
write_fresh_answers "$TMP/default.answers" \
  "arn:aws:acm:us-west-2:123456789012:certificate/abc123" \
  "default.example.com" "" "" "" ""
run_wizard "default gateway run completes" "$DEFAULT_INFRA" "$TMP/default.answers" "$TMP/default.log"
has_line "Envoy remains the default" "$DEFAULT_INFRA/terraform.tfvars" 'enable_envoy_gateway    = true'

echo "6. ALB-only mode accepts Sandboxes"
SANDBOX_INFRA="$TMP/sandbox"
write_fresh_answers "$TMP/sandbox.answers" \
  "arn:aws:acm:us-west-2:123456789012:certificate/abc123" \
  "sandbox.example.com" "" "" "" "3" "" "y"
run_wizard "ALB-only Sandbox run completes" "$SANDBOX_INFRA" "$TMP/sandbox.answers" "$TMP/sandbox.log"
if grep -Eq '^enable_sandboxes[[:space:]]*=[[:space:]]*true$' "$SANDBOX_INFRA/terraform.tfvars"; then
  ok "Sandboxes are enabled"
else
  bad "Sandboxes were not enabled"
fi

echo "7. No-gateway mode rejects Deployments before writing configuration"
INVALID_INFRA="$TMP/invalid"
mkdir -p "$INVALID_INFRA"
write_fresh_answers "$TMP/invalid.answers" \
  "arn:aws:acm:us-west-2:123456789012:certificate/abc123" \
  "invalid.example.com" "" "" "" "3" "y"
if INFRA_DIR="$INVALID_INFRA" bash "$SRC" < "$TMP/invalid.answers" > "$TMP/invalid.log" 2>&1; then
  bad "unsupported no-gateway combination was accepted"
else
  log_has "no-gateway rejection explains the dependency" "$TMP/invalid.log" "Agent deployment endpoints require Envoy"
  if [[ ! -f "$INVALID_INFRA/terraform.tfvars" ]]; then
    ok "unsupported configuration was not written"
  else
    bad "unsupported configuration was written"
  fi
fi

echo ""
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
