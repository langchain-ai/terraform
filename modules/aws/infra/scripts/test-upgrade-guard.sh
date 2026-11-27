#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-upgrade-guard.sh — Checks upgrade-guard.sh, and the NGINX stop that
# init-values.sh and deploy.sh run (_stop_if_nginx_applied in _common.sh),
# against a fake terraform. No AWS, Terraform state, or cluster.
#
# Usage: bash infra/scripts/test-upgrade-guard.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/upgrade-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# The fake reads its answers from files: state (the state list, or the word
# NOSTATE / BROKEN), outputs.json, and nginx_output (empty when the state has
# no enable_nginx_ingress output).
mkdir -p "$TMP/bin" "$TMP/infra"
cat > "$TMP/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"state list"*)
    s=$(cat "$FAKE/state")
    [[ "$s" == NOSTATE ]] && { echo "No state file was found!"; exit 1; }
    [[ "$s" == BROKEN ]] && { echo "Error: backend unreachable"; exit 1; }
    printf '%s\n' "$s" ;;
  *"output -json"*) cat "$FAKE/outputs.json" ;;
  *"output -raw enable_nginx_ingress"*)
    [[ -s "$FAKE/nginx_output" ]] || { echo 'Error: Output "enable_nginx_ingress" not found' >&2; exit 1; }
    cat "$FAKE/nginx_output" ;;
esac
FAKE
chmod +x "$TMP/bin/terraform"

# run <name> <want exit> <want message> <tfvars> <state> [outputs json]
# A refusal must name its reason, so a refusal for the wrong reason fails.
run() {
  local name="$1" want="$2" message="$3" tfvars="$4" state="$5" outputs_json="${6:-}"
  [[ -n "$outputs_json" ]] || outputs_json='{}'
  printf '%b' "$tfvars" > "$TMP/infra/terraform.tfvars"
  printf '%b' "$state" > "$TMP/state"
  printf '%s' "$outputs_json" > "$TMP/outputs.json"
  local got=0
  PATH="$TMP/bin:$PATH" FAKE="$TMP" INFRA_DIR="$TMP/infra" HOME="$TMP" \
    bash "$GUARD" > "$TMP/out" 2>&1 || got=$?
  if [[ "$got" == "$want" ]] && { [[ -z "$message" ]] || grep -qF -- "$message" "$TMP/out"; }; then
    PASS=$((PASS + 1)); echo "  PASS  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $name (exit $got, want $want)"; sed 's/^/        /' "$TMP/out"
  fi
}

R='region = "us-west-2"\n'
V018='{"smithdb_query_enabled":{"value":true}}'

run "a new install with no state passes" 0 "" "$R" "NOSTATE"
run "an empty state passes" 0 "" "$R" ""
run "an unreadable state refuses" 1 "could not read the Terraform state" "$R" "BROKEN"
# The first 0.18 apply of a 0.17 install (no smithdb_query_enabled output yet).
run "0.17 state without enable_smithdb refuses" 1 "set enable_smithdb" "$R" 'module.eks.x'
run "0.17 state with enable_smithdb = false passes" 0 "" "${R}enable_smithdb = false\n" 'module.eks.x'
run "0.17 SmithDB state without the ingestion gate refuses" 1 "set smithdb_ingestion_enabled" "${R}enable_smithdb = true\nsmithdb_query_enabled = false\n" 'module.eks.x'
run "0.17 SmithDB state without the query gate refuses" 1 "set smithdb_query_enabled" "${R}enable_smithdb = true\nsmithdb_ingestion_enabled = false\n" 'module.eks.x'
run "0.17 SmithDB state with both gates set passes" 0 "" "${R}enable_smithdb = true\nsmithdb_ingestion_enabled = true\nsmithdb_query_enabled = false\n" 'module.eks.x'
run "0.18 state with settings left to their defaults passes" 0 "" "$R" 'module.eks.x' "$V018"
# A state that still runs NGINX refuses whatever terraform.tfvars says: before
# the SmithDB checks (they would pass here), and before the early exit a state
# with the 0.18 outputs takes.
N='module.k8s_bootstrap.helm_release.nginx_ingress[0]\nmodule.k8s_bootstrap.terraform_data.nginx_target_group_binding[0]\naws_vpc_security_group_ingress_rule.alb_to_nginx[0]'
run "0.17 state that runs NGINX refuses" 1 "still runs the NGINX ingress controller" "${R}enable_smithdb = false\n" "module.eks.x\n$N"
run "state with the 0.18 outputs that runs NGINX refuses" 1 "still runs the NGINX ingress controller" "$R" "module.eks.x\n$N" "$V018"
run "NGINX under a wrapper module refuses" 1 "still runs the NGINX ingress controller" "$R" 'module.langsmith.module.k8s_bootstrap.helm_release.nginx_ingress[0]' "$V018"
run "the NGINX ALB rule left by a failed apply refuses" 1 "still runs the NGINX ingress controller" "$R" 'module.eks.x\naws_vpc_security_group_ingress_rule.alb_to_nginx[0]' "$V018"

# nginx_stop <name> <want exit> <enable_nginx_ingress output, empty when absent> <tfvars>
nginx_stop() {
  local name="$1" want="$2" value="$3" tfvars="$4" got=0
  printf '%s' "$value" > "$TMP/nginx_output"
  printf '%b' "$tfvars" > "$TMP/infra/terraform.tfvars"
  PATH="$TMP/bin:$PATH" FAKE="$TMP" INFRA_DIR="$TMP/infra" HOME="$TMP" \
    bash -c 'source "$1" && _stop_if_nginx_applied' _ "$SCRIPT_DIR/_common.sh" > "$TMP/out" 2>&1 || got=$?
  if [[ "$got" == "$want" ]] && { [[ "$want" == 0 ]] || grep -qF "still runs NGINX ingress" "$TMP/out"; }; then
    PASS=$((PASS + 1)); echo "  PASS  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $name (exit $got, want $want)"; sed 's/^/        /' "$TMP/out"
  fi
}

nginx_stop "the Helm steps stop on a state last applied with NGINX" 1 "true" "$R"
nginx_stop "the Helm steps continue on a state last applied without NGINX" 0 "false" "$R"
nginx_stop "the Helm steps continue on a 0.18 state and the false QuickStart wrote" 0 "" "${R}enable_nginx_ingress = false\n"
nginx_stop "the Helm steps stop with no output and true in terraform.tfvars" 1 "" "${R}enable_nginx_ingress = true\n"

echo ""
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
