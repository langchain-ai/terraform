# Dedicated general-purpose nodes; cache volumes use Azure Managed Disks.
locals {
  smithdb_node_vm_size = coalesce(var.smithdb_node_vm_size, {
    small = "Standard_D16s_v5", medium = "Standard_D32s_v5", large = "Standard_D64s_v5"
  }[local.smithdb_resource_tier])
  smithdb_node_max_count = coalesce(var.smithdb_node_max_count, local.smithdb_resource_tier == "small" ? 5 : 10)

  # Keep existing pool overrides while enforcing the scheduling contract.
  smithdb_node_pools = var.enable_smithdb ? {
    smithdb = merge({
      vm_size           = local.smithdb_node_vm_size
      min_count         = var.smithdb_node_min_count
      max_count         = local.smithdb_node_max_count
      kubelet_disk_type = "OS"
      zones             = var.smithdb_node_zones != null ? var.smithdb_node_zones : var.availability_zones
      os_sku            = null
      os_disk_size_gb   = var.smithdb_node_os_disk_size_gb
      }, try(var.additional_node_pools["smithdb"], {}), {
      zones           = try(var.additional_node_pools["smithdb"].zones, null) != null ? var.additional_node_pools["smithdb"].zones : (var.smithdb_node_zones != null ? var.smithdb_node_zones : var.availability_zones)
      os_disk_size_gb = try(var.additional_node_pools["smithdb"].os_disk_size_gb, null) != null ? var.additional_node_pools["smithdb"].os_disk_size_gb : var.smithdb_node_os_disk_size_gb
      node_labels = merge(try(var.additional_node_pools["smithdb"].node_labels, {}), {
        "langsmith-nodepool/smithdb" = "true"
      })
      node_taints = distinct(concat(try(var.additional_node_pools["smithdb"].node_taints, []), ["langsmith-nodepool/smithdb=true:NoSchedule"]))
    })
  } : {}

  smithdb_node_tolerations = var.enable_smithdb ? [
    for taint in local.smithdb_node_pools["smithdb"].node_taints : {
      key      = split("=", split(":", taint)[0])[0]
      operator = strcontains(split(":", taint)[0], "=") ? "Equal" : "Exists"
      value    = try(split("=", split(":", taint)[0])[1], "")
      effect   = split(":", taint)[1]
    }
  ] : []
}

variable "smithdb_node_vm_size" {
  type        = string
  description = "SmithDB node VM size. Null selects D16s_v5, D32s_v5, or D64s_v5 for the small, medium, or large chart tier."
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
  description = "Maximum SmithDB nodes. Null selects 5 for small or 10 for medium and large."
  default     = null

  validation {
    condition     = var.smithdb_node_max_count == null ? true : var.smithdb_node_max_count > var.smithdb_node_min_count && floor(var.smithdb_node_max_count) == var.smithdb_node_max_count
    error_message = "smithdb_node_max_count must be a whole number greater than smithdb_node_min_count."
  }
}

variable "smithdb_node_os_disk_size_gb" {
  type        = number
  description = "SmithDB node OS disk size in GB. Null keeps the AKS default; migration needs 100Gi of allocatable node ephemeral storage per pod."
  default     = null
}

check "smithdb_pool_on_attached_cluster" {
  assert {
    condition     = !var.enable_smithdb || var.create_cluster || var.existing_cluster_node_pools_managed
    error_message = "Terraform does not add a SmithDB pool to an attached cluster with existing_cluster_node_pools_managed = false. Provide zonal general-purpose nodes with label langsmith-nodepool/smithdb=true and taint langsmith-nodepool/smithdb=true:NoSchedule, or set existing_cluster_node_pools_managed = true."
  }
}

variable "smithdb_node_zones" {
  type        = list(string)
  description = "SmithDB node availability zones. Null follows availability_zones without changing other pools or databases."
  default     = null

  validation {
    condition     = var.smithdb_node_zones == null ? true : length(var.smithdb_node_zones) > 0 && alltrue([for zone in var.smithdb_node_zones : contains(["1", "2", "3"], zone)])
    error_message = "smithdb_node_zones must name at least one zone, using 1, 2, or 3."
  }
}

output "smithdb_node_tolerations" {
  description = "Required tolerations for every SmithDB workload, derived from the dedicated pool's taints."
  value       = var.enable_smithdb ? local.smithdb_node_tolerations : null
}
