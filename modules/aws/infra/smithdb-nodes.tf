# Dedicated SmithDB nodes, scaled independently by Cluster Autoscaler.
locals {
  smithdb_node_instance_type = coalesce(var.smithdb_node_instance_type, {
    minimum    = "m6g.4xlarge", dev = "m6g.4xlarge", default = "m6g.4xlarge",
    production = "m6g.8xlarge", production-large = "m6g.16xlarge"
  }[var.sizing_profile])
  # The Large tier exceeds five nodes' CPU capacity even before migration.
  smithdb_node_default_max_count = contains(["production", "production-large"], var.sizing_profile) ? 10 : 5
  smithdb_node_max_count         = coalesce(var.smithdb_node_max_count, local.smithdb_node_default_max_count)

  smithdb_node_group = {
    name           = "node-group-smithdb"
    instance_types = [local.smithdb_node_instance_type]
    min_size       = var.smithdb_node_min_count
    desired_size   = var.smithdb_node_min_count
    max_size       = local.smithdb_node_max_count
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
  description = "SmithDB EC2 instance type. Null selects m6g.4xlarge, m6g.8xlarge, or m6g.16xlarge for Small, production, or production-large."
  default     = null
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
  description = "Maximum SmithDB nodes. Null selects 5 for Small or 10 for production and production-large. Must exceed the minimum."
  default     = null

  validation {
    condition = var.smithdb_node_max_count == null ? local.smithdb_node_default_max_count > var.smithdb_node_min_count : (
      var.smithdb_node_max_count > var.smithdb_node_min_count && floor(var.smithdb_node_max_count) == var.smithdb_node_max_count
    )
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
