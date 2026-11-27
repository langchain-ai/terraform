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
  local invalid_zone_id="${5:-}" zone_id="${6:-}" invalid_bounds="${7:-false}"
  local smithdb_answer="${8:-}"
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
    printf '\n'                    # RDS instance type
    printf '\n'                    # RDS initial storage
    printf '\n'                    # RDS max storage
    printf '\n'                    # ElastiCache instance type
    printf '\n'                    # ClickHouse: in-cluster
    printf '%s\n' "$smithdb_answer" # Enable SmithDB (blank accepts the default: yes)
    printf '%s\n' "3"             # Gateway: ALB
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
    if [[ "$smithdb_answer" == "n" ]]; then
      :                            # SmithDB declined: no capacity questions
    elif [[ "$invalid_bounds" == "true" ]]; then
      printf '%s\n' 0 2 2 7 0 400
      # Invalid minimum, maximum, and boot disk size must each be re-asked.
    else
      printf '\n\n\n'              # SmithDB min, max, disk defaults
    fi
    printf '\n'                    # Deployments: no
    printf '\n'                    # Fleet: no
    printf '\n'                    # LangSmith Chat: no
    printf '\n'                    # Insights: no
    printf '\n'                    # Sandboxes: no
    printf '\n'                    # Write configuration: yes
  } > "$file"
}

