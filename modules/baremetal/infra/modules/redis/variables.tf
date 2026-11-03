#------------------------------------------------------------------------------
# Inputs for one Redis instance.
# Covers namespace, image, persistence, storage, resources and which
# namespaces may connect.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "namespace" {
  type        = string
  description = "Namespace created for this instance."
}

variable "image" {
  type        = string
  description = "Redis image, exact tag."
}

variable "persistence" {
  type        = string
  default     = "rdb"
  description = "rdb = periodic snapshots (queues, caches); aof = append-only log fsynced every second (data you can't lose, e.g. JuiceFS metadata)."

  validation {
    condition     = contains(["rdb", "aof"], var.persistence)
    error_message = "persistence must be rdb or aof."
  }
}

variable "storage_size" {
  type        = string
  description = "PVC size for /data."
}

variable "storage_class" {
  type        = string
  description = "StorageClass for /data (the Retain class)."
}

variable "resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Container requests and limits (from the root budget)."
}

variable "memory_limit_mi" {
  type        = number
  description = "Memory limit in MiB; maxmemory is set to 75% of it to leave room for the copy-on-write fork during saves."
}

variable "allowed_namespaces" {
  type        = list(string)
  description = "Namespaces allowed to connect on 6379 (NetworkPolicy). The instance's own namespace is always allowed."
}

variable "datastore_label" {
  type        = map(string)
  description = "Label shared by every datastore pod, for anti-affinity spreading."
}

variable "allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "Addresses allowed to connect on 6379 besides those namespaces: clients on the host network, which no namespace selector matches."
}
