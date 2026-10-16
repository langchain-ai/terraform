#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-quickstart-state.sh — Unit tests for the quickstart wizard's resume layer, --yes, and quick setup.
#
# Covers the checkpoint round-trip (_save_state / _load_state), the whitelist
# that guards it, and seeding the wizard from an existing terraform.tfvars
# (_load_tfvars), the files --yes writes or refuses, and quick setup driven from
# scripted answers. Runs entirely in a temp directory — no Azure, no terraform,
# and your own terraform.tfvars is never read or written.
#
# Usage:
#   ./infra/scripts/test-quickstart-state.sh
#
# Also available as: make test-quickstart
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/quickstart.sh"

# The wizard variable and tfvars key holding the deployment name. The rename has
# landed, so the sample values below also dropped their leading hyphen: name_prefix
# carries no hyphen of its own, and _load_tfvars strips a pasted one for back-compat.
NAME_VAR="NAME_PREFIX"
NAME_TFKEY="name_prefix"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
# stat(1) is BSD on macOS and GNU on Linux.
perm() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# Carve out the resume-state block (STATE_FILE= through the end of _load_tfvars)
# so the functions can be driven directly, without the wizard's prompt loop.
START=$(grep -n '^STATE_FILE=' "$SRC" | cut -d: -f1)
END=$(awk -v s="$START" 'NR>s && /^# Any exit that still leaves/ {print NR-1; exit}' "$SRC")
if [[ -z "$START" || -z "$END" ]]; then
  echo "  FAIL  could not locate the state block in quickstart.sh"
  exit 1
fi
sed -n "${START},${END}p" "$SRC" > block.sh

INFRA_DIR="$TMP"
OUTPUT="$INFRA_DIR/terraform.tfvars"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"
# shellcheck source=/dev/null
source ./block.sh

echo "1. _save_state / _load_state round-trip"
SECTION=4
ANSWERED="1 2 3"
PROFILE="prod"
eval "$NAME_VAR=acme-eu"
LOCATION="centralus"
OWNER="platform team"          # inner space
COST_CENTER="CC-9 / dept 4"    # space and slash
PG_ADMIN_USER="ls_admin"
CREATE_WAF="true"
_save_state
eq "checkpoint is 0600"        "$(perm "$STATE_FILE")" "600"

SECTION=""; ANSWERED=""; PROFILE=""; LOCATION=""; OWNER=""; COST_CENTER=""
PG_ADMIN_USER=""; CREATE_WAF=""; eval "$NAME_VAR="
_load_state
eq "SECTION survives"          "$SECTION"       "4"
eq "ANSWERED survives"         "$ANSWERED"      "1 2 3"
eq "PROFILE survives"          "$PROFILE"       "prod"
eq "$NAME_VAR survives"        "${!NAME_VAR}"   "acme-eu"
eq "LOCATION survives"         "$LOCATION"      "centralus"
eq "OWNER keeps its space"     "$OWNER"         "platform team"
eq "COST_CENTER keeps space"   "$COST_CENTER"   "CC-9 / dept 4"
eq "PG_ADMIN_USER survives"    "$PG_ADMIN_USER" "ls_admin"
eq "CREATE_WAF survives"       "$CREATE_WAF"    "true"

# A checkpoint written before the network mode was a choice has no NETWORK_MODE
# line; that deployment runs node-subnet, and the resumed session must not carry
# the top-level default of overlay into its tfvars.
printf 'SECTION=4\nANSWERED=1 2 3\n' > "$STATE_FILE"
NETWORK_MODE="overlay"
_load_state
eq "old checkpoint seeds node-subnet"  "$NETWORK_MODE" "node-subnet"
printf 'SECTION=4\nNETWORK_MODE=overlay\n' > "$STATE_FILE"
_load_state
eq "checkpoint with a mode keeps it"   "$NETWORK_MODE" "overlay"

