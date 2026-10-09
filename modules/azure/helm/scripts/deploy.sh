#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# deploy.sh — Deploy or upgrade LangSmith via Helm on Azure.
#
# Values files loaded (in order, last wins):
#   1. values.yaml                               — base Azure config (always)
#   2. values-overrides.yaml                     — env-specific: hostname, WI, blob (required)
#   3. langsmith-values-agent-deploys.yaml       — Deployments feature (if enable_deployments = true)
#   4. langsmith-values-agent-builder.yaml       — Agent Builder, legacy (if enable_agent_builder = true)
#   5. langsmith-values-fleet.yaml               — Fleet, standalone (if enable_fleet = true; replaces #4)
#   6. langsmith-values-insights.yaml            — Insights (if enable_insights = true)
#   7. langsmith-values-polly.yaml               — Polly (if enable_polly = true)
#   7b. langsmith-values-llm-gateway.yaml        — LLM Gateway (if enable_llm_gateway = true)
#   7c. langsmith-values-gateway-pii.yaml        — its PII redaction (if enable_gateway_pii_redaction = true)
#   8. langsmith-values-sizing-{profile}.yaml    — sizing profile (from sizing_profile in terraform.tfvars)
#   9. langsmith-values-smithdb*.yaml             — SmithDB (if enable_smithdb = true)
#
# Generate values files first: make init-values (or: ./helm/scripts/init-values.sh)
# Templates live in helm/values/examples/ — init-values.sh copies them based on your choices.
#
# Usage (from azure/):
#   ./helm/scripts/deploy.sh
#   CHART_VERSION=0.17.0 ./helm/scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"

source "$INFRA_DIR/scripts/_common.sh"

# The Helm release name: RELEASE_NAME from the environment if set, else
# langsmith_release_name from terraform.tfvars, else langsmith. The chart names
# its objects after its fullname, which is the release name only when that
# contains "langsmith" (prod -> prod-langsmith-backend).
RELEASE_NAME="${RELEASE_NAME:-$(_parse_tfvar langsmith_release_name || echo langsmith)}"
if [[ "$RELEASE_NAME" == *langsmith* ]]; then
  CHART_FULLNAME="$RELEASE_NAME"
else
  CHART_FULLNAME="${RELEASE_NAME}-langsmith"
fi
# Same order for the namespace. The Terraform side (the workload identity
# subjects, the namespace itself) reads langsmith_namespace, so an env-only
# value installed the release where no federated identity pointed.
NAMESPACE="${NAMESPACE:-$(_parse_tfvar langsmith_namespace || echo langsmith)}"
CHART_VERSION="${CHART_VERSION:-}"

BASE_VALUES_FILE="$VALUES_DIR/values.yaml"
OVERRIDES_FILE="$VALUES_DIR/values-overrides.yaml"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith Azure — Helm Deploy"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Validate required values files ────────────────────────────────────────
if [[ ! -f "$OVERRIDES_FILE" ]]; then
  fail "values-overrides.yaml not found"
  action "make init-values  (generates it from terraform outputs)"
  exit 1
fi
# init-values writes insights.enabled and polly.enabled into every overrides file
# it generates. A file without them predates that, and may be missing other
# settings init-values writes now.
if ! grep -q '^insights:' "$OVERRIDES_FILE" || ! grep -q '^polly:' "$OVERRIDES_FILE"; then
  warn "values-overrides.yaml has no insights/polly block, so it predates the current init-values"
  action "make init-values  (regenerates it; re-apply any hand edits afterward)"
fi

# ── Reject a values-overrides.yaml generated from different tfvars ─────────
# init-values.sh bakes tfvars values into that file and `make deploy` never
# regenerates it, so a tfvars edit afterward leaves Terraform and Helm deploying
# different configurations.
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  warn "terraform.tfvars not found — values-overrides.yaml not checked against it"
  echo ""
else
  _stale=""
  _stamped="false"
  for _key in $_VALUES_INPUT_KEYS; do
    _was=$(_read_values_stamp "$OVERRIDES_FILE" "$_key") || continue
    _stamped="true"
    _now=$(_parse_tfvar "$_key") || _now=""
    [[ "$_was" == "$_now" ]] && continue
    _stale="${_stale}${_key}: generated with '${_was}', terraform.tfvars now says '${_now}'
"
  done

  if [[ "$_stamped" != "true" ]]; then
    warn "values-overrides.yaml carries no terraform.tfvars stamp (written by an older init-values.sh)"
    action "make init-values  (adds the stamp, so this check can run)"
    echo ""
  elif [[ -n "$_stale" ]]; then
    fail "values-overrides.yaml was generated from different terraform.tfvars values:"
    printf '%s' "$_stale" | while IFS= read -r _line; do
      [[ -n "$_line" ]] && info "$_line"
    done
    echo ""
    info "terraform apply used the current terraform.tfvars; this file still describes the old one."
    action "make init-values  (regenerate it, then re-run make deploy)"
    exit 1
  fi
fi

# ── Point kubeconfig at the right cluster ─────────────────────────────────
_cluster_name=$(_tf_out aks_cluster_name) || {
  fail "Could not read aks_cluster_name. Is 'terraform apply' complete?"
  exit 1
}
_rg_name=$(_tf_out aks_resource_group_name) || {
  fail "Could not read aks_resource_group_name. Run 'make apply' to record it."
  exit 1
}

info "Cluster: ${_cluster_name}"
_aks_get_credentials "$_cluster_name" "$_rg_name" >/dev/null || {
  fail "Could not fetch credentials for cluster '${_cluster_name}'."
  action "make kubeconfig  (to retry once the error above is fixed)"
  exit 1
}
_aks_kubelogin_convert "$_cluster_name" "$_rg_name"
info "Active context: $(kubectl config current-context)"
echo ""

