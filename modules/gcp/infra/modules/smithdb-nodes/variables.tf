# smithdb-nodes: dedicated GKE node pools for the SmithDB workloads.
#
# The AWS module provisions this capacity with Karpenter (EC2NodeClass with
# instanceStorePolicy: RAID0 plus NodePools constrained by local NVMe size).
# Karpenter has no GCP equivalent here, so these are native node pools whose
# labels and taints match the AWS ones exactly, letting a single Helm values
# overlay schedule correctly on either cloud.

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region. The cluster is regional, so pools span node_locations (or every zone in the region when unset)."
  type        = string
}

variable "cluster_name" {
  description = "Name of the GKE cluster to attach the pools to"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the node pool names, e.g. {name_prefix}-{environment}-smithdb"
  type        = string
}

variable "node_service_account_email" {
  description = "Service account email for the nodes. Should match the primary node pool. Pods use Workload Identity separately."
  type        = string
  default     = null
}

variable "node_locations" {
  description = "Zones to place SmithDB nodes in. Empty uses every zone in the cluster's region, which fails if the machine type or Local SSD count is unavailable in any of them. Pin this after checking availability."
  type        = list(string)
  default     = []
}

variable "release_channel_auto_upgrade" {
  description = "Enable node auto-upgrade. Required to stay true on clusters using a release channel."
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# Instance-store pool — Local SSD-backed ephemeral storage for the SmithDB cache
#------------------------------------------------------------------------------
variable "instance_store_machine_type" {
  description = "Machine type for the Local SSD pool. Second-generation types (N2/N2D) take an explicit local SSD count; third/fourth-generation -lssd types (C3, C4, Z3) have a fixed count implied by the machine type and must set instance_store_local_ssd_count = 0. At chart defaults the three cache workloads request 4 CPU each, which fits within the ~15.9 allocatable vCPU of an n2-standard-16."
  type        = string
  default     = "n2-standard-16"
}

variable "instance_store_local_ssd_count" {
  description = "Number of 375 GB Local SSD disks per node, combined into one ephemeral-storage filesystem. Compute Engine only accepts specific counts per machine type, so this is not a free-form number: N2 types with 12-20 vCPU (which includes the default n2-standard-16) take 2, 4, 8, 16 or 24. At chart defaults the three cache workloads request 200Gi (query) + 100Gi (ingestion) + 100Gi (compactionWorker), needing roughly 430 GB of allocatable ephemeral storage, which the default 2 disks (750 GB raw) covers with headroom for kubelet reservations and the image cache. Step up to 4 if you raise the resource requests or expect several replicas per node. Set 0 for -lssd machine types that bundle their own disks."
  type        = number
  default     = 2

  validation {
    # Compute Engine rejects any other count, and the API only reports it at
    # create time - a full apply in, which is expensive to discover. The exact
    # allowed subset narrows further with vCPU count (n2-standard-16 excludes 1),
    # so this catches the common typos rather than every invalid combination.
    # https://cloud.google.com/compute/docs/disks/local-ssd#choose_a_valid_number_of_local_ssd_disks
    condition     = contains([0, 1, 2, 4, 8, 16, 24], var.instance_store_local_ssd_count)
    error_message = "instance_store_local_ssd_count must be one of 0, 1, 2, 4, 8, 16, 24. Counts in between (3, 5, 6, ...) are rejected by Compute Engine. For N2 types with 12-20 vCPU such as n2-standard-16, use 2, 4, 8, 16 or 24."
  }
}

variable "instance_store_disk_size_gb" {
  description = "Boot disk size in GB for Local SSD pool nodes. The cache lives on Local SSD, so this only holds the OS and images."
  type        = number
  default     = 100
}

variable "instance_store_min_nodes" {
  description = "Minimum nodes per zone in the Local SSD pool. 0 lets the cluster autoscaler scale to zero when SmithDB is idle, which is the closest analogue to Karpenter consolidation."
  type        = number
  default     = 0
}

variable "instance_store_max_nodes" {
  description = "Maximum nodes per zone in the Local SSD pool"
  type        = number
  default     = 3
}

#------------------------------------------------------------------------------
# Compute pool — SmithDB components that do not need the local cache
#------------------------------------------------------------------------------
variable "compute_machine_type" {
  description = "Machine type for the SmithDB compute pool"
  type        = string
  default     = "n2-standard-8"
}

variable "compute_disk_size_gb" {
  description = "Boot disk size in GB for compute pool nodes"
  type        = number
  default     = 100
}

variable "compute_min_nodes" {
  description = "Minimum nodes per zone in the compute pool"
  type        = number
  default     = 0
}

variable "compute_max_nodes" {
  description = "Maximum nodes per zone in the compute pool"
  type        = number
  default     = 3
}

variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