echo "2. _STATE_KEYS covers every variable _load_tfvars assigns"
# _load_state drops a key that is missing from the whitelist without saying so,
# and _save_state never writes it, so a rename that lands in one place and not
# the other loses that answer on resume. PROFILE comes from the header comment
# rather than a case arm, so seed it; the rest are scraped from the function.
{ echo PROFILE
  sed -n "/^_load_tfvars() {/,/^}/p" "$SRC" \
    | grep -oE '\b[A-Z][A-Z0-9_]+=[^ ]*(_TF_VAL|_tfvar)' \
    | sed 's/=.*//'
} | sort -u > assigned.txt
COUNT=$(wc -l < assigned.txt | tr -d ' ')
[[ "$COUNT" -ge 25 ]] && ok "scraped $COUNT assigned variables" \
  || bad "scraped only $COUNT variables — the scrape pattern has drifted"
# _STATE_KEYS wraps across lines, so flatten it before matching on " $v ".
KEYS=""
for k in $_STATE_KEYS; do KEYS="$KEYS $k"; done
MISSING=""
while read -r v; do
  case "$KEYS " in
    *" $v "*) ;;
    *) MISSING="$MISSING $v" ;;
  esac
done < assigned.txt
[[ -z "$MISSING" ]] && ok "every assigned variable is whitelisted" \
  || bad "assigned by _load_tfvars but missing from _STATE_KEYS:$MISSING"

echo "2b. _WRITER_KEYS covers every key the writer emits"
# The preserve loop copies any key outside _WRITER_KEYS from the previous file
# into the "Kept from your previous terraform.tfvars" block, so a key the writer
# emits but does not own lands twice on a re-edit and no plan can parse the
# result. Scrape the writer's heredoc and echo lines from _WRITER_KEYS onward.
WRITER_START=$(grep -n '^_WRITER_KEYS=' "$SRC" | cut -d: -f1)
sed -n "${WRITER_START},\$p" "$SRC" \
  | grep -oE '^[a-z_][a-z0-9_]* += |echo "[a-z_][a-z0-9_]* += ' \
  | sed -E 's/^echo "//; s/ *= *$//' | sort -u > emitted.txt
ECOUNT=$(wc -l < emitted.txt | tr -d ' ')
[[ "$ECOUNT" -ge 40 ]] && ok "scraped $ECOUNT emitted keys" \
  || bad "scraped only $ECOUNT emitted keys — the scrape pattern has drifted"
WKEYS=" $(sed -n '/^_WRITER_KEYS="/,/"$/p' "$SRC" | tr -d '"' | sed 's/_WRITER_KEYS=//' | tr '\n' ' ') "
WMISSING=""
while read -r k; do [[ "$WKEYS" == *" $k "* ]] || WMISSING="$WMISSING $k"; done < emitted.txt
[[ -z "$WMISSING" ]] && ok "every emitted key is in _WRITER_KEYS" \
  || bad "emitted by the writer but missing from _WRITER_KEYS:$WMISSING"

echo "3. A key outside the whitelist is ignored"
NOT_A_KEY="untouched"
printf 'NOT_A_KEY=clobbered\nPROFILE=dev\n' > "$STATE_FILE"
_load_state
eq "off-whitelist key dropped"  "$NOT_A_KEY" "untouched"
eq "whitelisted key still read" "$PROFILE"   "dev"

echo "4. Checkpoint values stay literal through the eval"
rm -f ran-cmdsub ran-backtick
{ printf 'OWNER=$(touch ran-cmdsub)\n'
  printf 'COST_CENTER=`touch ran-backtick`\n'
  printf 'LOCATION=* ; rm -rf /\n'
  printf 'PG_DB_NAME=${IFS}${HOME}\n'
} > "$STATE_FILE"
OWNER=""; COST_CENTER=""; LOCATION=""; PG_DB_NAME=""
_load_state
eq "command substitution literal" "$OWNER"       '$(touch ran-cmdsub)'
eq "backticks literal"            "$COST_CENTER" '`touch ran-backtick`'
eq "glob and metachars literal"   "$LOCATION"    '* ; rm -rf /'
eq "parameter expansion literal"  "$PG_DB_NAME"  '${IFS}${HOME}'
[[ ! -e ran-cmdsub ]]   && ok "no command ran from \$( )"    || bad "COMMAND EXECUTED from \$( )"
[[ ! -e ran-backtick ]] && ok "no command ran from backticks" || bad "COMMAND EXECUTED from backticks"

