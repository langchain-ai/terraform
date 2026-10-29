#------------------------------------------------------------------------------
# Sandboxes and Engine, named as modules/aws names them (enable_sandboxes,
# enable_engine), on any cluster.
#
# Sandboxes run Firecracker microVMs in a privileged sandbox-host pod on each
# node in sandbox_hosts: amd64 with /dev/kvm, /dev/net/tun and /dev/fuse, cgroup
# v2, and local disk for the JuiceFS cache (docs enable-self-hosted-sandboxes,
# "Node requirements for bare-metal and on-premises clusters"). Their shared
# filesystem is JuiceFS: metadata in a Redis of its own (AOF, noeviction:
# durable, unlike the queue Redis) and data in a bucket on the same RustFS.
# The module labels and taints the sandbox nodes itself, so the same inputs work
# on any cluster, whether or not the module installed its add-ons.
#
# Engine runs its analysis in those sandboxes, on the deployment it shares with
# Insights, and needs a TLS hostname the sandboxes can reach (the chart rejects
# localhost and in-cluster addresses) and the Engine entitlement in the licence
# (docs engine-self-hosted).
#------------------------------------------------------------------------------

variable "enable_sandboxes" {
  type        = bool
  default     = false
  description = "Sandboxes on the nodes in sandbox_hosts. Needs the Sandboxes entitlement and app version 0.17.35 or later for S3-compatible storage with static keys."
}

variable "sandbox_hosts" {
  type        = list(string)
  default     = []
  description = "cluster_nodes that run sandboxes: amd64 with KVM, TUN and FUSE. Each is labelled and tainted sandbox.langsmith.com/host=true and runs one sandbox-host pod."
}

variable "sandbox_source_cidrs" {
  type        = list(string)
  default     = []
  description = "Where sandbox-host's traffic to the JuiceFS Redis and RustFS comes from. It runs on the host network, so the datastores' namespace policies do not match it: the nodes' addresses, and on flannel (k3s) the pod CIDR too, since a host-network pod reaches a remote pod from the node's flannel address."
}

variable "sandbox_juicefs_cache_gi" {
  type        = number
  default     = 50
  description = "JuiceFS cache per sandbox node, on node-local disk (the chart's default, --cache-size=51200)."
}

variable "enable_engine" {
  type        = bool
  default     = false
  description = "LangSmith Engine on the shared Insights deployment. Needs enable_sandboxes, the Engine entitlement, and https with langsmith_domain."
}

variable "engine_sandbox_tenant_id" {
  type        = string
  default     = ""
  description = "Workspace for Engine's sandboxes. Required when the install has more than one shared organization; a workspace reserved for Engine is recommended."
}

variable "engine_intelligence_base_url" {
  type        = string
  default     = "https://beacon.langchain.com/intelligence"
  description = "Where Engine runs its models: https://beacon.aws.langchain.com/intelligence for LangSmith Intelligence, the default for your own providers, \"\" when air-gapped."
}

# Engine through the customer's own LLM gateway (docs engine-self-hosted-model-providers, "Use a model
# gateway"; chart 0.17.31 or later). Set the URL of each API the gateway serves; make setup-env asks its key.
variable "engine_gateway_anthropic_base_url" {
  type        = string
  default     = ""
  description = "The base URL an Anthropic SDK would use for your gateway; Engine calls <url>/v1/messages. HTTPS, with no redirect. Empty: Engine does not use the gateway's Anthropic API."
}

variable "engine_gateway_openai_base_url" {
  type        = string
  default     = ""
  description = "The base URL an OpenAI SDK would use for your gateway, usually ending in /v1; Engine calls <url>/responses. HTTPS, with no redirect. Empty: Engine does not use the gateway's OpenAI API."
}

variable "engine_gateway_auth_header" {
  type        = string
  default     = ""
  description = "The header your gateway reads its key from, such as x-api-key. Empty: Engine sends Authorization: Bearer <key>."
}

