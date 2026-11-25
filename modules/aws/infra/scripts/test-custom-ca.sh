#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-custom-ca.sh — Unit tests for the custom CA bundle support (the chart's
# config.customCa): the values block init-values.sh writes from
# langsmith_custom_ca_secret_name / langsmith_custom_ca_secret_key
# (_custom_ca_values_block in _common.sh), and the Secret check deploy.sh runs
# before Helm (_custom_ca_secret_check). No AWS, no terraform, no cluster: kubectl is
# a fake that answers from an environment variable.
#
# Usage:
#   ./infra/scripts/test-custom-ca.sh        (or: make test-custom-ca)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

PASS=0; FAIL=0
_check() { # _check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1"; PASS=$((PASS + 1))
  else
    echo "  FAIL $1"; FAIL=$((FAIL + 1))
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/       /'
  fi
}

echo "values block"
_check "no Secret set: nothing is written" "" "$(_custom_ca_values_block "" "ca.crt")"
_check "Secret set: customCa with the default key" \
  '
  customCa:
    secretName: "langsmith-ca"
    secretKey: "ca.crt"' \
  "$(_custom_ca_values_block "langsmith-ca" "ca.crt")"
_check "Secret set with another key" \
  '
  customCa:
    secretName: "corp-ca"
    secretKey: "bundle.pem"' \
  "$(_custom_ca_values_block "corp-ca" "bundle.pem")"
_check "key left out: ca.crt" \
  '
  customCa:
    secretName: "corp-ca"
    secretKey: "ca.crt"' \
  "$(_custom_ca_values_block "corp-ca")"

# The block goes on the line after config.deployment.url, with customCa at the same
# indent as the other config keys. Assemble the fragment the way init-values.sh does.
_fragment() {
  local _custom_ca_block="$1"
  cat <<FRAG
config:
  deployment:
    url: "https://langsmith.example.com"${_custom_ca_block}
  blobStorage:
    bucketName: "bucket"
FRAG
}
_check "off: the config block is unchanged" \
  'config:
  deployment:
    url: "https://langsmith.example.com"
  blobStorage:
    bucketName: "bucket"' \
  "$(_fragment "$(_custom_ca_values_block "" "ca.crt")")"
_check "on: customCa sits between deployment and blobStorage, at the config indent" \
  'config:
  deployment:
    url: "https://langsmith.example.com"
  customCa:
    secretName: "langsmith-ca"
    secretKey: "ca.crt"
  blobStorage:
    bucketName: "bucket"' \
  "$(_fragment "$(_custom_ca_values_block "langsmith-ca" "ca.crt")")"

_check "init-values.sh appends the block right after the deployment url" "1" \
  "$(grep -cE '^    url: "\$\{_protocol\}://\$\{HOSTNAME\}"\$\{_custom_ca_block\}$' "$SCRIPT_DIR/../../helm/scripts/init-values.sh")"
_check "deploy.sh runs the Secret check" "1" \
  "$(grep -c '_custom_ca_secret_check "\$NAMESPACE"' "$SCRIPT_DIR/../../helm/scripts/deploy.sh")"

echo "Secret check (deploy.sh preflight)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_KUBECTL_CALLS"
[[ -n "${FAKE_SECRET_KEYS:-}" ]] || exit 1
printf '%s ' $FAKE_SECRET_KEYS
FAKE
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH" FAKE_KUBECTL_CALLS="$TMP/calls"

_run() { # _run <keys the fake Secret holds> <secret> <key>; prints "<status>|<output>"
  : > "$FAKE_KUBECTL_CALLS"
  local out status
  out=$(FAKE_SECRET_KEYS="$1" _custom_ca_secret_check "langsmith" "$2" "$3" 2>&1); status=$?
  printf '%s|%s' "$status" "$out" | sed 's/\x1b\[[0-9;]*m//g'
}

r=$(_run "" "" "ca.crt")
_check "no Secret configured: passes without calling kubectl" "0|:0" "${r%%|*}|:$(wc -l < "$FAKE_KUBECTL_CALLS" | tr -d ' ')"
r=$(_run "ca.crt" "langsmith-ca" "ca.crt")
_check "Secret with the key: passes" "0" "${r%%|*}"
_check "Secret with the key: says what it found" "1" "$(printf '%s' "$r" | grep -c 'CA bundle langsmith-ca/ca.crt found in langsmith')"
_check "kubectl is asked for that Secret in that namespace" "get secret langsmith-ca -n langsmith -o go-template={{range \$k, \$v := .data}}{{\$k}} {{end}}" "$(head -1 "$FAKE_KUBECTL_CALLS")"
r=$(_run "" "langsmith-ca" "ca.crt")
_check "Secret missing: fails" "1" "${r%%|*}"
_check "Secret missing: prints the kubectl command to create it" "1" \
  "$(printf '%s' "$r" | grep -c 'kubectl -n langsmith create secret generic langsmith-ca --from-file=ca.crt=ca-bundle.pem')"
r=$(_run "tls.crt tls.key" "langsmith-ca" "ca.crt")
_check "Secret without the key: fails" "1" "${r%%|*}"
_check "Secret without the key: lists the keys it has" "1" "$(printf '%s' "$r" | grep -c 'it has: tls.crt tls.key')"
r=$(_run "bundle.pem" "corp-ca" "bundle.pem")
_check "custom key present: passes" "0" "${r%%|*}"

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "$FAIL check(s) failed, $PASS passed."
  exit 1
fi
echo "All $PASS checks passed."
