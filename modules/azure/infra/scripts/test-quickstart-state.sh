#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-quickstart-state.sh — Unit tests for the quickstart wizard's resume layer.
#
# Covers the checkpoint round-trip (_save_state / _load_state), the whitelist
# that guards it, and seeding the wizard from an existing terraform.tfvars
# (_load_tfvars). Runs entirely in a temp directory — no Azure, no terraform,
# no prompts, and your own terraform.tfvars is never read or written.
#
# Usage:
#   ./infra/scripts/test-quickstart-state.sh
#
# Also available as: make test-quickstart
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/quickstart.sh"

# The wizard variable and tfvars key holding the deployment name. These are the
# only two lines to change when the name_prefix rename lands.
NAME_VAR="IDENTIFIER"
NAME_TFKEY="identifier"

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
eval "$NAME_VAR=-acme-eu"
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
eq "$NAME_VAR survives"        "${!NAME_VAR}"   "-acme-eu"
eq "LOCATION survives"         "$LOCATION"      "centralus"
eq "OWNER keeps its space"     "$OWNER"         "platform team"
eq "COST_CENTER keeps space"   "$COST_CENTER"   "CC-9 / dept 4"
eq "PG_ADMIN_USER survives"    "$PG_ADMIN_USER" "ls_admin"
eq "CREATE_WAF survives"       "$CREATE_WAF"    "true"

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
$NAME_TFKEY = "-acme"
location        = "westus2"
owner           = "platform team"
create_waf      = true
EOF
PROFILE="dev"; LOCATION=""; OWNER=""; CREATE_WAF="false"; eval "$NAME_VAR="
_load_tfvars
eq "$NAME_TFKEY read into $NAME_VAR" "${!NAME_VAR}" "-acme"
eq "PROFILE read from the header"    "$PROFILE"     "prod"
eq "LOCATION read"                   "$LOCATION"    "westus2"
eq "OWNER keeps its space"           "$OWNER"       "platform team"
eq "CREATE_WAF read"                 "$CREATE_WAF"  "true"

echo "6. tfvars to checkpoint and back keeps the deployment name"
_save_state
eval "$NAME_VAR="; PROFILE=""
_load_state
eq "name survives the full trip"    "${!NAME_VAR}" "-acme"
eq "profile survives the full trip" "$PROFILE"     "prod"

echo ""
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