# ── Set DNS label annotation on the ingress LoadBalancer service ──────────
# Azure assigns <dns_label>.<region>.cloudapp.azure.com (cloudapp.usgovcloudapi.net
# in Azure Government) to the public IP only when
# the annotation service.beta.kubernetes.io/azure-dns-label-name is on the LB service.
# Covers nginx, istio and istio-addon. Envoy Gateway creates its Service per Gateway,
# so the EnvoyProxy in the Envoy Gateway block below carries the label instead.
# cert-manager's HTTP-01 challenge requires DNS to resolve before cert issuance.
_dns_label=$(_parse_tfvar "dns_label") || _dns_label=""
_location=$(_parse_tfvar "location") || _location="eastus"
_ingress_controller=$(_parse_tfvar "ingress_controller") || _ingress_controller="envoy-gateway"
_cloudapp_suffix=$(_azure_cloudapp_suffix)
# ingress_load_balancer = "internal" puts the controller's load balancer on a
# private IP in the cluster's VNet. Terraform annotates the Services it owns
# (nginx, self-managed Istio); the EnvoyProxy and the Istio add-on's internal
# gateway are handled below. Terraform refuses dns_label with "internal".
_ingress_lb=$(_parse_tfvar "ingress_load_balancer") || _ingress_lb="public"
_ingress_lb_subnet_id=$(_parse_tfvar "ingress_load_balancer_subnet_id") || _ingress_lb_subnet_id=""
_ingress_lb_ip=$(_parse_tfvar "ingress_load_balancer_ip") || _ingress_lb_ip=""
# The subnet annotation takes the subnet's name, not its ID.
_ingress_lb_subnet="${_ingress_lb_subnet_id##*/}"
if [[ -n "$_dns_label" ]]; then
  case "$_ingress_controller" in
    nginx)
      _lb_svc="ingress-nginx-controller"
      _lb_ns="ingress-nginx"
      ;;
    istio-addon)
      _lb_svc="aks-istio-ingressgateway-external"
      _lb_ns="aks-istio-ingress"
      ;;
    istio)
      _lb_svc="istio-ingressgateway"
      _lb_ns="istio-system"
      ;;
    *)
      _lb_svc=""
      _lb_ns=""
      ;;
  esac
  if [[ -n "$_lb_svc" ]] && kubectl get svc "$_lb_svc" -n "$_lb_ns" &>/dev/null; then
    kubectl annotate svc "$_lb_svc" -n "$_lb_ns" \
      "service.beta.kubernetes.io/azure-dns-label-name=${_dns_label}" \
      --overwrite &>/dev/null
    pass "DNS label set (${_ingress_controller}): ${_dns_label}.${_location}.${_cloudapp_suffix}"
  elif [[ -n "$_lb_svc" ]]; then
    warn "${_lb_svc} not found in ${_lb_ns} — DNS label not set (run make apply first)"
  fi
fi

# ── Apply ClusterIssuer ────────────────────────────────────────────────────
# kubernetes_manifest in Terraform can't create these on fresh deploy (no cluster
# exists during plan). Applied here instead — idempotent, safe to re-run.
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source=""

# ── Ingress class for ingress_controller = "none" ─────────────────────────
# No class is set for none, so the chart's Ingress and the HTTP-01 solver's go
# to the cluster's default IngressClass, unless values-overrides.yaml (or
# values.yaml) names one. With neither, no controller serves them. Kubernetes
# also refuses a classless Ingress when more than one class claims the default.
_byo_ingress_class=""
if [[ "$_ingress_controller" == "none" ]]; then
  for _vf in "$OVERRIDES_FILE" "$BASE_VALUES_FILE"; do
    [[ -f "$_vf" ]] || continue
    _byo_ingress_class=$(_values_ingress_class "$_vf")
    [[ -n "$_byo_ingress_class" ]] && { _byo_class_file=$(basename "$_vf"); break; }
  done

  if [[ -n "$_byo_ingress_class" ]]; then
    if ! [[ "$_byo_ingress_class" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
      fail "ingress.ingressClassName '${_byo_ingress_class}' in ${_byo_class_file} is not a valid IngressClass name."
      exit 1
    fi
    pass "ingress_controller = none: Ingress uses class '${_byo_ingress_class}' from ${_byo_class_file}"
  elif ! _default_classes=$(kubectl get ingressclass -o jsonpath='{range .items[?(@.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null); then
    warn "ingress_controller = none: could not list IngressClasses, so the default class is unverified."
  else
    read -r -a _default_class_list <<<"$_default_classes"
    case "${#_default_class_list[@]}" in
      1)
        pass "ingress_controller = none: Ingress uses the cluster's default IngressClass '${_default_class_list[0]}'"
        ;;
      0)
        if [[ "$_tls_source" == "letsencrypt" ]]; then
          fail "ingress_controller = none: the cluster has no default IngressClass, so no controller would serve the Ingress or the Let's Encrypt HTTP-01 challenge. Set ingress.ingressClassName in values-overrides.yaml to your controller's class, or mark that IngressClass as the default."
          exit 1
        fi
        warn "ingress_controller = none: the cluster has no default IngressClass, so no controller will serve the LangSmith Ingress. Set ingress.ingressClassName in values-overrides.yaml to your controller's class, or mark that IngressClass as the default. Port-forwarding to langsmith-frontend works regardless."
        ;;
      *)
        fail "ingress_controller = none: IngressClasses ${_default_classes% } all claim the default, and Kubernetes rejects an Ingress with no class in that case. Set ingress.ingressClassName in values-overrides.yaml, or leave one default."
        exit 1
        ;;
    esac
  fi
fi

# With Envoy Gateway, both cert-manager TLS paths issue through its Gateway shim,
# which Terraform switches on only for the cert-manager it installs.
if [[ "$_ingress_controller" == "envoy-gateway" ]] && [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "dns01" ]]; then
  _install_cert_manager=$(_parse_tfvar "install_cert_manager") || _install_cert_manager=true
  if [[ "$_install_cert_manager" == "false" ]]; then
    warn "install_cert_manager = false: the cluster's own cert-manager must run with Gateway API support enabled, or no certificate is issued for the Envoy Gateway listener."
  fi
