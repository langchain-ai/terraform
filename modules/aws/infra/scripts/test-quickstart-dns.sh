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
  {
    printf '%s\n' "1"             # Deployment profile: dev
    printf '\n'                    # Name prefix
    printf '\n'                    # Environment
    printf '\n'                    # Region
    printf '\n'                    # Owner
    printf '\n'                    # Cost center
    printf '\n'                    # Create VPC: yes
    printf '\n'                    # EKS version
    printf '\n'                    # Node instance type
    printf '\n'                    # Node min
    printf '\n'                    # Node max
    printf '%s\n' "2"             # Backends: in-cluster
    printf '\n'                    # ClickHouse: in-cluster
    printf '%s\n' "2"             # Gateway: ALB
    printf '%s\n' "1"             # TLS: ACM
    printf '%s\n' "$acm_arn"      # Existing ACM ARN or auto-provision
    printf '%s\n' "$domain"       # Custom domain
    if [[ -z "$acm_arn" ]]; then
      printf '%s\n' "$dns_choice" # Route 53: new or reuse
      if [[ "$dns_choice" == "2" ]]; then
        [[ -n "$invalid_zone_id" ]] && printf '%s\n' "$invalid_zone_id"
        printf '%s\n' "$zone_id"
      fi
    fi
    printf '\n'                    # Sizing: dev
    printf '\n'                    # Deployments: no
    printf '\n'                    # Insights: no
    printf '\n'                    # SmithDB: no
    printf '\n'                    # Sandboxes: no
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
    printf '\n' # Name prefix
    printf '\n' # Environment
    printf '\n' # Region
    printf '\n' # Owner
    printf '\n' # Cost center
    printf '\n' # Create VPC
    printf '\n' # EKS version
    printf '\n' # Node instance type
    printf '\n' # Node min
    printf '\n' # Node max
    printf '\n' # Backends
    printf '\n' # ClickHouse
    printf '\n' # Gateway
    printf '\n' # TLS
    printf '\n' # ACM ARN
    printf '\n' # Domain
    printf '\n' # Route 53 choice
    printf '\n' # Existing zone ID
    printf '\n' # Sizing
    printf '\n' # Deployments
    printf '\n' # Insights
    printf '\n' # SmithDB
    printf '\n' # Sandboxes
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
log_has "invalid zone ID is rejected" "$TMP/reuse.log" \
  "ERROR: enter a valid Route 53 hosted zone ID starting with Z."
log_has "summary shows reused zone" "$TMP/reuse.log" \
  "existing (Z1ABCDEF123456)"

echo "2. Update mode preserves the zone choice and ID as defaults"
write_update_defaults "$TMP/update.answers"
run_wizard "existing-zone update run completes" "$REUSE_INFRA" \
  "$TMP/update.answers" "$TMP/update.log"
has_line "reuse choice survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  "dns_create_zone        = false"
has_line "existing zone ID survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  "dns_existing_zone_id   = \"Z1ABCDEF123456\""

echo "3. Creating a new zone writes the choice without an existing ID"
NEW_INFRA="$TMP/new"
write_fresh_answers "$TMP/new.answers" "" "new.example.com" "1"
run_wizard "fresh new-zone run completes" "$NEW_INFRA" \
  "$TMP/new.answers" "$TMP/new.log"
has_line "new-zone choice is written" "$NEW_INFRA/terraform.tfvars" \
  "dns_create_zone        = true"
lacks_key "new-zone mode omits an existing ID" "$NEW_INFRA/terraform.tfvars" \
  "dns_existing_zone_id"
log_has "summary shows newly created zone" "$TMP/new.log" "new (new.example.com)"

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

echo ""
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