# Every answer is accepted from terraform.tfvars in update mode. Keeping this
# list explicit makes a newly inserted prompt fail the test instead of silently
# shifting later answers onto the wrong questions.
write_update_defaults() {
  local file="$1" smithdb="${2:-true}" enable_answer="${3:-}" confirm_answer="${4:-}"
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
    printf '\n' # RDS instance type
    printf '\n' # RDS initial storage
    printf '\n' # RDS max storage
    printf '\n' # ElastiCache instance type
    printf '\n' # ClickHouse
    printf '%s\n' "$enable_answer" # Enable SmithDB
    [[ -z "$confirm_answer" ]] || printf '%s\n' "$confirm_answer" # Confirm disabling SmithDB
    printf '\n' # Gateway
    printf '\n' # TLS
    printf '\n' # Certificate management
    printf '\n' # Route 53 choice
    printf '\n' # Existing zone ID
    if [[ "$smithdb" == "true" ]]; then
      printf '\n\n\n' # SmithDB min, max, disk
    fi
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

echo "2. Update mode preserves DNS, SSO, and disabled SmithDB settings"
# Preserve explicit settings changed outside QuickStart.
sed -e 's/^enable_sso_oidc[[:space:]]*=.*/enable_sso_oidc = true/' \
  -e 's/^enable_smithdb[[:space:]]*=.*/enable_smithdb = false/' \
  -e 's/^smithdb_ingestion_enabled[[:space:]]*=.*/smithdb_ingestion_enabled = false/' \
  "$REUSE_INFRA/terraform.tfvars" > "$TMP/sso.tfvars"
mv "$TMP/sso.tfvars" "$REUSE_INFRA/terraform.tfvars"
write_update_defaults "$TMP/update.answers" false
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
has_line "disabled SmithDB survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  'enable_smithdb                        = false'
has_line "disabled ingestion survives rerun" "$REUSE_INFRA/terraform.tfvars" \
  'smithdb_ingestion_enabled             = false'
sed '/^enable_smithdb[[:space:]]*=/d; /^smithdb_ingestion_enabled[[:space:]]*=/d' \
  "$REUSE_INFRA/terraform.tfvars" > "$TMP/legacy.tfvars"
mv "$TMP/legacy.tfvars" "$REUSE_INFRA/terraform.tfvars"
run_wizard "legacy update with omitted SmithDB flags completes" "$REUSE_INFRA" \
  "$TMP/update.answers" "$TMP/legacy-update.log"
has_line "omitted SmithDB flag stays disabled on update" "$REUSE_INFRA/terraform.tfvars" \
  'enable_smithdb                        = false'
has_line "omitted ingestion flag stays disabled on update" "$REUSE_INFRA/terraform.tfvars" \
  'smithdb_ingestion_enabled             = false'

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

echo "6. SmithDB capacity is independent and survives update mode"
SMITHDB_INFRA="$TMP/smithdb"
write_fresh_answers "$TMP/smithdb.answers" "" "langsmith.example.com" 2 "" Z1ABCDEF123456 true
run_wizard "SmithDB setup completes after invalid bounds" "$SMITHDB_INFRA" "$TMP/smithdb.answers" "$TMP/smithdb.log"
has_line "SmithDB minimum written" "$SMITHDB_INFRA/terraform.tfvars" "smithdb_node_min_count                = 2"
has_line "SmithDB maximum written" "$SMITHDB_INFRA/terraform.tfvars" "smithdb_node_max_count                = 7"
has_line "SmithDB cache defaults to network-disk" "$SMITHDB_INFRA/terraform.tfvars" 'smithdb_cache_storage                 = "network-disk"'
if awk '$1 == "smithdb_node_root_volume_size_gb" { found = ($3 == 400) } END { exit !found }' "$SMITHDB_INFRA/terraform.tfvars"; then
  ok "SmithDB boot disk written"
else
  bad "SmithDB boot disk written"
fi
sed -e 's/^smithdb_transition_mode[[:space:]]*=.*/smithdb_transition_mode = true/' \
  -e 's/^smithdb_node_instance_type[[:space:]]*=.*/smithdb_node_instance_type = "m6i.4xlarge"/' \
  -e 's/^smithdb_cache_storage[[:space:]]*=.*/smithdb_cache_storage = "local-ssd"/' \
  -e 's/^smithdb_ingestion_enabled[[:space:]]*=.*/smithdb_ingestion_enabled = false/' \
  "$SMITHDB_INFRA/terraform.tfvars" > "$TMP/transition.tfvars"
mv "$TMP/transition.tfvars" "$SMITHDB_INFRA/terraform.tfvars"
write_update_defaults "$TMP/smithdb-update.answers" true
run_wizard "SmithDB update accepts current settings" "$SMITHDB_INFRA" "$TMP/smithdb-update.answers" "$TMP/smithdb-update.log"
has_line "SmithDB minimum preserved" "$SMITHDB_INFRA/terraform.tfvars" "smithdb_node_min_count                = 2"
has_line "SmithDB maximum preserved" "$SMITHDB_INFRA/terraform.tfvars" "smithdb_node_max_count                = 7"
has_line "SmithDB transition mode survives QuickStart" "$SMITHDB_INFRA/terraform.tfvars" "smithdb_transition_mode               = true"
has_line "SmithDB instance override survives QuickStart" "$SMITHDB_INFRA/terraform.tfvars" 'smithdb_node_instance_type            = "m6i.4xlarge"'
has_line "SmithDB local-ssd cache survives QuickStart" "$SMITHDB_INFRA/terraform.tfvars" 'smithdb_cache_storage                 = "local-ssd"'
has_line "disabled ingestion survives with SmithDB enabled" "$SMITHDB_INFRA/terraform.tfvars" 'smithdb_ingestion_enabled             = false'
# A tfvars written when null meant "follow sizing_profile" has to come out with the plain defaults.
sed -e 's/^smithdb_node_instance_type[[:space:]]*=.*/smithdb_node_instance_type = null/' \
  -e 's/^smithdb_node_max_count[[:space:]]*=.*/smithdb_node_max_count = null/' \
  "$SMITHDB_INFRA/terraform.tfvars" > "$TMP/legacy.tfvars"
mv "$TMP/legacy.tfvars" "$SMITHDB_INFRA/terraform.tfvars"
write_update_defaults "$TMP/smithdb-legacy.answers" true
run_wizard "SmithDB update replaces legacy null settings" "$SMITHDB_INFRA" "$TMP/smithdb-legacy.answers" "$TMP/smithdb-legacy.log"
has_line "legacy null instance type becomes m6a.4xlarge" "$SMITHDB_INFRA/terraform.tfvars" 'smithdb_node_instance_type            = "m6a.4xlarge"'
has_line "legacy null maximum becomes 5" "$SMITHDB_INFRA/terraform.tfvars" "smithdb_node_max_count                = 5"

echo "7. A new setup gets the SmithDB defaults and no sizing profile"
DEFAULT_INFRA="$TMP/smithdb-defaults"
write_fresh_answers "$TMP/defaults.answers" "" "langsmith.example.com" 2 "" Z1ABCDEF123456 false
run_wizard "SmithDB defaults complete" "$DEFAULT_INFRA" "$TMP/defaults.answers" "$TMP/defaults.log"
has_line "LangSmith type is independent of SmithDB" "$DEFAULT_INFRA/terraform.tfvars" '    instance_types = ["m6a.2xlarge"]'
has_line "Dev / POC lets the LangSmith nodes reach the sizing's maximum" "$DEFAULT_INFRA/terraform.tfvars" '    max_size       = 10'
has_line "SmithDB type is m6a.4xlarge" "$DEFAULT_INFRA/terraform.tfvars" 'smithdb_node_instance_type            = "m6a.4xlarge"'
has_line "SmithDB initial capacity" "$DEFAULT_INFRA/terraform.tfvars" 'smithdb_node_min_count                = 2'
has_line "SmithDB ceiling is 5" "$DEFAULT_INFRA/terraform.tfvars" "smithdb_node_max_count                = 5"
log_lacks "no claim that QuickStart picks the SmithDB node type" "$TMP/defaults.log" "selects the instance type automatically"
log_lacks "no warning about the SmithDB node type" "$TMP/defaults.log" "gives SmithDB a tier that needs"
log_has "QuickStart points to the SmithDB scale-up steps" "$TMP/defaults.log" "describes scaling up to the medium or large tier"
has_line "SmithDB enabled by default" "$DEFAULT_INFRA/terraform.tfvars" 'enable_smithdb                        = true'
has_line "ingestion enabled by default" "$DEFAULT_INFRA/terraform.tfvars" 'smithdb_ingestion_enabled             = true'
has_line "migration remains disabled" "$DEFAULT_INFRA/terraform.tfvars" 'smithdb_migration_enabled             = false'
has_line "a new setup serves reads from SmithDB" "$DEFAULT_INFRA/terraform.tfvars" 'smithdb_query_enabled                 = true'
lacks_key "a new setup writes no sizing_profile" "$DEFAULT_INFRA/terraform.tfvars" sizing_profile
log_has "QuickStart names the one sizing" "$TMP/defaults.log" "LangSmith runs one sizing"
# A 0.17 tfvars carries sizing_profile; update mode drops it and says so.
printf 'sizing_profile = "production"\n' >> "$DEFAULT_INFRA/terraform.tfvars"
write_update_defaults "$TMP/sizing-update.answers" true
run_wizard "update mode completes with a 0.17 sizing_profile" "$DEFAULT_INFRA" "$TMP/sizing-update.answers" "$TMP/sizing-update.log"
lacks_key "update mode drops sizing_profile" "$DEFAULT_INFRA/terraform.tfvars" sizing_profile
log_has "update mode says sizing_profile was removed" "$TMP/sizing-update.log" "sizing_profile was removed in 0.18"

echo "8. SmithDB can be turned on and off in the wizard"
OPTOUT_INFRA="$TMP/smithdb-optout"
write_fresh_answers "$TMP/optout.answers" "" "langsmith.example.com" 2 "" Z1ABCDEF123456 false n
run_wizard "a new setup can decline SmithDB" "$OPTOUT_INFRA" "$TMP/optout.answers" "$TMP/optout.log"
has_line "SmithDB is off when declined" "$OPTOUT_INFRA/terraform.tfvars" 'enable_smithdb                        = false'
write_update_defaults "$TMP/enable.answers" true y
run_wizard "update mode can turn SmithDB on" "$OPTOUT_INFRA" "$TMP/enable.answers" "$TMP/enable.log"
has_line "SmithDB is on after the update" "$OPTOUT_INFRA/terraform.tfvars" 'enable_smithdb                        = true'
write_update_defaults "$TMP/disable.answers" false n y
run_wizard "update mode can turn SmithDB off after a warning" "$OPTOUT_INFRA" "$TMP/disable.answers" "$TMP/disable.log"
has_line "SmithDB is off after the update" "$OPTOUT_INFRA/terraform.tfvars" 'enable_smithdb                        = false'
log_has "turning SmithDB off warns about its data" "$TMP/disable.log" "disabling SmithDB may remove its metastore"

echo "9. Fleet, Chat and Insights storage is no longer asked, and 0.17 settings stop the wizard"
for key in fleet_storage polly_storage insights_storage enable_standalone_polly enable_standalone_insights; do
  lacks_key "a new install does not write $key" "$SMITHDB_INFRA/terraform.tfvars" "$key"
done
STOP_INFRA="$TMP/addon-stop"
for case in 'polly_storage = "in-cluster"' 'enable_standalone_insights = true'; do
  mkdir -p "$STOP_INFRA"
  # Chat is on, so its in-cluster data would be stranded.
  { sed 's/^enable_polly[[:space:]]*=.*/enable_polly = true/' "$SMITHDB_INFRA/terraform.tfvars"; printf '%s\n' "$case"; } > "$STOP_INFRA/terraform.tfvars"
  write_update_defaults "$TMP/addon-stop.answers" true
  if INFRA_DIR="$STOP_INFRA" bash "$SRC" < "$TMP/addon-stop.answers" > "$TMP/addon-stop.log" 2>&1; then
    bad "update mode stops on $case (the wizard finished)"
  else
    log_has "update mode stops on $case" "$TMP/addon-stop.log" "${case%% *} "
  fi
  grep -Fqx "$case" "$STOP_INFRA/terraform.tfvars" \
    && ok "the stop on $case leaves terraform.tfvars as it was" \
    || bad "the stop on $case rewrote terraform.tfvars"
done
# The 0.17 QuickStart wrote polly_storage = "in-cluster" with Chat off too.
STALE_INFRA="$TMP/addon-stale"
mkdir -p "$STALE_INFRA"
{ cat "$SMITHDB_INFRA/terraform.tfvars"; printf 'polly_storage = "in-cluster"\n'; } > "$STALE_INFRA/terraform.tfvars"
write_update_defaults "$TMP/addon-stale.answers" true
run_wizard "update mode accepts in-cluster storage for an add-on that is off" "$STALE_INFRA" "$TMP/addon-stale.answers" "$TMP/addon-stale.log"
lacks_key "update mode drops the stale polly_storage" "$STALE_INFRA/terraform.tfvars" "polly_storage"
KEEP_INFRA="$TMP/addon-keep"
mkdir -p "$KEEP_INFRA"
{ cat "$SMITHDB_INFRA/terraform.tfvars"; printf 'polly_storage = "external"\n'; } > "$KEEP_INFRA/terraform.tfvars"
write_update_defaults "$TMP/addon-keep.answers" true
run_wizard "update mode accepts polly_storage = external" "$KEEP_INFRA" "$TMP/addon-keep.answers" "$TMP/addon-keep.log"
if awk '$1 == "polly_storage" { found = ($3 == "\"external\"") } END { exit !found }' "$KEEP_INFRA/terraform.tfvars"; then
  ok "update mode keeps the confirmation that deploy.sh reads"
else
  bad "update mode keeps the confirmation that deploy.sh reads"
fi

echo ""
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
