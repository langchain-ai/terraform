#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-upgrade-guard.sh — Checks upgrade-guard.sh against fake terraform,
# kubectl and aws commands. No AWS, Terraform state, or cluster.
#
# Usage: bash infra/scripts/test-upgrade-guard.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/upgrade-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# Fakes read their answers from files: state (the state list, or the word
# NOSTATE / BROKEN), claims (nodeclaim names, or BROKEN), outputs (key=value).
mkdir -p "$TMP/bin" "$TMP/infra"
cat > "$TMP/bin/terraform" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"state list"*)
    s=$(cat "$FAKE/state")
    [[ "$s" == NOSTATE ]] && { echo "No state file was found!"; exit 1; }
    [[ "$s" == BROKEN ]] && { echo "Error: backend unreachable"; exit 1; }
    printf '%s\n' "$s" ;;
  *"output -json"*) cat "$FAKE/outputs.json" ;;
  *"output -raw "*) grep "^${!#}=" "$FAKE/outputs" | cut -d= -f2- | grep . || exit 1 ;;
esac
EOF
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
c=$(cat "$FAKE/claims"); [[ "$c" == BROKEN ]] && { echo "connection refused"; exit 1; }
printf '%s' "$c"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/aws"
chmod +x "$TMP/bin/"*

# run <name> <want exit> <want message> <tfvars> <state> <claims> [outputs json]
# A refusal must name its reason, so a refusal for the wrong reason fails.
run() {
  local name="$1" want="$2" message="$3" tfvars="$4" state="$5" claims="$6" outputs_json="${7:-}"
  [[ -n "$outputs_json" ]] || outputs_json='{}'
  printf '%b' "$tfvars" > "$TMP/infra/terraform.tfvars"
  printf '%b' "$state" > "$TMP/state"
  printf '%b' "$claims" > "$TMP/claims"
  printf 'cluster_name=c1\n' > "$TMP/outputs"
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

POOLS='module.eks.x\nkubectl_manifest.smithdb_nodepool_compute[0]\nkubectl_manifest.smithdb_nodepool_instance_store[0]'
TFV='region = "us-west-2"\nenable_smithdb = true\n'

run "a new install with no state passes" 0 "" "$TFV" "NOSTATE" ""
run "an unreadable state refuses" 1 "could not read the Terraform state" "$TFV" "BROKEN" ""
run "no Karpenter pools in state passes" 0 "" "$TFV" 'module.eks.x' ""
run "pools in state with the keep flag passes" 0 "" "${TFV}smithdb_keep_karpenter_pools = true\n" "$POOLS" "nodeclaim/a"
run "pools in state, flag off, nodes still owned refuses" 1 "still owns 2 node(s)" "$TFV" "$POOLS" "nodeclaim/a\nnodeclaim/b"
run "pools in state, flag off, no nodes left passes" 0 "" "$TFV" "$POOLS" ""
run "pools in state, flag off, cluster unreachable refuses" 1 "listing their nodes failed" "$TFV" "$POOLS" "BROKEN"

echo ""
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