echo "5. _load_tfvars seeds the wizard from an existing terraform.tfvars"
cat > "$OUTPUT" << EOF
# Profile: prod
subscription_id = "sub-1"
$NAME_TFKEY = "acme"
location        = "westus2"
owner           = "platform team"
create_waf      = true
langsmith_domain = "langsmith.acme.com"
create_dns_zone = true
EOF
PROFILE="dev"; LOCATION=""; OWNER=""; CREATE_WAF="false"; NETWORK_MODE="overlay"; CREATE_DNS_ZONE="false"; eval "$NAME_VAR="
_load_tfvars
eq "$NAME_TFKEY read into $NAME_VAR" "${!NAME_VAR}" "acme"
eq "PROFILE read from the header"    "$PROFILE"     "prod"
eq "LOCATION read"                   "$LOCATION"    "westus2"
eq "OWNER keeps its space"           "$OWNER"       "platform team"
eq "CREATE_WAF read"                 "$CREATE_WAF"  "true"
# Section 6 defaults its zone prompt to this value on a re-edit.
eq "CREATE_DNS_ZONE read"            "$CREATE_DNS_ZONE" "true"
# A tfvars from before the mode was a choice deploys the module default of
# that time; seeding overlay would write a migration into it on save.
eq "absent aks_network_mode is node-subnet" "$NETWORK_MODE" "node-subnet"
printf 'aks_network_mode = "overlay"\n' >> "$OUTPUT"
_load_tfvars
eq "present aks_network_mode is read"      "$NETWORK_MODE" "overlay"

echo "6. tfvars to checkpoint and back keeps the deployment name"
_save_state
eval "$NAME_VAR="; PROFILE=""
_load_state
eq "name survives the full trip"    "${!NAME_VAR}" "acme"
eq "profile survives the full trip" "$PROFILE"     "prod"

echo "7. A trailing comment on a bare value is not part of the value"
# terraform.tfvars.example ships annotated keys, so a copied file reaches here
# with them. An unstripped comment makes every boolean read as neither true nor
# false, and _derive_kv_name then names a vault that does not exist.
cat > "$OUTPUT" << EOF
subscription_id       = "sub-1"
$NAME_TFKEY           = "acme"
create_waf            = false  # the dev subscription has no WAF quota
blob_ttl_short_days   = 21     # short-lived trace payloads
create_keyvault       = false  # attach to the platform vault
existing_keyvault_name = "corp-shared-kv"
unique_resource_names = true
EOF
CREATE_WAF="true"; BLOB_TTL_SHORT_DAYS=""
_load_tfvars
eq "annotated boolean loses its comment" "$CREATE_WAF"          "false"
eq "annotated integer loses its comment" "$BLOB_TTL_SHORT_DAYS" "21"
eq "attach mode survives the comment"    "$(_derive_kv_name)"   "corp-shared-kv"

echo "8. The cloud is asked in section 2, never locked in by an earlier value"
# A tfvars written on the commercial cloud and reused after the CLI moved to
# Government must be changeable in the wizard, not only by hand. Carve the cloud
# functions and drive them with the stub az and a scripted answer.
for f in _azure_environment _ask_choice _index_of _hint _cli_azure_environment \
         _warn_cloud_mismatch _resolve_azure_environment _ask_azure_environment \
         _gov_redis_in_cluster; do
  awk -v f="$f" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^}/ {p=0}' "$SRC"
done > cloud.sh
# shellcheck source=/dev/null
source ./cloud.sh
mkdir -p fix bin
cp "$SCRIPT_DIR/test-support/az" bin/az
export FIXTURE_DIR="$TMP/fix"
PATH="$TMP/bin:$PATH"
printf 'AzureUSGovernment' > fix/cloud_name
unset TF_VAR_azure_environment

AZURE_ENVIRONMENT="public"; REDIS_SOURCE="external"
_resolve_azure_environment > out.txt 2>&1
eq "a set value is kept at startup"      "$AZURE_ENVIRONMENT" "public"
grep -q "change the Azure cloud in section 2" out.txt \
  && ok "the mismatch warning offers section 2" || bad "the mismatch warning does not offer section 2"
