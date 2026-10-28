#------------------------------------------------------------------------------
# Inputs for the bare-metal root module, grouped by concern: cluster access,
# declared node capacity (for the budget gate), sizing, LangSmith features,
# platform add-ons, the optional Cloudflare Tunnel, pinned images and the
# LangSmith hostname. Set them in terraform.tfvars; terraform.tfvars.example
# lists every one with an example value. No secrets here except the tunnel
# token, which is marked sensitive and should come from TF_VAR_.
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# Cluster access
#------------------------------------------------------------------------------
variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Path to the kubeconfig for the target cluster."
}

variable "kube_context" {
  type        = string
  description = "Context in kubeconfig_path to deploy into. Required: never fall back to the current context."

  validation {
    condition     = length(trimspace(var.kube_context)) > 0
    error_message = "kube_context must name a context in kubeconfig_path."
  }
}

#------------------------------------------------------------------------------
# Cluster capacity (declared) — the budget check compares sizing to this
#------------------------------------------------------------------------------
variable "cluster_nodes" {
  type = map(object({
    cpu       = number
    memory_gi = number
    disk_gi   = number
    role      = optional(string, "worker")
  }))
  description = <<-EOT
    Nodes as Kubernetes sees them: allocatable CPU (cores), memory (GiB), and
    ephemeral storage (GiB) from `kubectl get nodes -o custom-columns=...`.
    Only role = "worker" nodes count toward the LangSmith budget.
    role = "smithdb-cache" / "smithdb-compute" dedicates nodes to SmithDB
    (labeled and tainted by Terraform), like the cloud modules' node pools.
    Map keys must be the Kubernetes node names.
  EOT

  validation {
    condition     = length([for n in values(var.cluster_nodes) : n if n.role == "worker"]) > 0
    error_message = "cluster_nodes needs at least one node with role = \"worker\"."
  }

  validation {
    condition     = alltrue([for n in values(var.cluster_nodes) : contains(["worker", "control-plane", "smithdb-cache", "smithdb-compute"], n.role)])
    error_message = "role must be one of: worker, control-plane, smithdb-cache, smithdb-compute."
  }
}

variable "node_reserved" {
  type = object({
    cpu       = number
    memory_gi = number
  })
  # Measured on a small reference cluster with metrics-server: an idle worker uses ~90m CPU
  # and ~1.6 Gi for the OS, kubelet, containerd, Calico, and kube-proxy, none
  # of which set requests. Memory is rounded up to 2 Gi.
  default = {
    cpu       = 0.5
    memory_gi = 2
  }
  description = "Held back per worker for the OS, kubelet, containerd, and the CNI (none of which set requests)."
}

variable "max_request_ratio" {
  type        = number
  default     = 0.7
  description = "Highest share of (worker capacity - node_reserved) that the sizing profile may request."

  validation {
    condition     = var.max_request_ratio > 0 && var.max_request_ratio <= 1
    error_message = "max_request_ratio must be greater than 0 and at most 1."
  }
}

#------------------------------------------------------------------------------
# Sizing
#------------------------------------------------------------------------------
variable "sizing_profile" {
  type        = string
  default     = "minimum"
  description = "LangSmith sizing profile: minimum | lab | dev | production | production-large."

  validation {
    condition     = contains(["minimum", "lab", "dev", "production", "production-large"], var.sizing_profile)
    error_message = "sizing_profile must be one of: minimum, lab, dev, production, production-large."
  }
}

#------------------------------------------------------------------------------
# Features (same flags as the cloud modules)
#------------------------------------------------------------------------------
variable "enable_deployments" {
  type        = bool
  default     = false
  description = "LangGraph Platform Deployments (host-backend, listener, operator). Requires the Deployments entitlement and a gateway."
}


variable "enable_fleet" {
  type        = bool
  default     = false
  description = "Fleet (replaces the legacy Agent Builder). Uses database langsmith_fleet on postgres-langsmith and Redis DB 1. Does not require enable_deployments."
}

variable "enable_standalone_insights" {
  type        = bool
  default     = false
  description = "Insights standalone deployment. Uses database langsmith_insights on postgres-langsmith and Redis DB 3."
}

variable "enable_standalone_polly" {
  type        = bool
  default     = false
  description = "Polly standalone deployment. Uses database langsmith_polly on postgres-langsmith and Redis DB 2."
}