locals {
  juicefs_bucket = "sandbox-juicefs"
  # The JuiceFS Redis's 256Mi is a floor, unmeasured: size it from the first sandbox load test.
  juicefs_size = { cpu_m = 100, mem_mi = 256, lim_cpu_m = 1000, lim_mem_mi = 1024, storage_gi = 5 }

  sandbox_problems = compact([
    var.enable_sandboxes && length(var.sandbox_hosts) == 0 ? "enable_sandboxes needs sandbox_hosts" : "",
    length([for h in var.sandbox_hosts : h if !contains(keys(var.cluster_nodes), h)]) > 0 ? "sandbox_hosts must all be in cluster_nodes" : "",
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
        existingSecretName = kubernetes_secret_v1.sandbox_juicefs[0].metadata[0].name
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

resource "terraform_data" "sandboxes" {
  input = { sandboxes = var.enable_sandboxes, hosts = var.sandbox_hosts, engine = var.enable_engine }

  lifecycle {
    precondition {
      condition     = length(local.sandbox_problems) == 0
      error_message = "Sandboxes: ${join("; ", local.sandbox_problems)}."
    }
  }
}

module "redis_juicefs" {
  source = "./modules/redis"
  count  = var.enable_sandboxes ? 1 : 0

  namespace          = "redis-juicefs"
  image              = var.redis_image
  persistence        = "aof"
  storage_size       = local.datastores_k8s.redis_juicefs.storage
  storage_class      = local.storage_class_retain
  resources          = { requests = local.datastores_k8s.redis_juicefs.requests, limits = local.datastores_k8s.redis_juicefs.limits }
  memory_limit_mi    = local.datastores.redis_juicefs.lim_mem_mi
  allowed_namespaces = [kubernetes_namespace_v1.langsmith.metadata[0].name]
  allowed_cidrs      = var.sandbox_source_cidrs
  datastore_label    = local.datastore_label

  depends_on = [terraform_data.budget, terraform_data.sandboxes, kubernetes_node_taint.sandbox_host]
}

# The JuiceFS configuration the chart's format Job and sandbox-host read
# (docs: "Use S3-compatible object storage"; static keys, app 0.17.35+).
resource "kubernetes_secret_v1" "sandbox_juicefs" {
  count = var.enable_sandboxes ? 1 : 0
  metadata {
    name      = "langsmith-sandbox-juicefs"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    name         = local.juicefs_bucket
    metaurl      = "redis://:${module.redis_juicefs[0].password}@${module.redis_juicefs[0].host}:6379/0"
    storage      = "s3"
    bucket       = "${module.rustfs_smithdb.endpoint}/${local.juicefs_bucket}"
    "access-key" = module.rustfs_smithdb.access_key
    "secret-key" = module.rustfs_smithdb.secret_key
  }
  type = "Opaque"
}

resource "kubernetes_labels" "sandbox_host" {
  for_each    = var.enable_sandboxes ? toset(var.sandbox_hosts) : toset([])
  api_version = "v1"
  kind        = "Node"
  metadata {
    name = each.key
  }
  labels = { "sandbox.langsmith.com/host" = "true" }
  # Its own field manager. Under the provider's default, Terraform, the label and the taint below were one
  # owner of the Node under server-side apply, and each apply dropped the other's field: every plan
  # re-added the label and every apply changed both (reed-lab, 2026-10-29).
  field_manager = "langsmith-sandbox-label"
}

resource "kubernetes_node_taint" "sandbox_host" {
  for_each = var.enable_sandboxes ? toset(var.sandbox_hosts) : toset([])
  # A Node's taints are one atomic list, owned by whoever wrote it last: the kubelet registering the
  # node (field manager k3s on k3s). Without force the apply stops on that conflict (reed-lab, 2026-10-29).
  force         = true
  field_manager = "langsmith-sandbox-taint"
  metadata {
    name = each.key
  }
  taint {
    key    = "sandbox.langsmith.com/host"
    value  = "true"
    effect = "NoSchedule"
  }
}