_ask_azure_environment > out.txt 2>&1 <<< "2"
eq "picking Government overrides tfvars" "$AZURE_ENVIRONMENT" "usgovernment"
eq "Government moves Redis in-cluster"   "$REDIS_SOURCE"      "in-cluster"
grep -q "WARNING" out.txt && bad "warned after the cloud matched the CLI" || ok "no warning once the cloud matches the CLI"
_ask_azure_environment > out.txt 2>&1 <<< ""
eq "Enter keeps the current cloud"       "$AZURE_ENVIRONMENT" "usgovernment"

AZURE_ENVIRONMENT=""
TF_VAR_azure_environment="public" _resolve_azure_environment > out.txt 2>&1
eq "TF_VAR_ outranks the CLI when unset" "$AZURE_ENVIRONMENT" "public"
AZURE_ENVIRONMENT=""
_resolve_azure_environment > out.txt 2>&1
eq "the CLI fills an unset cloud"        "$AZURE_ENVIRONMENT" "usgovernment"

echo "9. --yes writes a new deployment with no prompts"
# The whole script, against a scratch INFRA_DIR and the stub az. stdin is
# /dev/null, so a prompt that slipped into this path fails the run instead of
# hanging it.
printf 'AzureCloud' > fix/cloud_name
NI="$TMP/ni"
qs() { rm -rf "$NI"; mkdir -p "$NI"; INFRA_DIR="$NI" "$SRC" "$@" < /dev/null > qs.out 2>&1; }
has() { grep -qE "^$2[[:space:]]*=[[:space:]]*$3\$" "$NI/terraform.tfvars" && ok "$1" || bad "$1 (no $2 = $3)"; }

qs --yes
eq "dev run exits 0"                  "$?" "0"
has "dev subscription from az"        subscription_id   '"11111111-1111-1111-1111-111111111111"'
has "dev name is the profile"         name_prefix       '"dev"'
has "dev serves HTTP"                 tls_certificate_source '"none"'
has "dev DNS label from the name"     dns_label         '"langsmith-dev"'
has "dev Postgres in-cluster"         postgres_source   '"in-cluster"'
has "dev sizing"                      sizing_profile    '"dev"'
[[ ! -e "$NI/.quickstart-state" ]] && ok "no checkpoint left behind" || bad "checkpoint left behind"

qs --yes --profile prod --location westus2 --domain langsmith.example.com --email ops@example.com
eq "prod run exits 0"                 "$?" "0"
grep -q '^# Profile: prod' "$NI/terraform.tfvars" && ok "prod stamped in the header" || bad "prod not stamped in the header"
has "prod name is the profile"        name_prefix       '"prod"'
has "prod location"                   location          '"westus2"'
has "prod D8s_v5 nodes"               default_node_pool_vm_size '"Standard_D8s_v5"'
has "prod Postgres external"          postgres_source   '"external"'
has "prod Redis B3"                   amr_sku           '"Balanced_B3"'
has "prod Redis HA"                   redis_high_availability true
has "prod purge protection"           keyvault_purge_protection true
has "prod diagnostics"                create_diagnostics true
has "prod sizing"                     sizing_profile    '"production"'
has "domain switches TLS on"          tls_certificate_source '"letsencrypt"'
has "domain written"                  langsmith_domain  '"langsmith.example.com"'
has "domain gets a zone"              create_dns_zone   true
grep -q '^dns_label' "$NI/terraform.tfvars" && bad "dns_label written beside a domain" || ok "no dns_label beside a domain"

printf 'AzureUSGovernment' > fix/cloud_name
qs --yes --profile prod
has "Government keeps prod Redis in-cluster" redis_source '"in-cluster"'
has "Government cloud written"        azure_environment '"usgovernment"'
printf 'AzureCloud' > fix/cloud_name

qs --yes --name none
has "none means no suffix"            name_prefix       '""'
has "no-suffix DNS label"             dns_label         '"langsmith"'

rm -rf "$NI"; mkdir -p "$NI"; echo 'location = "keep"' > "$NI/terraform.tfvars"
INFRA_DIR="$NI" "$SRC" --yes < /dev/null > qs.out 2>&1
eq "existing tfvars refused"          "$?" "1"
eq "existing tfvars untouched"        "$(cat "$NI/terraform.tfvars")" 'location = "keep"'

