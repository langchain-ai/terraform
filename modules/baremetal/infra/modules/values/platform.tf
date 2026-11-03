#------------------------------------------------------------------------------
# What the values need from the platform the root installs or is given: the
# StorageClasses every volume takes and the Gateway the chart's HTTPRoutes
# attach to. The root's local-path and Envoy Gateway modules are given these
# names, so they are named once.
#------------------------------------------------------------------------------

locals {
  storage_classes = {
    delete = var.install_local_path ? "local-path" : var.storage_class
    retain = var.install_local_path ? "local-path-retain" : var.storage_class
  }
  gateway = var.install_envoy_gateway ? { name = "langsmith-gateway", namespace = local.namespace } : var.existing_gateway

  platform_problems = compact([
    !var.install_local_path && var.storage_class == "" ? "install_local_path = false needs storage_class" : "",
    !var.install_envoy_gateway && var.existing_gateway == null ? "install_envoy_gateway = false needs existing_gateway" : "",
    # The URL falls back to the gateway IP, which only our MetalLB serves; an empty hostname renders an HTTPRoute the API server refuses.
    !(var.install_metallb && var.install_envoy_gateway) && var.langsmith_domain == "" ? "without this module's MetalLB and Envoy Gateway, set langsmith_domain: the gateway's address is not ours to name" : "",
    var.install_metallb && length(var.metallb_addresses) == 0 ? "install_metallb needs metallb_addresses" : "",
    var.install_envoy_gateway && var.install_metallb && var.envoy_gateway_lb_ip == "" ? "envoy_gateway_lb_ip is required when this module installs both MetalLB and Envoy Gateway" : "",
    var.gateway_tls_secret != "" && !var.install_envoy_gateway ? "gateway_tls_secret is for this module's Envoy Gateway: on existing_gateway, TLS is that Gateway's" : "",
    var.gateway_tls_secret != "" && (var.langsmith_domain == "" || var.langsmith_url_scheme != "https") ? "gateway_tls_secret needs langsmith_domain and langsmith_url_scheme = https" : "",
  ])

  # The values files helm/scripts/deploy.sh hands Helm, in order (last wins), by their names under
  # helm/values/: the base, the three Terraform writes (overrides, admin, SmithDB), the profile's
  # sizing, each enabled feature's (the order of modules/gcp), then SSO. deploy.sh adds the optional
  # langsmith-values-local.yaml last. One list, so a tool layering the same files cannot drift from it.
  values_files = concat(
    ["values.yaml", "langsmith-values-overrides.yaml", "langsmith-values-admin.yaml", "langsmith-values-sizing-${var.sizing_profile}.yaml"],
    var.enable_deployments ? ["langsmith-values-agent-deploys.yaml"] : [],
    var.enable_fleet ? ["langsmith-values-fleet.yaml"] : [],
    contains(keys(local.standalone_features), "polly") ? ["langsmith-values-standalone-polly.yaml"] : [],
    contains(keys(local.standalone_features), "insights") ? ["langsmith-values-standalone-insights.yaml"] : [],
    var.enable_sso_oidc ? ["langsmith-values-sso.yaml"] : [],
    ["langsmith-values-smithdb.yaml"],
  )
}
