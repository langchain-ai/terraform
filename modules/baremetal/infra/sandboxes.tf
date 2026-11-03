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

resource "terraform_data" "sandboxes" {
  input = { sandboxes = var.enable_sandboxes, hosts = var.sandbox_hosts, engine = var.enable_engine }

  lifecycle {
    precondition {
      condition     = length(module.values.problems.sandboxes) == 0
      error_message = "Sandboxes: ${join("; ", module.values.problems.sandboxes)}."
    }
  }
}

# The JuiceFS configuration the chart's format Job and sandbox-host read
# (docs: "Use S3-compatible object storage"; static keys, app 0.17.35+).
resource "kubernetes_secret_v1" "sandbox_juicefs" {
  count = var.enable_sandboxes ? 1 : 0
  metadata {
    name      = module.values.secret_names.juicefs
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    name         = module.values.juicefs_bucket
    metaurl      = "redis://:${local.redis.juicefs.password}@${local.redis.juicefs.host}:${local.redis.juicefs.port}/0"
    storage      = "s3"
    bucket       = "${module.values.rustfs.endpoint}/${module.values.juicefs_bucket}"
    "access-key" = local.rustfs_keys.access_key
    "secret-key" = local.rustfs_keys.secret_key
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
