#!/usr/bin/env bash
# Regression checks for the LLM Gateway values that init-values.sh generates:
# the PII-without-gateway refusal, the gateway and Presidio overlays, the classic
# ALB idle timeout and its merge with base-file attributes, and the Envoy
# no-domain warning. Runs the real script in a temp tree with fake terraform and
# kubectl, so it needs no cloud credentials, cluster, or state.
# Usage: bash modules/aws/helm/scripts/test-init-values-llm-gateway.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_SRC="$SCRIPT_DIR/.."
INFRA_SRC="$HELM_SRC/../infra"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
FAILURES=0
IRSA_ARN="arn:aws:iam::123456789012:role/llmgw-test-langsmith"

mkdir -p "$TEST_TMP/bin"
# Outputs come from MOCK_TF_* variables; an unset one fails like a missing output.
cat > "$TEST_TMP/bin/terraform" <<'EOF'
#!/usr/bin/env bash
key="${*: -1}"
case "$key" in
  bucket_name) echo "llmgw-test-bucket" ;;
  langsmith_irsa_role_arn) echo "$MOCK_IRSA_ARN" ;;
  enable_envoy_gateway) echo "$MOCK_TF_ENVOY" ;;
  enable_istio_gateway|enable_nginx_ingress) echo "false" ;;
  *) exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/kubectl"
chmod +x "$TEST_TMP/bin/terraform" "$TEST_TMP/bin/kubectl"

fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# new_tree <name> <extra tfvars lines>: a fresh copy of the script and examples.
new_tree() {
  local root="$TEST_TMP/$1"
  mkdir -p "$root/helm/scripts" "$root/helm/values" "$root/infra/scripts"
  cp "$SCRIPT_DIR/init-values.sh" "$root/helm/scripts/"
  cp -R "$HELM_SRC/values/examples" "$root/helm/values/"
  cp "$INFRA_SRC/scripts/_common.sh" "$root/infra/scripts/"
  printf 'name_prefix = "llmgw"\nenvironment = "test"\nregion = "us-west-2"\nlangsmith_admin_email = "admin@example.com"\n%s\n' "$2" \
    > "$root/infra/terraform.tfvars"
  echo "$root"
}

# run_init <root> <envoy flag>: runs the script, output in <root>/out.log.
run_init() {
  PATH="$TEST_TMP/bin:$PATH" MOCK_IRSA_ARN="$IRSA_ARN" MOCK_TF_ENVOY="$2" \
    bash "$1/helm/scripts/init-values.sh" </dev/null >"$1/out.log" 2>&1
}

# PII redaction without the gateway is refused before anything is written.
root=$(new_tree pii-only 'enable_gateway_pii_redaction = true')
if run_init "$root" false; then
  fail "PII without the gateway exited 0"
elif ! grep -q 'enable_gateway_pii_redaction requires enable_llm_gateway' "$root/out.log"; then
  fail "PII without the gateway failed without the expected error"
fi

# Classic ALB mode: overlays, and the idle timeout on a fresh base file.
root=$(new_tree alb-fresh $'enable_llm_gateway = true\nenable_gateway_pii_redaction = true')
if ! run_init "$root" false; then
  fail "classic ALB run failed: $(tail -5 "$root/out.log")"
else
  values="$root/helm/values"
  grep -q "eks.amazonaws.com/role-arn: \"$IRSA_ARN\"" "$values/langsmith-values-llm-gateway.yaml" \
    || fail "gateway overlay is missing the IRSA annotation"
  grep -q 'presidioAnalyzer:' "$values/langsmith-values-gateway-pii.yaml" \
    || fail "PII overlay is missing presidioAnalyzer"
  if grep -q 'role-arn' "$values/langsmith-values-gateway-pii.yaml"; then
    fail "PII overlay gives Presidio an IAM role"
  fi
  grep -q 'load-balancer-attributes: "idle_timeout.timeout_seconds=900"' "$values/langsmith-values-overrides.yaml" \
    || fail "overrides file is missing the 900 s ALB idle timeout"
fi

# Classic ALB mode: attributes already in the base file are carried over.
root=$(new_tree alb-merge 'enable_llm_gateway = true')
cat > "$root/helm/values/langsmith-values.yaml" <<'EOF'
ingress:
  annotations:
    alb.ingress.kubernetes.io/load-balancer-attributes: "access_logs.s3.enabled=true"
EOF
if ! run_init "$root" false; then
  fail "ALB merge run failed: $(tail -5 "$root/out.log")"
else
  grep -q 'load-balancer-attributes: "access_logs.s3.enabled=true,idle_timeout.timeout_seconds=900"' \
    "$root/helm/values/langsmith-values-overrides.yaml" \
    || fail "overrides file dropped the base file's ALB attributes"
fi

# Classic ALB mode: an idle timeout already in the base file wins.
root=$(new_tree alb-keep 'enable_llm_gateway = true')
cat > "$root/helm/values/langsmith-values.yaml" <<'EOF'
ingress:
  annotations:
    alb.ingress.kubernetes.io/load-balancer-attributes: 'idle_timeout.timeout_seconds=1800'
EOF
if ! run_init "$root" false; then
  fail "ALB keep run failed: $(tail -5 "$root/out.log")"
else
  grep -q 'load-balancer-attributes: "idle_timeout.timeout_seconds=1800"' \
    "$root/helm/values/langsmith-values-overrides.yaml" \
    || fail "overrides file replaced the base file's idle timeout"
fi

# Envoy mode with no domain warns that long model calls will be cut.
root=$(new_tree envoy-nodomain 'enable_llm_gateway = true')
if ! run_init "$root" true; then
  fail "Envoy run failed: $(tail -5 "$root/out.log")"
else
  grep -q 'WARNING: enable_llm_gateway with Envoy Gateway and no langsmith_domain' "$root/out.log" \
    || fail "Envoy run without a domain printed no warning"
  if grep -q 'load-balancer-attributes' "$root/helm/values/langsmith-values-overrides.yaml"; then
    fail "Envoy run wrote an ALB annotation"
  fi
fi

if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "All LLM Gateway init-values checks passed"
