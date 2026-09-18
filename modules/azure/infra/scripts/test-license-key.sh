#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-license-key.sh — Unit tests for _validate_license_key in _common.sh.
#
# The prompt in setup-env.sh and the Key Vault read in create-k8s-secrets.sh
# both call it, so this is the one place the accepted shapes are pinned down:
# an online key (lcl_ plus the key body) or an offline key (a three-part token
# whose first part is a base64url JSON header). No Azure, no prompts.
#
# Usage:
#   ./infra/scripts/test-license-key.sh
#
# Also available as: make test-license-key
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# accepts <name> <value>: the validator returns 0 and prints nothing.
accepts() {
  local out
  if out=$(_validate_license_key "$2" 2>&1) && [[ -z "$out" ]]; then ok "$1"; else bad "$1 (rejected: '$out')"; fi
}
# rejects <name> <value> <fragment>: the validator returns 1 and its message carries the fragment.
rejects() {
  local out
  if out=$(_validate_license_key "$2" 2>&1); then
    bad "$1 (accepted)"
  elif [[ "$out" == *"$3"* ]]; then
    ok "$1"
  else
    bad "$1 (message '$out' lacks '$3')"
  fi
}

# Fixtures are built here rather than pasted, so each one says what it encodes.
b64url() { printf '%s' "$1" | base64 | tr -d '
=' | tr '+/' '-_'; }
JWT="$(b64url '{"alg":"RS256","typ":"JWT"}').$(b64url '{"sub":"test"}').c2lnbmF0dXJl"
JWT_SHORT_HEADER="$(b64url '{"alg":"HS256"}').$(b64url '{"sub":"test"}').c2ln"   # 20-char header: decodes with no padding
JWT_BAD_HEADER="$(b64url 'hello').$(b64url '{"sub":"test"}').c2ln"               # valid base64, not JSON
LCL='lcl_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG'

echo "1. accepted shapes"
accepts "online key, lcl_ plus a 43-character body"          "$LCL"
accepts "online key with - and _ in the body"                 "lcl_abc-DEF_ghi-JKL_mno-PQR"
accepts "offline key, three parts, RS256 header"              "$JWT"
accepts "offline key whose header decodes without padding"    "$JWT_SHORT_HEADER"

echo "2. the paste that caused #250"
rejects "https share link"        "https://share.1password.com/s#AbCdEf.GhIjKl.MnOpQr" "URL"
rejects "http URL with no dots"   "http://example/key"                                   "URL"
rejects "URL message says to paste the key, not the link" "https://share.1password.com/s#x.y.z" "not the link"

echo "3. other rejections"
rejects "empty"                              ""                         "empty"
rejects "whitespace inside"                  "lcl_abc def ghi jkl mno"  "whitespace"
rejects "lcl_ with a body too short to be a key" "lcl_abc"              "short"
rejects "three parts, header is not JSON"    "$JWT_BAD_HEADER"          "header"
rejects "three parts, header is not base64"  "!!!.${JWT#*.}"           "header"
rejects "three parts, header is a truncated {"  "ew.${JWT#*.}"            "header"
rejects "three parts, header is an empty object"  "$(b64url '{}').${JWT#*.}"  "header"
rejects "three parts, header has no alg member"  "$(b64url '{"typ":"JWT"}').${JWT#*.}" "header"
rejects "four parts"                         "$JWT.extra"               "three"
rejects "two parts"                          "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0" "lcl_"
rejects "plain word"                         "mylicensekey"             "lcl_"

echo "4. message shape"
rejects "message opens with 'License key'"   "mylicensekey"             "License key "

echo ""
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