variable "enable_sso_oidc" {
  type        = bool
  default     = false
  description = "SSO via OIDC (config only, no extra pods). Enable after the first admin login works."
}

variable "enable_usage_telemetry" {
  type        = bool
  default     = false
  description = "Extended usage telemetry reporting: sets PHONE_HOME_USAGE_REPORTING_ENABLED on every LangSmith component (commonEnv in langsmith-values-overrides.yaml)."
}

variable "enable_blob_storage" {
  type        = bool
  default     = true
  description = "Store large run payloads (inputs, outputs, events, errors) in a second RustFS bucket instead of Redis (chart config.blobStorage). Keeps Redis memory several times smaller for agent-sized traces."
}

variable "blob_storage_min_size_kb" {
  type        = number
  default     = 20
  description = "Payload parts at or above this size (KiB, as uploaded) go to blob storage; smaller ones stay in Redis. The chart default is 20."

  validation {
    condition     = var.blob_storage_min_size_kb >= 0 && floor(var.blob_storage_min_size_kb) == var.blob_storage_min_size_kb
    error_message = "blob_storage_min_size_kb must be a whole number of KiB, 0 or more."
  }
}

variable "blob_storage_ttl_days" {
  type        = object({ short = number, long = number })
  default     = { short = 14, long = 400 }
  description = "Days before the blob bucket deletes ttl_s/ (short-lived) and ttl_l/ (long-lived) payloads, as the cloud modules' lifecycle rules do. LangSmith expects the bucket to expire them; match the chart's config.ttl if you change it."

  validation {
    condition     = var.blob_storage_ttl_days.short >= 1 && var.blob_storage_ttl_days.long >= var.blob_storage_ttl_days.short
    error_message = "blob_storage_ttl_days: short must be at least 1 and long at least short."
  }
}

variable "expected_agent_deployments" {
  type        = number
  default     = 0
  description = "Agent deployments you expect to run. The operator creates their pods at runtime, so the budget reserves an estimate for each."

  validation {
    condition     = var.expected_agent_deployments >= 0 && var.expected_agent_deployments <= 20 && floor(var.expected_agent_deployments) == var.expected_agent_deployments
    error_message = "expected_agent_deployments must be a whole number from 0 to 20."
  }

  validation {
    condition     = var.expected_agent_deployments == 0 || var.enable_deployments
    error_message = "expected_agent_deployments > 0 requires enable_deployments = true."
  }
}

#------------------------------------------------------------------------------
# Platform add-ons
#------------------------------------------------------------------------------
variable "metrics_server_chart_version" {
  type        = string
  default     = "3.14.0"
  description = "metrics-server Helm chart version (kubernetes-sigs)."
}

variable "metrics_server_kubelet_insecure_tls" {
  type        = bool
  default     = true
  description = "Pass --kubelet-insecure-tls to metrics-server. Needed while kubelets use kubeadm's self-signed serving certs; set false after enabling serverTLSBootstrap."
}

variable "local_path_image" {
  type        = string
  default     = "docker.io/rancher/local-path-provisioner:v0.0.37"
  description = "local-path-provisioner image."
}

variable "local_path_helper_image" {
  type        = string
  default     = "docker.io/library/busybox:1.37.0"
  description = "Helper pod image used to create and delete volume directories."
}

variable "local_path_node_path" {
  type        = string
  default     = "/opt/local-path-provisioner"
  description = "Directory on each node for local-path volumes, the datastores' included. Put it on ext4 or XFS, or on a btrfs subvolume with copy-on-write off: on copy-on-write btrfs, RustFS's commits stall under load (TROUBLESHOOTING.md, Storage)."
}

variable "metallb_chart_version" {
  type        = string
  default     = "0.16.1"
  description = "MetalLB Helm chart version."
}

variable "metallb_addresses" {
  type        = list(string)
  description = "LoadBalancer IP pool for MetalLB (ranges a.b.c.d-a.b.c.e or CIDRs), outside the router's DHCP pool. Required with install_metallb."
  default     = []

  validation {
    condition = alltrue([
      for a in var.metallb_addresses :
      can(cidrhost(a, 0)) || can(regex("^\\d{1,3}(\\.\\d{1,3}){3}-\\d{1,3}(\\.\\d{1,3}){3}$", a))
    ])
    error_message = "Each metallb_addresses entry must be a CIDR (10.20.0.48/29) or a range (10.20.0.50-10.20.0.59)."
  }
}

