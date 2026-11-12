#------------------------------------------------------------------------------
# Sandboxes and Engine (the root's sandboxes.tf has the inputs, the node labels
# and taints, and the JuiceFS Secret).
#------------------------------------------------------------------------------

locals {
  juicefs_bucket = "sandbox-juicefs"
  # The JuiceFS Redis runs in charts/datastores with the other stores, sized in datastore-sizes.yaml.

  sandbox_problems = compact([
    var.enable_sandboxes && length(var.sandbox_hosts) == 0 ? "enable_sandboxes needs sandbox_hosts" : "",
    length([for h in var.sandbox_hosts : h if !contains(keys(var.cluster_nodes), h)]) > 0 ? "sandbox_hosts must all be in cluster_nodes" : "",
    length([for h in var.sandbox_hosts : h if contains(keys(local.smithdb_dedicated_nodes), h)]) > 0 ? "a sandbox host cannot also be a dedicated SmithDB node: each taint owns the node's whole taint list, so the two would overwrite each other on every apply" : "",
    var.enable_sandboxes && length(var.sandbox_source_cidrs) == 0 ? "enable_sandboxes needs sandbox_source_cidrs: sandbox-host runs on the host network" : "",
    var.enable_engine && !var.enable_sandboxes ? "enable_engine needs enable_sandboxes: every Engine run executes in a sandbox" : "",
    var.enable_engine && var.langsmith_url_scheme != "https" ? "enable_engine needs langsmith_url_scheme = https with langsmith_domain: the sandboxes call LangSmith at a TLS hostname" : "",
    length(local.engine_gateway_apis) > 0 && !var.enable_engine ? "engine_gateway_*_base_url needs enable_engine" : "",
    length([for u in [var.engine_gateway_anthropic_base_url, var.engine_gateway_openai_base_url] : u if u != "" && !startswith(u, "https://")]) > 0 ? "engine_gateway_*_base_url must start with https://: Engine follows no redirect" : "",
  ])

  engine_gateway_apis = compact([
    var.engine_gateway_anthropic_base_url != "" ? "anthropic" : "",
    var.engine_gateway_openai_base_url != "" ? "openai" : "",
  ])
  engine_gateway = var.enable_engine && length(local.engine_gateway_apis) > 0
  # Both Engine workloads get the URLs and the key, mounted from the Secret deploy.sh makes. Engine reads
  # the file at the start of each run, so a rotated key needs no restart. Through JSON: Terraform will
  # not unify this object with {} in a conditional.
  engine_gateway_deployment = jsondecode(local.engine_gateway ? jsonencode({
    extraEnv = concat(
      var.engine_gateway_anthropic_base_url != "" ? [{ name = "ENGINE_GATEWAY_ANTHROPIC_BASE_URL", value = var.engine_gateway_anthropic_base_url }] : [],
      var.engine_gateway_openai_base_url != "" ? [{ name = "ENGINE_GATEWAY_OPENAI_BASE_URL", value = var.engine_gateway_openai_base_url }] : [],
      [{ name = "ENGINE_GATEWAY_API_KEY_FILE", value = "/etc/engine-gateway/api-key" }],
      var.engine_gateway_auth_header != "" ? [{ name = "ENGINE_GATEWAY_AUTH_HEADER", value = var.engine_gateway_auth_header }] : [],
    )
    volumes      = [{ name = "engine-gateway", secret = { secretName = "engine-model-gateway" } }]
    volumeMounts = [{ name = "engine-gateway", mountPath = "/etc/engine-gateway", readOnly = true }]
  }) : "{}")
  # On every component: LangSmith shows Model gateway in Engine's settings only when this is set.
  engine_gateway_env = local.engine_gateway ? [{ name = "ENGINE_GATEWAY_APIS", value = jsonencode(local.engine_gateway_apis) }] : []

  # Pods the budget adds: one sandbox-host per sandbox node at the chart's requests, with its JuiceFS cache on that node's disk.
  sandbox_nodes = var.enable_sandboxes ? var.sandbox_hosts : []
  sandbox_pods = var.enable_sandboxes ? [{
    name     = "sandboxes/sandbox-host"
    pool     = "sandbox"
    replicas = length(var.sandbox_hosts)
    cpu      = "2"   # chart 0.17.26 sandboxes.sandboxHost.deployment.resources.requests
    memory   = "2Gi" # same
    disk     = "${var.sandbox_juicefs_cache_gi}Gi"
  }] : []

  sandbox_values = var.enable_sandboxes ? {
    sandboxes = {
      enabled = true
      juicefs = {
        name               = local.juicefs_bucket
        existingSecretName = local.secret_names.juicefs
        hostMount          = { mountOptions = ["--cache-size=${var.sandbox_juicefs_cache_gi * 1024}", "--cache-large-write"] }
      }
      sandboxHost = {
        deployment = {
          replicas     = length(var.sandbox_hosts)
          nodeSelector = { "kubernetes.io/arch" = "amd64", "sandbox.langsmith.com/host" = "true" }
        }
      }
    }
  } : {}

  engine_values = var.enable_engine ? {
    engine = merge(
      { enabled = true, intelligenceBaseUrl = var.engine_intelligence_base_url },
      var.engine_sandbox_tenant_id != "" ? { sandboxTenantId = var.engine_sandbox_tenant_id } : {},
    )
  } : {}
}