fi
if [[ "$_tls_source" == "letsencrypt" ]]; then
  _le_email=$(_parse_tfvar "letsencrypt_email") || _le_email=""
  _le_namespace="$NAMESPACE"
  _le_hostname="${_dns_label}.${_location}.${_cloudapp_suffix}"
  _le_domain=$(_parse_tfvar "langsmith_domain") || _le_domain=""
  [[ -n "$_le_domain" ]] && _le_hostname="$_le_domain"

  if [[ "$_ingress_controller" == "envoy-gateway" ]]; then
    # Envoy Gateway uses Gateway API: the gatewayHTTPRoute solver below needs
    # cert-manager's Gateway API support, which Terraform enables on the
    # cert-manager it installs (k8s-bootstrap).
    kubectl apply -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${_le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        gatewayHTTPRoute:
          parentRefs:
          - name: langsmith-gateway
            namespace: ${_le_namespace}
            kind: Gateway
EOF
    pass "ClusterIssuer letsencrypt-prod configured (solver: gatewayHTTPRoute)"
  else
    # Map ingress controller to the class cert-manager uses for HTTP-01 solvers.
    # For none, an empty class leaves the solver's Ingress to the default class.
    case "$_ingress_controller" in
      istio|istio-addon) _acme_ingress_class="istio" ;;
      nginx)             _acme_ingress_class="nginx" ;;
      agic)              _acme_ingress_class="azure-application-gateway" ;;
      *)                 _acme_ingress_class="$_byo_ingress_class" ;;
    esac
    kubectl apply -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${_le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress: {${_acme_ingress_class:+ingressClassName: ${_acme_ingress_class}}}
EOF
    pass "ClusterIssuer letsencrypt-prod configured (solver class: ${_acme_ingress_class:-cluster default})"
  fi
fi

if [[ "$_tls_source" == "dns01" ]]; then
  # DNS-01 via Azure DNS + Workload Identity.
  # Requires: langsmith_domain set, create_dns_zone = true, Azure DNS zone NS-delegated.
  # cert-manager WI setup (pod labels + SA annotation) is handled by Terraform k8s-bootstrap.
  _le_email=$(_parse_tfvar "letsencrypt_email") || _le_email=""
  _le_domain=$(_parse_tfvar "langsmith_domain") || _le_domain=""
  _dns_zone="$_le_domain"                          # zone name = domain name
  _dns_rg=$(_tf_out resource_group_name) || _dns_rg=""
  _subscription_id=$(_parse_tfvar "subscription_id") || _subscription_id=""
  _cert_manager_client_id=$(_tf_out cert_manager_identity_client_id) || _cert_manager_client_id=""

  if [[ -z "$_le_domain" ]]; then
    warn "dns01 requires langsmith_domain to be set in terraform.tfvars — ClusterIssuer skipped"
  elif [[ -z "$_cert_manager_client_id" ]]; then
    warn "dns01 requires cert_manager_identity_client_id output — run make apply first"
  else
    kubectl apply -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${_le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - dns01:
        azureDNS:
          subscriptionID: ${_subscription_id}
          resourceGroupName: ${_dns_rg}
          hostedZoneName: ${_dns_zone}
          environment: $(_cert_manager_azure_environment)
          managedIdentity:
            clientID: ${_cert_manager_client_id}
EOF
    pass "ClusterIssuer letsencrypt-prod configured (solver: dns01/azureDNS)"
  fi
fi

# ── Self-managed Istio: create IngressClass resource ──────────────────────
# istiod needs an IngressClass named "istio" to exist so it generates listeners
# for the istio-ingressgateway. Without it, LDS push has 0 resources.
if [[ "$_ingress_controller" == "istio" ]]; then
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
EOF
  pass "IngressClass 'istio' created"
fi

# ── Create Istio Gateway resource (istio-addon only) ──────────────────────
# With AKS managed Istio, ingressClassName: istio targets label istio: ingressgateway
# but the AKS external gateway has label istio: aks-istio-ingressgateway-external.
# We create explicit Gateway + VirtualService to route port 80/443 correctly.
# Runs with either hostname source: langsmith_domain alone is the usual setup for
# dns01 and existing, and without this Gateway the chart's VirtualServices bind to
# nothing.
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
if [[ "$_ingress_controller" == "istio-addon" && ( -n "$_dns_label" || -n "$_langsmith_domain" ) ]]; then
  _istio_hostname="${_dns_label}.${_location}.${_cloudapp_suffix}"
  [[ -n "$_langsmith_domain" ]] && _istio_hostname="$_langsmith_domain"
  _namespace="$NAMESPACE"
  # The add-on labels each gateway's Service istio: aks-istio-ingressgateway-
  # external or -internal; Terraform enables only the internal one when the
  # load balancer is internal.
  _istio_gw="external"
  [[ "$_ingress_lb" == "internal" ]] && _istio_gw="internal"

  kubectl apply -f - &>/dev/null <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${_namespace}
spec:
  selector:
    istio: aks-istio-ingressgateway-${_istio_gw}
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "${_istio_hostname}"
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: langsmith-tls
    hosts:
    - "${_istio_hostname}"
EOF
  pass "Istio Gateway created: ${_istio_hostname} (ports 80 + 443)"
fi

# The Istio add-on creates its internal gateway's Service itself, so the subnet
# and static IP go on as annotations, which Microsoft lists as supported on that
# Service ("External or internal ingresses for the Istio service mesh add-on").
if [[ "$_ingress_controller" == "istio-addon" && "$_ingress_lb" == "internal" ]]; then
  _istio_int_ann=()
  [[ -n "$_ingress_lb_subnet" ]] && _istio_int_ann+=("service.beta.kubernetes.io/azure-load-balancer-internal-subnet=${_ingress_lb_subnet}")
  [[ -n "$_ingress_lb_ip" ]] && _istio_int_ann+=("service.beta.kubernetes.io/azure-load-balancer-ipv4=${_ingress_lb_ip}")
  if [[ ${#_istio_int_ann[@]} -gt 0 ]]; then
    if kubectl get svc aks-istio-ingressgateway-internal -n aks-istio-ingress &>/dev/null; then
      kubectl annotate svc aks-istio-ingressgateway-internal -n aks-istio-ingress \
        "${_istio_int_ann[@]}" --overwrite >/dev/null
      pass "Istio internal gateway: ${_istio_int_ann[*]}"
    else
      fail "aks-istio-ingressgateway-internal not found in aks-istio-ingress. Run make apply: ingress_load_balancer = \"internal\" enables the add-on's internal gateway."
      exit 1
    fi
  fi
fi

# ── Your own certificate and CA bundle ─────────────────────────────────────
# With tls_certificate_source = "existing" nothing issues langsmith-tls, so a
# missing Secret would leave the site serving the controller's default
# certificate. Every controller path reads it from the release namespace (both
# Istio paths copy it to their gateway namespace after the Helm upgrade).
if [[ "$_tls_source" == "existing" ]]; then
  _tls_type=$(kubectl get secret langsmith-tls -n "$NAMESPACE" -o jsonpath='{.type}' 2>/dev/null) || _tls_type=""
  if [[ -z "$_tls_type" ]]; then
    fail "tls_certificate_source = \"existing\" but Secret langsmith-tls is missing in namespace ${NAMESPACE}. Create it from your certificate (leaf first, then the intermediates) and its key:"
    echo "      kubectl -n ${NAMESPACE} create secret tls langsmith-tls --cert=fullchain.pem --key=privkey.pem"
    exit 1
  elif [[ "$_tls_type" != "kubernetes.io/tls" ]]; then
    fail "Secret langsmith-tls in ${NAMESPACE} is of type ${_tls_type}, not kubernetes.io/tls. Re-create it with kubectl create secret tls."
    exit 1
  fi
  pass "Secret langsmith-tls (kubernetes.io/tls) found in ${NAMESPACE}"
fi

_custom_ca_secret=$(_parse_tfvar "langsmith_custom_ca_secret_name") || _custom_ca_secret=""
if [[ -n "$_custom_ca_secret" ]]; then
  _custom_ca_key=$(_parse_tfvar "langsmith_custom_ca_secret_key") || _custom_ca_key="ca.crt"
  _ca_keys=$(kubectl get secret "$_custom_ca_secret" -n "$NAMESPACE" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>/dev/null) || _ca_keys=""
  if [[ -z "$_ca_keys" ]]; then
    fail "langsmith_custom_ca_secret_name = \"${_custom_ca_secret}\" but that Secret is missing in namespace ${NAMESPACE}. Create it from your root and intermediate certificates:"
    echo "      kubectl -n ${NAMESPACE} create secret generic ${_custom_ca_secret} --from-file=${_custom_ca_key}=ca-bundle.pem"
    exit 1
  elif [[ " ${_ca_keys} " != *" ${_custom_ca_key} "* ]]; then
    fail "Secret ${_custom_ca_secret} has no key ${_custom_ca_key} (it has: ${_ca_keys% }). Set langsmith_custom_ca_secret_key, or re-create the Secret."
    exit 1
  fi
  pass "CA bundle ${_custom_ca_secret}/${_custom_ca_key} found in ${NAMESPACE}"
fi

# ── Preflight checks ──────────────────────────────────────────────────────
"$SCRIPT_DIR/preflight-check.sh"

# ── Ensure langsmith-config-secret exists ─────────────────────────────────
info "Verifying langsmith-config-secret..."
if ! kubectl get secret langsmith-config-secret -n "$NAMESPACE" &>/dev/null; then
  warn "langsmith-config-secret not found — creating from Key Vault..."
  bash "$INFRA_DIR/scripts/create-k8s-secrets.sh"
else
  pass "langsmith-config-secret exists"
fi

# ── Ensure langsmith-clickhouse secret exists (external ClickHouse only) ──
# With clickhouse_source = "external" the chart skips its own ClickHouse
# StatefulSet and resolves all seven connection fields through secretKeyRef with
# optional=false. A missing secret or a missing key strands every LangSmith pod
# in CreateContainerConfigError, so fail here where the cause is still legible.
_clickhouse_source=$(_parse_tfvar "clickhouse_source") || _clickhouse_source="in-cluster"
if [[ "$_clickhouse_source" == "external" ]]; then
  info "Verifying langsmith-clickhouse secret..."
  # go-template over key names only — secret values never leave the API server.
  _ch_keys=$(kubectl get secret langsmith-clickhouse -n "$NAMESPACE" \
    -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null) || _ch_keys=""
  if [[ -z "$_ch_keys" ]]; then
    fail "clickhouse_source = \"external\" but secret langsmith-clickhouse is missing in namespace $NAMESPACE."
    action "Run: make init-values   (prompts for the connection and creates the secret)"
    exit 1
  fi
  _ch_missing=""
  for _ch_key in clickhouse_host clickhouse_port clickhouse_native_port \
                 clickhouse_user clickhouse_password clickhouse_db clickhouse_tls; do
    grep -qx "$_ch_key" <<< "$_ch_keys" || _ch_missing="${_ch_missing} ${_ch_key}"
  done
  if [[ -n "$_ch_missing" ]]; then
    fail "Secret langsmith-clickhouse is missing required keys:${_ch_missing}"
    action "kubectl delete secret langsmith-clickhouse -n $NAMESPACE && make init-values"
    exit 1
  fi
  pass "langsmith-clickhouse secret exists with all required keys"
else
  skip "langsmith-clickhouse secret not required (clickhouse_source = in-cluster)"
fi

# ── Pre-deploy hostname check ─────────────────────────────────────────────
_configured_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
  | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _configured_hostname=""
if [[ -n "$_configured_hostname" && "$_configured_hostname" == *"<"* ]]; then
  warn "config.hostname still contains a placeholder — run: make init-values"
fi

# ── Read feature flags from terraform.tfvars ──────────────────────────────
_sizing_profile=$(_parse_tfvar "sizing_profile") || _sizing_profile="default"
_postgres_source=$(_parse_tfvar "postgres_source") || _postgres_source="external"
_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_enable_llm_gateway=false
_enable_gateway_pii_redaction=false
_enable_fleet=false
_enable_smithdb=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true  || true
_tfvar_is_true "enable_agent_builder" && _enable_agent_builder=true || true
_tfvar_is_true "enable_insights"      && _enable_insights=true     || true
_tfvar_is_true "enable_polly"         && _enable_polly=true        || true
_tfvar_is_true "enable_llm_gateway"   && _enable_llm_gateway=true  || true
_tfvar_is_true "enable_gateway_pii_redaction" && _enable_gateway_pii_redaction=true || true
_tfvar_is_true "enable_fleet"         && _enable_fleet=true        || true
_tfvar_is_true "enable_smithdb"        && _enable_smithdb=true       || true

# Validate addon dependencies
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  fail "enable_agent_builder = true requires enable_deployments = true in terraform.tfvars"
  exit 1
fi
if [[ "$_enable_fleet" == "true" && "$_enable_deployments" != "true" ]]; then
  fail "enable_fleet = true requires enable_deployments = true in terraform.tfvars"
  exit 1
fi
if [[ "$_enable_fleet" == "true" && "$_enable_agent_builder" == "true" ]]; then
  fail "enable_fleet and enable_agent_builder are mutually exclusive — Fleet replaces the legacy Agent Builder path. Set enable_agent_builder = false."
  exit 1
fi
# Fleet needs the dedicated langsmith_fleet database + langsmith-fleet-postgres
# secret, which infra only creates for external Postgres. In-cluster Postgres has
# no fleet database, so the deploy would fail later resolving the missing secret.
if [[ "$_enable_fleet" == "true" && "$_postgres_source" != "external" ]]; then
  fail "enable_fleet = true requires postgres_source = external in terraform.tfvars"
  exit 1
fi

# ── Build values args ─────────────────────────────────────────────────────
VALUES_ARGS=()

# Base values (optional — provides Azure defaults + production sizing)
if [[ -f "$BASE_VALUES_FILE" ]]; then
  VALUES_ARGS+=(-f "$BASE_VALUES_FILE")
  echo "Values chain:"
  echo "  ✔ values.yaml (base)"
else
  echo "Values chain:"
  echo "  ○ values.yaml (not found — using overrides only)"
fi

VALUES_ARGS+=(-f "$OVERRIDES_FILE")
echo "  ✔ values-overrides.yaml"

# Addon overlays
_addon_gate=(
  "agent-deploys:deployments:$_enable_deployments"
  "agent-builder:agent_builder:$_enable_agent_builder"
  "fleet:fleet:$_enable_fleet"
  "insights:insights:$_enable_insights"
  "polly:polly:$_enable_polly"
  "llm-gateway:llm_gateway:$_enable_llm_gateway"
  "gateway-pii:gateway_pii_redaction:$_enable_gateway_pii_redaction"
)
for entry in "${_addon_gate[@]}"; do
  addon="${entry%%:*}"
  rest="${entry#*:}"
  flag_name="${rest%%:*}"
  enabled="${rest##*:}"
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ "$enabled" == "true" ]]; then
    if [[ -f "$f" ]]; then
      VALUES_ARGS+=(-f "$f")
      echo "  ✔ langsmith-values-${addon}.yaml (enable_${flag_name} = true)"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (enable_${flag_name} = true but file not found — run: make init-values)"
    fi
  else
    if [[ -f "$f" ]]; then
      echo "  ○ langsmith-values-${addon}.yaml (file exists but enable_${flag_name} = false — skipped)"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (not enabled)"
    fi
  fi
done

# Sizing profile. Loaded after the addon overlays because agent-deploys carries
# its own hostBackend/listener/operator resources for the default profile, and
# loaded before it those overrode whatever profile was chosen.
if [[ "$_sizing_profile" != "default" ]]; then
  _sizing_file="$VALUES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  if [[ -f "$_sizing_file" ]]; then
    VALUES_ARGS+=(-f "$_sizing_file")
    echo "  ✔ langsmith-values-sizing-${_sizing_profile}.yaml (sizing_profile = ${_sizing_profile})"
    if [[ "$_sizing_profile" == "minimum" ]]; then
      echo ""
      echo "  ⚠️  WARNING: sizing_profile = minimum — NOT for production."
      echo "     Use sizing_profile = production for production deployments."
      echo ""
    fi
  else
    echo "  ✗ langsmith-values-sizing-${_sizing_profile}.yaml (not found — run: make init-values)"
  fi
else
  echo "  ○ sizing: base values defaults (sizing_profile = default)"
fi

if [[ "$_enable_smithdb" == "true" ]]; then
  _smithdb_base="$VALUES_DIR/langsmith-values-smithdb.yaml"
  _smithdb_overrides="$VALUES_DIR/langsmith-values-smithdb-overrides.yaml"
  if [[ ! -f "$_smithdb_base" || ! -f "$_smithdb_overrides" ]]; then
    fail "enable_smithdb = true but the SmithDB values files are missing — run: make init-values"
    exit 1
  fi
  VALUES_ARGS+=(-f "$_smithdb_base" -f "$_smithdb_overrides")
  echo "  ✔ langsmith-values-smithdb.yaml + langsmith-values-smithdb-overrides.yaml"
fi
echo ""

# ── Chart source/version ──────────────────────────────────────────────────
_chart_source="langchain/langsmith"
# Precedence: CHART_VERSION env var > terraform.tfvars > pinned line default.
# We pin the chart line so an unpinned deploy cannot silently jump a breaking
# minor.
# An exported CHART_VERSION outlives the command that set it, so a value left over
# from an earlier session silently wins over the pin. Say so rather than deploying
# a different chart than the branch intends.
if [[ -n "${CHART_VERSION:-}" ]]; then
  echo "NOTE: CHART_VERSION='${CHART_VERSION}' comes from your environment and overrides the pinned chart line."
  echo "      Run 'unset CHART_VERSION' to deploy the pinned chart line."
fi
if [[ -z "$CHART_VERSION" ]]; then
  CHART_VERSION=$(_parse_tfvar "langsmith_helm_chart_version") || CHART_VERSION=""
fi
CHART_VERSION="${CHART_VERSION:-~0.17.0}"
_required_chart_line="0.17"

# These values target chart 0.17, where the SmithDB Azure values first appear.
# Refuse any other line rather than deploy a half-configured release.
_chart_line="$(printf '%s' "$CHART_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$_chart_line" != "$_required_chart_line" ]]; then
  echo "ERROR: CHART_VERSION '$CHART_VERSION' does not resolve to the chart ${_required_chart_line} line." >&2
  echo "       These values require chart ${_required_chart_line} (SmithDB values, engineInsightsAgent)." >&2
  echo "       Leave CHART_VERSION unset to use the pin, or name a ${_required_chart_line} patch explicitly:" >&2
  echo "         CHART_VERSION=${_required_chart_line}.0 make deploy" >&2
  exit 1
fi

# Preflight: reject values files still carrying the chart 0.15 schema. init-values.sh
# only creates an addon file when it is missing, so a values directory generated on the
# 0.15 line keeps its stale copies and they get loaded here. The chart does reject them,
# but its error names the key, not the generated file that carries it.
_legacy_files=""
for _vf in "$VALUES_DIR"/*.yaml; do
  [[ -f "$_vf" ]] || continue
  if awk '
      /^[A-Za-z_]/ { top = $1; sub(":", "", top) }
      top == "config"  && /^  (insights|polly):/ { found = 1 }
      top == "backend" && /^  agentBootstrap:/   { found = 1 }
      END { exit !found }
    ' "$_vf"; then
    _legacy_files+="         $(basename "$_vf")
"
  fi
done
if [[ -n "$_legacy_files" ]]; then
  echo "ERROR: these values files use the chart 0.15 schema, which chart 0.16 rejects:" >&2
  printf '%s' "$_legacy_files" >&2
  echo "       config.insights, config.polly and backend.agentBootstrap were removed." >&2
  echo "       init-values.sh only creates an addon file when it is missing, so delete the" >&2
  echo "       files listed above and re-run 'make init-values' to regenerate them." >&2
  exit 1
fi

# Same trap, different keys: a values directory written while SmithDB still had
# its own node pools keeps selecting smithdb-local/instance-store and
# smithdb-local/compute. Those pools no longer exist, so every SmithDB pod stays
# Pending on "node(s) didn't match Pod's node affinity/selector" and nothing in
# the chart or the scheduler names the file that asked for them. The chart
# accepts the keys, which is what makes this worth catching here.
_stale_pool_files=""
for _vf in "$VALUES_DIR"/*.yaml; do
  [[ -f "$_vf" ]] || continue
  if grep -q 'smithdb-local/' "$_vf" 2>/dev/null; then
    _stale_pool_files+="         $(basename "$_vf")
"
  fi
done
if [[ -n "$_stale_pool_files" ]]; then
  echo "ERROR: these values files schedule SmithDB onto node pools that no longer exist:" >&2
  printf '%s' "$_stale_pool_files" >&2
  echo "       The smithcache and smithcompute pools were removed when the SmithDB cache" >&2
  echo "       moved to per-pod Premium SSD v2 volumes, so a smithdb-local/* nodeSelector" >&2
  echo "       now matches no node and leaves every SmithDB pod Pending." >&2
  echo "       Delete the files listed above and re-run 'make init-values'." >&2
  exit 1
fi

# ── Pending-upgrade guard ─────────────────────────────────────────────────
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
if [[ "$_release_status" == "pending-upgrade" ]]; then
  warn "Helm release '${RELEASE_NAME}' is in 'pending-upgrade' state (interrupted upgrade)."
  info "Rolling back to clear the lock..."
  helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
  echo ""
elif [[ "$_release_status" == "failed" ]]; then
  warn "Helm release '${RELEASE_NAME}' is in 'failed' state."
  info "This is usually caused by a hook timeout — proceeding with upgrade."
  echo ""
fi

# ── Pre-deploy: Envoy Gateway EnvoyProxy + GatewayClass + Gateway ────────
# Must exist before helm install so the chart's gateway.enabled: true passes
# chart validation (validate.yaml requires ingress, gateway, or istioGateway).
# HTTPRoutes are created by the chart (gateway.enabled: true) — not by deploy.sh.
# Envoy Gateway creates the proxy LoadBalancer Service from the Gateway, with
# the annotations the GatewayClass's EnvoyProxy lists, so the DNS label is on
# the Service from the start and the HTTP-01 challenge can resolve it.
if [[ "$_ingress_controller" == "envoy-gateway" ]]; then
  _eg_namespace="$NAMESPACE"
  _eg_hostname="${_dns_label}.${_location}.${_cloudapp_suffix}"
  _eg_domain=$(_parse_tfvar "langsmith_domain") || _eg_domain=""
  [[ -n "$_eg_domain" ]] && _eg_hostname="$_eg_domain"
  if [[ "$_tls_source" != "none" && -z "$_dns_label" && -z "$_eg_domain" ]]; then
    fail "tls_certificate_source = \"${_tls_source}\" needs a hostname for the HTTPS listener: set dns_label or langsmith_domain in terraform.tfvars."
    exit 1
  fi

  _eg_service_annotations="{}"
  [[ -n "$_dns_label" ]] && _eg_service_annotations="{service.beta.kubernetes.io/azure-dns-label-name: \"${_dns_label}\"}"
  # Internal: the annotations Terraform puts on the nginx and Istio Services,
  # from its output. It prints a one-line JSON object, which is YAML flow
  # syntax. dns_label is refused with "internal", so the two never combine.
  if [[ "$_ingress_lb" == "internal" ]]; then
    _eg_service_annotations=$(terraform -chdir="$INFRA_DIR" output -json ingress_internal_annotations 2>/dev/null) || _eg_service_annotations=""
    if [[ "$_eg_service_annotations" != "{"*"azure-load-balancer-internal"*"}" ]]; then
      fail "ingress_load_balancer = \"internal\" but the ingress_internal_annotations output does not carry it. Run make apply first."
      exit 1
    fi
  fi

  # With envoy_gateway_image_registry, the proxy pods pull from the mirror as
  # the controller does. _tf_out refuses the "/" and ":" of an image reference,
  # so that output is read and checked here.
  _eg_proxy_image=$(terraform -chdir="$INFRA_DIR" output -raw envoy_gateway_proxy_image 2>/dev/null) || _eg_proxy_image=""
  [[ "$_eg_proxy_image" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] || _eg_proxy_image=""
  _eg_registry=$(_parse_tfvar "envoy_gateway_image_registry") || _eg_registry=""
  if [[ -n "$_eg_registry" && -z "$_eg_proxy_image" ]]; then
    fail "envoy_gateway_image_registry is set, but the envoy_gateway_proxy_image output is empty or not an image reference, so the proxy pods would pull from docker.io. Run terraform apply in ${INFRA_DIR}, then rerun."
    exit 1
  fi
  _eg_pull_secret=$(_tf_out envoy_gateway_image_pull_secret_name) || _eg_pull_secret=""
  _eg_deployment=""
  if [[ -n "$_eg_proxy_image" ]]; then
    info "Envoy proxy image: ${_eg_proxy_image}"
    _eg_deployment="
      envoyDeployment:
        container:
          image: \"${_eg_proxy_image}\""
    if [[ -n "$_eg_pull_secret" ]]; then
      _eg_deployment+="
        pod:
          imagePullSecrets:
          - name: \"${_eg_pull_secret}\""
    fi
  fi

  kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: langsmith-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        annotations: ${_eg_service_annotations}${_eg_deployment}
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: langsmith-eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: langsmith-proxy
    namespace: envoy-gateway-system
EOF

  # Build Gateway listeners — always include HTTP; add HTTPS only when TLS is enabled.
  # cert-manager issues langsmith-tls from the Gateway's annotation for letsencrypt
  # and dns01; with existing, the operator supplies that Secret.
  _eg_gateway_annotations=""
  if [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "dns01" ]]; then
    _eg_gateway_annotations='
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"'
  fi
  if [[ "$_tls_source" == "none" ]]; then
    kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${_eg_namespace}
spec:
  gatewayClassName: langsmith-eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
EOF
  else
    kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${_eg_namespace}${_eg_gateway_annotations}
spec:
  gatewayClassName: langsmith-eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "${_eg_hostname}"
    tls:
      mode: Terminate
      certificateRefs:
      - name: langsmith-tls
    allowedRoutes:
      namespaces:
        from: Same
EOF
  fi
  pass "Envoy Gateway EnvoyProxy + GatewayClass + Gateway created (tls: ${_tls_source})"
fi

# ── Deploy ────────────────────────────────────────────────────────────────
info "Deploying LangSmith (sizing: ${_sizing_profile})..."
info "(waiting for pods — 5-15 min on a cold cluster)"
echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain &>/dev/null
_resolved_chart=$(helm show chart "$_chart_source" --version "$CHART_VERSION" ${_devel_flag:-} 2>/dev/null \
  | awk '/^version:/{print $2}') || _resolved_chart=""
echo "Chart: $_chart_source  requested=${CHART_VERSION}  resolved=${_resolved_chart:-UNRESOLVED}"
if [[ -z "$_resolved_chart" ]]; then
  echo "ERROR: no chart matches '$CHART_VERSION' in the langchain repo." >&2
  exit 1
fi

# --server-side is a Helm 4 flag. Helm 3 has no server-side apply and rejects the
# whole invocation with "unknown flag: --server-side" (verified on v3.21.4), so
# passing it unconditionally blocks the deploy on the Helm 3 the docs require.
# On Helm 4, SSA is the default for a fresh install, which is what this module
# does. The chart was written and tested against client-side apply, so ask for it
# explicitly rather than let the Helm binary decide the apply semantics. Helm 3
# only ever applies client-side, making the flag redundant as well as unsupported.
# If the version cannot be read, omit it: omitting is valid on both majors,
# passing it fails outright on one.
_helm_major=$(helm version --template '{{.Version}}' 2>/dev/null | sed -e 's/^v//' -e 's/[^0-9].*$//') || _helm_major=""
_ssa_flag=""
if [[ -z "$_helm_major" ]]; then
  echo "WARNING: could not read the Helm version; omitting --server-side=false." >&2
elif [[ "$_helm_major" -ge 4 ]]; then
  _ssa_flag="--server-side=false"
fi

helm upgrade --install "$RELEASE_NAME" "$_chart_source" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --version "$CHART_VERSION" \
  "${VALUES_ARGS[@]}" \
  ${EXTRA_HELM_ARGS:+$EXTRA_HELM_ARGS} \
  ${_ssa_flag} \
  --timeout 20m

echo ""
pass "LangSmith deployed. Waiting for core pods..."
echo ""

# ── Wait for core components ──────────────────────────────────────────────
_core_deployments=(
  "${CHART_FULLNAME}-frontend"
  "${CHART_FULLNAME}-backend"
  "${CHART_FULLNAME}-platform-backend"
  "${CHART_FULLNAME}-ingest-queue"
  "${CHART_FULLNAME}-queue"
  # The chart always installs playground. Without it here, a sizing profile that
  # leaves playground crash-looping still reports "All core deployments ready" (#217).
  "${CHART_FULLNAME}-playground"
)
if [[ "$_enable_deployments" == "true" ]]; then
  _core_deployments+=(
    "${CHART_FULLNAME}-host-backend"
    "${CHART_FULLNAME}-listener"
    "${CHART_FULLNAME}-operator"
  )
fi

_all_ready=true
for dep in "${_core_deployments[@]}"; do
  if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    warn "$dep not ready within 5m (may still be starting)"
    _all_ready=false
  fi
done

if [[ "$_all_ready" == "true" ]]; then
  pass "All core deployments ready"
else
  warn "Some deployments are still rolling out — check with: kubectl get pods -n $NAMESPACE"
fi
echo ""

# ── Post-deploy Envoy Gateway: LoadBalancer IP ────────────────────────────
# The EnvoyProxy (pre-deploy block above) put the DNS label on the proxy Service;
# this only reports the address Azure gave it.
if [[ "$_ingress_controller" == "envoy-gateway" ]]; then
  info "Waiting for Envoy Gateway LoadBalancer IP..."
  _eg_ip=""
  for _ in $(seq 1 30); do
    _eg_ip=$(kubectl get svc -n "envoy-gateway-system" \
      -l "gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway,gateway.envoyproxy.io/owning-gateway-namespace=${NAMESPACE}" \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$_eg_ip" ]] && break
    sleep 5
  done

  if [[ -n "$_eg_ip" ]]; then
    pass "Envoy Gateway LoadBalancer IP: ${_eg_ip}${_dns_label:+ (${_dns_label}.${_location}.${_cloudapp_suffix})}"
  else
    warn "Envoy Gateway LoadBalancer has no IP yet. Check: kubectl get gateway langsmith-gateway -n ${NAMESPACE}"
  fi

  # A deployment moved off ingress-nginx still has the langsmith-tls Certificate
  # its Ingress owned, and cert-manager's gateway-shim refuses to take it over.
  # The helm upgrade above removed that Ingress, so garbage collection deletes
  # the Certificate, and the shim does not retry on its own: the Secret keeps
  # serving until it expires, and nothing renews it. Touching the Gateway makes
  # the shim re-sync and create a Certificate the Gateway owns.
  if [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "dns01" ]]; then
    _eg_cert_owner=""
    for _ in $(seq 1 24); do
      _eg_cert_owner=$(kubectl get certificate langsmith-tls -n "$NAMESPACE" \
        -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "none")
      [[ "$_eg_cert_owner" == "Ingress" ]] || break
      sleep 5
    done
    case "$_eg_cert_owner" in
      Gateway) ;;
      Ingress)
        warn "Certificate langsmith-tls is still owned by the old Ingress, so it will not renew."
        action "Re-run make deploy once kubectl get ingress -n ${NAMESPACE} shows no langsmith Ingress"
        ;;
      *)
        kubectl annotate gateway langsmith-gateway -n "$NAMESPACE" --overwrite \
          "langsmith.com/cert-resync=$(date +%s)" >/dev/null
        pass "Asked cert-manager to re-create Certificate langsmith-tls for the Gateway"
        ;;
    esac
  fi
fi

# ── Post-deploy self-managed Istio TLS sync ───────────────────────────────
# istiod reads the TLS secret via SDS using kubernetes:// scheme.
# For self-managed Istio, the secret must exist in istio-system namespace
# (the gateway pod namespace) — istiod serves it to the gateway via ADS/SDS.
# Without this sync, the gateway returns "no peer certificate available".
# Every TLS source but "none" leaves langsmith-tls in the release namespace.
if [[ "$_ingress_controller" == "istio" && "$_tls_source" != "none" ]]; then
  _istio_ns="$NAMESPACE"
  info "Waiting for TLS certificate langsmith-tls in ${_istio_ns}..."
  _cert_ready=false
  for _ in $(seq 1 18); do
    if kubectl get secret langsmith-tls -n "$_istio_ns" &>/dev/null 2>&1; then
      _cert_ready=true; break
    fi
    sleep 10
  done
  if [[ "$_cert_ready" == "true" ]]; then
    kubectl get secret langsmith-tls -n "$_istio_ns" -o json 2>/dev/null | \
      python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'istio-system'
for k in ['resourceVersion','uid','creationTimestamp']:
    s['metadata'].pop(k, None)
s['metadata']['annotations'] = {}
print(json.dumps(s))
" | kubectl apply -f - &>/dev/null
    pass "TLS secret synced to istio-system namespace"
  else
    warn "TLS certificate not ready within 3 min — sync skipped. Re-run: make deploy"
  fi
fi

# ── Post-deploy TLS sync (istio-addon only) ───────────────────────────────
# After cert-manager issues the TLS cert, copy it to aks-istio-ingress namespace
# so the Gateway can load it via SDS (credentialName lookup uses gateway pod namespace).
# The VirtualService is managed by the Helm chart (istioGateway.enabled: true in values).
# Same hostname gate as the Gateway above; skipped for "none", which has no Secret.
if [[ "$_ingress_controller" == "istio-addon" && ( -n "$_dns_label" || -n "$_langsmith_domain" ) && "$_tls_source" != "none" ]]; then
  _namespace="$NAMESPACE"

  info "Waiting for TLS certificate langsmith-tls..."
  _cert_ready=false
  for _ in $(seq 1 18); do
    if kubectl get secret langsmith-tls -n "$_namespace" &>/dev/null 2>&1; then
      _cert_ready=true
      break
    fi
    sleep 10
  done

  if [[ "$_cert_ready" == "true" ]]; then
    # Sync TLS secret to aks-istio-ingress namespace (required for Gateway credentialName)
    kubectl get secret langsmith-tls -n "$_namespace" -o json 2>/dev/null | \
      python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'aks-istio-ingress'
for k in ['resourceVersion','uid','creationTimestamp']:
    s['metadata'].pop(k, None)
s['metadata']['annotations'] = {}
print(json.dumps(s))
" | kubectl apply -f - &>/dev/null
    pass "TLS secret synced to aks-istio-ingress namespace"
  else
    warn "TLS certificate not ready within 3 min — sync skipped. Re-run: make deploy"
  fi
fi

# ── Ensure langsmith-ksa carries the WI annotation ───────────────────────
# langsmith-ksa is used by operator-spawned agent deployment pods.
# It is created by the operator on first use (not part of Helm release).
_wi_client_id=$(_tf_out storage_account_k8s_managed_identity_client_id || true)
if [[ -n "$_wi_client_id" ]]; then
  kubectl create serviceaccount langsmith-ksa -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
  kubectl annotate serviceaccount langsmith-ksa -n "$NAMESPACE" \
    azure.workload.identity/client-id="$_wi_client_id" --overwrite &>/dev/null
  pass "langsmith-ksa WI annotation: ${_wi_client_id}"
fi

# ── LLM Gateway: an Ingress of its own for /gateway/ ─────────────────────
# The chart's frontend allows 900 s on /gateway/ for long model calls, but
# ingress-nginx cuts at 60 s and Application Gateway at 30 s. Raising that on the
# chart's Ingress would raise it for every path, so /gateway/ gets a second
# Ingress, built from the chart's (same class, host, TLS and backend), carrying
# the longer timeout; every other path keeps the controller default. Istio has no
# default request timeout. For envoy-gateway, init-values.sh warns. With the
# gateway off, a leftover one is removed.
_chart_fullname="$RELEASE_NAME"
[[ "$RELEASE_NAME" == *langsmith* ]] || _chart_fullname="${RELEASE_NAME}-langsmith"
_gw_ingress="${_chart_fullname}-llm-gateway"
if [[ "$_enable_llm_gateway" == "true" && ( "$_ingress_controller" == "nginx" || "$_ingress_controller" == "agic" ) ]]; then
  if _chart_ingress_json=$(kubectl get ingress "${_chart_fullname}-ingress" -n "$NAMESPACE" -o json 2>/dev/null); then
    if printf '%s' "$_chart_ingress_json" \
        | python3 "$SCRIPT_DIR/llm-gateway-ingress.py" --controller "$_ingress_controller" --name "$_gw_ingress" \
        | kubectl apply -f - >/dev/null; then
      pass "LLM Gateway Ingress ${_gw_ingress}: /gateway/ with a 900 s timeout (${_ingress_controller})"
    else
      warn "Could not apply Ingress ${_gw_ingress}; gateway calls use the controller's default timeout. Re-run: make deploy"
    fi
  else
    warn "Ingress ${_chart_fullname}-ingress not found, so ${_gw_ingress} was not created; gateway calls use the controller's default timeout"
  fi
elif kubectl get ingress "$_gw_ingress" -n "$NAMESPACE" &>/dev/null; then
  kubectl delete ingress "$_gw_ingress" -n "$NAMESPACE" >/dev/null && pass "Removed Ingress ${_gw_ingress} (enable_llm_gateway is off)"
fi

# ── Post-deploy access info ───────────────────────────────────────────────
_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
  | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
_kv_name=$(_tf_out keyvault_name || true)
_admin_email=$(_tf_out langsmith_admin_email || true)
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source="none"
_url_protocol="http"
[[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "dns01" || "$_tls_source" == "existing" ]] && _url_protocol="https"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith deployed"
echo "══════════════════════════════════════════════════════"
echo ""
[[ -n "$_hostname" ]] && echo "  URL      : ${_url_protocol}://${_hostname}"
[[ -n "$_admin_email" ]] && echo "  Login    : ${_admin_email}"
[[ -n "$_kv_name" ]] && echo "  Password : az keyvault secret show --vault-name ${_kv_name} --name langsmith-admin-password --query value -o tsv"
echo ""
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get ingress -n ${NAMESPACE}"
echo "  kubectl get certificate -n ${NAMESPACE}"
echo ""
echo "  make status   # for a full health check"
echo ""