variable "metallb_l2_node_selector" {
  type        = map(string)
  default     = {}
  description = "Nodes allowed to answer ARP for LoadBalancer IPs. Default {}: every node except those labeled node.kubernetes.io/exclude-from-external-load-balancers, which kubeadm puts on control-plane nodes. Set a label here only if your workers carry it (stock kubeadm, k3s and RKE2 don't label workers)."
}

variable "keda_chart_version" {
  type        = string
  default     = "2.21.0"
  description = "KEDA Helm chart version (https://kedacore.github.io/charts). Installed only with enable_deployments: the LangSmith operator scales agent deployments with KEDA ScaledObjects."
}

variable "envoy_gateway_chart_version" {
  type        = string
  default     = "v1.9.2"
  description = "Envoy Gateway Helm chart version (oci://docker.io/envoyproxy/gateway-helm)."
}

variable "envoy_gateway_lb_ip" {
  type        = string
  default     = ""
  description = "LAN IP pinned to the Envoy proxy LoadBalancer Service. MetalLB serves it from its own pool (autoAssign off), so it must be an unused address on the node subnet OUTSIDE metallb_addresses. Required when this module installs both MetalLB and Envoy Gateway (platform.tf)."

  validation {
    condition     = var.envoy_gateway_lb_ip == "" || can(regex("^\\d{1,3}(\\.\\d{1,3}){3}$", var.envoy_gateway_lb_ip))
    error_message = "envoy_gateway_lb_ip must be an IPv4 address."
  }
}

variable "envoy_gateway_route_timeout" {
  type        = string
  default     = "60s"
  description = "Request timeout on the LangSmith chart's route and the LAN route (Envoy BackendTrafficPolicy); Fleet and Deployments streams and the operator's agent routes have none. Envoy Gateway's default is 15 s, which returns 504 on slow trace reads. Empty string keeps the Envoy default."

  validation {
    condition     = var.envoy_gateway_route_timeout == "" || can(regex("^[0-9]+(ms|s|m|h)$", var.envoy_gateway_route_timeout))
    error_message = "envoy_gateway_route_timeout must be a duration like \"60s\" or \"2m\", or \"\" for the Envoy default."
  }
}

#------------------------------------------------------------------------------
# Cloudflare Tunnel (optional). Connector only: create the tunnel and its
# public hostname in the Cloudflare dashboard, then paste the token here.
#------------------------------------------------------------------------------
variable "enable_cloudflare_tunnel" {
  type        = bool
  default     = false
  description = "Run a cloudflared connector for a remotely-managed Cloudflare Tunnel. Outbound only: no port-forward, no inbound firewall rule."
}

variable "cloudflare_tunnel_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Tunnel token from Zero Trust → Networks → Tunnels. Prefer TF_VAR_cloudflare_tunnel_token over terraform.tfvars. Stored in Terraform state and in Secret cloudflared/cloudflared-token."

  validation {
    condition     = !var.enable_cloudflare_tunnel || length(trimspace(var.cloudflare_tunnel_token)) > 0
    error_message = "enable_cloudflare_tunnel = true needs cloudflare_tunnel_token (export TF_VAR_cloudflare_tunnel_token)."
  }
}

variable "cloudflared_image" {
  type        = string
  default     = "docker.io/cloudflare/cloudflared:2026.10.0"
  description = "cloudflared image, exact tag."
}

variable "postgres_image" {
  type        = string
  default     = "docker.io/library/postgres:18.6"
  description = "Postgres image for both instances (LangSmith and SmithDB metastore require 18+ for the metastore)."
}

variable "redis_image" {
  type        = string
  default     = "docker.io/library/redis:7.4.11"
  description = "Redis image (LangSmith supports Redis >= 6.2 or Valkey 8)."
}

variable "rustfs_image" {
  type        = string
  default     = "docker.io/rustfs/rustfs:1.0.1"
  description = "RustFS image (S3-compatible object storage, Apache 2.0). Replaces MinIO, whose community edition is unmaintained."
}

variable "aws_cli_image" {
  type        = string
  default     = "docker.io/amazon/aws-cli:2.37.8"
  description = "AWS CLI image for bucket-creation Jobs."
}
