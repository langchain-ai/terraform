# Dedicated SmithDB nodes, scaled independently by Cluster Autoscaler.
locals {
  # The sizing files set smithdb.resourceTier: production is Medium and
  # production-large is Large. Medium pods need m6a.8xlarge nodes and Large needs
  # m6a.16xlarge, whereas the node default fits the Small tier.
  smithdb_tier_min_xlarge = { production = 8, production-large = 16 }
  # The size multiple in the instance type: m6a.4xlarge is 4, and a type with no
  # number (xlarge, large) counts as 1. A metal type is always big enough.
  smithdb_node_xlarge = can(regex("\\.metal", var.smithdb_node_instance_type)) ? 1000 : try(tonumber(regex("\\.(\\d+)xlarge$", var.smithdb_node_instance_type)[0]), 1)

  smithdb_node_group = {
    name           = "node-group-smithdb"
    instance_types = [var.smithdb_node_instance_type]
    min_size       = var.smithdb_node_min_count
    desired_size   = var.smithdb_node_min_count
    max_size       = var.smithdb_node_max_count
    labels         = { "langsmith-nodepool/smithdb" = "true" }
    taints = {
      smithdb = { key = "langsmith-nodepool/smithdb", value = "true", effect = "NO_SCHEDULE" }
    }
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = var.smithdb_node_root_volume_size_gb
          volume_type           = "gp3"
          encrypted             = true
          delete_on_termination = true
        }
      }
    }
  }
}

variable "smithdb_node_instance_type" {
  type        = string
  description = "SmithDB EC2 instance type. The default, m6a.4xlarge, fits the Small tier. The Medium tier needs m6a.8xlarge nodes and the Large tier m6a.16xlarge. The module does not derive it from sizing_profile."
  default     = "m6a.4xlarge"
  nullable    = false

  validation {
    condition     = trimspace(var.smithdb_node_instance_type) != ""
    error_message = "smithdb_node_instance_type must be an EC2 instance type such as m6a.4xlarge."
  }
}

variable "smithdb_node_min_count" {
  type        = number
  description = "Minimum SmithDB nodes; at least 1 for Helm migration hooks."
  default     = 2

  validation {
    condition     = var.smithdb_node_min_count >= 1 && floor(var.smithdb_node_min_count) == var.smithdb_node_min_count
    error_message = "smithdb_node_min_count must be a whole number of at least 1."
  }
}

variable "smithdb_node_max_count" {
  type        = number
  description = "Maximum SmithDB nodes. Must exceed the minimum. Raise it for the Medium and Large tiers."
  default     = 5
  nullable    = false

  validation {
    condition     = var.smithdb_node_max_count > var.smithdb_node_min_count && floor(var.smithdb_node_max_count) == var.smithdb_node_max_count
    error_message = "smithdb_node_max_count must be a whole number greater than smithdb_node_min_count."
  }
}

resource "kubernetes_storage_class_v1" "smithdb_cache" {
  count = var.enable_smithdb ? 1 : 0

  metadata {
    name = "smithdb-cache"
  }
  storage_provisioner = "ebs.csi.aws.com"
  parameters = {
    type       = "gp3"
    iops       = "7000"
    throughput = "1000"
    encrypted  = "true"
  }
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"
  depends_on          = [module.eks]
}

output "smithdb_cache_storage_class_name" {
  description = "StorageClass for SmithDB per-pod caches."
  value       = var.enable_smithdb ? kubernetes_storage_class_v1.smithdb_cache[0].metadata[0].name : null
}

variable "smithdb_transition_mode" {
  type        = bool
  description = "Keep Karpenter while moving an existing SmithDB deployment to managed nodes. See ../SMITHDB.md for transition steps."
  default     = false

  validation {
    condition     = !var.smithdb_transition_mode || var.enable_smithdb
    error_message = "smithdb_transition_mode requires enable_smithdb = true."
  }
}

# A warning, not an error: Terraform cannot know the nodes' real capacity, but a
# profile whose tier is larger than the node type leaves pods Pending.
check "smithdb_nodes_fit_the_sizing_profile" {
  assert {
    condition = (
      !var.enable_smithdb ||
      !contains(keys(local.smithdb_tier_min_xlarge), var.sizing_profile) ||
      local.smithdb_node_xlarge >= local.smithdb_tier_min_xlarge[var.sizing_profile]
    )
    error_message = "sizing_profile = ${var.sizing_profile} gives SmithDB a tier that needs ${try(local.smithdb_tier_min_xlarge[var.sizing_profile], 0)}xlarge nodes or larger, but smithdb_node_instance_type is ${var.smithdb_node_instance_type}. SmithDB pods that do not fit stay Pending. Set smithdb_node_instance_type to m6a.8xlarge for production or m6a.16xlarge for production-large."
  }
}
