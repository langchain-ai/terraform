# Dedicated SmithDB nodes, scaled independently by Cluster Autoscaler. The defaults
# fit the small tier, which every sizing profile runs; ../SMITHDB.md covers medium
# and large.
locals {
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
  description = "SmithDB EC2 instance type. The default, m6a.4xlarge, fits the small tier that every sizing profile runs. The medium tier needs m6a.8xlarge nodes and the large tier m6a.16xlarge (SMITHDB.md, Scaling up)."
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
  description = "Maximum SmithDB nodes. Must exceed the minimum, so that a rolling update has room for its extra pod. Raise it for the medium and large tiers."
  default     = 5
  nullable    = false

  validation {
    condition     = var.smithdb_node_max_count > var.smithdb_node_min_count && floor(var.smithdb_node_max_count) == var.smithdb_node_max_count
    error_message = "smithdb_node_max_count must be a whole number greater than smithdb_node_min_count. SmithDB rolls out one extra pod at a time, and a full pool at its maximum cannot place it."
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
