# Dedicated SmithDB nodes, scaled independently by Cluster Autoscaler. The defaults
# fit the small tier that the Helm values run; ../SMITHDB.md covers medium and large.
locals {
  smithdb_local_ssd = var.enable_smithdb && var.smithdb_cache_storage == "local-ssd"

  # nodeadm joins the instance-store NVMe disks as RAID0 and moves the kubelet,
  # containerd, and pod-log directories onto it, so emptyDir caches use it and the
  # node reports it as allocatable ephemeral-storage. The network-disk group gets no
  # extra user data, which keeps its launch template unchanged.
  smithdb_local_ssd_nodeadm = local.smithdb_local_ssd ? {
    cloudinit_pre_nodeadm = [{
      content_type = "application/node.eks.aws"
      content      = <<-EOT
        apiVersion: node.eks.aws/v1alpha1
        kind: NodeConfig
        spec:
          instance:
            localStorage:
              strategy: RAID0
      EOT
    }]
  } : {}

  smithdb_node_group = merge({
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
  }, local.smithdb_local_ssd_nodeadm)
}

variable "smithdb_cache_storage" {
  type        = string
  description = "SmithDB cache storage. \"network-disk\" (default): a gp3 volume per pod from the smithdb-cache StorageClass. \"local-ssd\": an emptyDir on the nodes' instance-store NVMe, which nodeadm joins as RAID0; it needs a smithdb_node_instance_type with instance store, such as m6id.4xlarge. A change replaces the SmithDB nodes, so follow the order in SMITHDB.md, \"Local SSD cache\"."
  default     = "network-disk"
  nullable    = false

  validation {
    condition     = contains(["network-disk", "local-ssd"], var.smithdb_cache_storage)
    error_message = "smithdb_cache_storage must be \"network-disk\" or \"local-ssd\"."
  }
}

# Read only in local-ssd mode: a node type without instance store would put the
# caches on the boot disk.
data "aws_ec2_instance_type" "smithdb" {
  count         = local.smithdb_local_ssd ? 1 : 0
  instance_type = var.smithdb_node_instance_type

  lifecycle {
    postcondition {
      condition     = self.instance_storage_supported
      error_message = "smithdb_cache_storage = \"local-ssd\" needs a smithdb_node_instance_type with instance-store NVMe, such as m6id.4xlarge for the small tier. ${var.smithdb_node_instance_type} has none."
    }
  }
}

output "smithdb_cache_storage" {
  description = "SmithDB cache storage: network-disk or local-ssd (null when enable_smithdb = false). deploy.sh writes the matching Helm cache values."
  value       = var.enable_smithdb ? var.smithdb_cache_storage : null
}

variable "smithdb_node_instance_type" {
  type        = string
  description = "SmithDB EC2 instance type. The default, m6a.4xlarge, fits the small tier that the Helm values run. The medium tier needs m6a.8xlarge nodes and the large tier m6a.16xlarge (SMITHDB.md, Scaling up)."
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