rm -rf "$NI"; mkdir -p "$NI"; echo 'SECTION=3' > "$NI/.quickstart-state"
INFRA_DIR="$NI" "$SRC" --yes < /dev/null > qs.out 2>&1
eq "existing checkpoint refused"      "$?" "1"

# Each of these lands inside a quoted HCL string, so anything off the
# allow-list is refused before a file is written.
for bad_args in "--location east\$us" "--location \${x}" "--name Prod" "--name a--b" \
                "--profile staging" "--subscription not-a-guid" "--dns-label 1abc" \
                "--domain langsmith.example.com" "--email a@b.co" \
                "--dns-label ab --domain a.example.com --email a@b.co" \
                "--name abcdefghijklmnopq"; do
  # shellcheck disable=SC2086  # split the case into its flags on purpose
  qs --yes $bad_args
  rc=$?
  [[ "$rc" -ne 0 && ! -e "$NI/terraform.tfvars" ]] && ok "refused: $bad_args" \
    || bad "accepted: $bad_args (exit $rc)"
done

# A quote would close the HCL string early, and the loop above splits on spaces.
qs --yes --domain 'x"y.example.com' --email a@b.co
[[ "$?" -ne 0 && ! -e "$NI/terraform.tfvars" ]] && ok "refused: a quote in --domain" \
  || bad "accepted: a quote in --domain"

qs --profile prod
eq "a flag without --yes is refused"  "$?" "2"
qs --bogus
eq "an unknown flag is refused"       "$?" "2"

echo "10. Quick setup takes the profile's defaults from a few answers"
# Answers on stdin, one per line: quick y/n, profile, cloud, subscription, name,
# region, domain (then email when a domain is given), and the review choice.
quick() { rm -rf "$NI"; mkdir -p "$NI"; printf '%s\n' "$@" | INFRA_DIR="$NI" "$SRC" > qs.out 2>&1; }

quick "" 1 "" "" "" "" "" ""
eq "quick dev exits 0"                "$?" "0"
has "quick dev name is the profile"   name_prefix       '"dev"'
has "quick dev D4s_v5 nodes"          default_node_pool_vm_size '"Standard_D4s_v5"'
has "quick dev serves HTTP"           tls_certificate_source '"none"'
has "quick dev DNS label"             dns_label         '"langsmith-dev"'
has "quick dev Postgres in-cluster"   postgres_source   '"in-cluster"'
has "quick dev purgeable vault"       keyvault_purge_protection false
[[ ! -e "$NI/.quickstart-state" ]] && ok "quick leaves no checkpoint" || bad "quick left a checkpoint"

# A bad domain and a bad email are each asked again, not written.
quick "" 2 "" "" "" westus2 Bad_Domain langsmith.example.com notanemail ops@example.com ""
eq "quick prod exits 0"               "$?" "0"
eq "bad domain and email re-asked"    "$(grep -c 'ERROR' qs.out)" "2"
has "quick prod location"             location          '"westus2"'
has "quick prod D8s_v5 nodes"         default_node_pool_vm_size '"Standard_D8s_v5"'
has "quick prod Postgres external"    postgres_source   '"external"'
has "quick prod purge protection"     keyvault_purge_protection true
has "quick prod sizing"               sizing_profile    '"production"'
has "quick domain switches TLS on"    tls_certificate_source '"letsencrypt"'
has "quick email written"             letsencrypt_email '"ops@example.com"'

# Switching to dev at review moves every section quick setup did not ask.
quick "" 2 "" "" "" "" "" 1 1 ""
has "review switch keeps the name"    name_prefix       '"prod"'
has "review switch resizes nodes"     default_node_pool_vm_size '"Standard_D4s_v5"'
has "review switch moves Postgres"    postgres_source   '"in-cluster"'
has "review switch drops purge prot." keyvault_purge_protection false

# Declining quick setup opens the full wizard, which asks for the tags.
quick n 1 "" "" "" "" "" "" ""
grep -q 'Environment tag (blank' qs.out && ok "n opens the full section 2" || bad "n skipped the tag prompts"

echo ""
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
