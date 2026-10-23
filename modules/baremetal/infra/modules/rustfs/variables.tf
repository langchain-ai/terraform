#------------------------------------------------------------------------------
# Inputs for RustFS (S3-compatible object storage).
# Covers namespace, image, the main bucket plus extra buckets, the AWS CLI
# image for the bucket Jobs, storage, resources and which namespaces may
# connect.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "namespace" {
  type        = string
  description = "Namespace created for this instance."
}

variable "image" {
  type        = string
  description = "RustFS image, exact tag."
}

variable "bucket" {
  type        = string
  description = "Bucket created by the init Job (idempotent)."
}

variable "extra_buckets" {
  type        = list(string)
  default     = []
  description = "More buckets on the same store and keys (e.g. LangSmith's payload blob bucket)."
}

variable "ttl_buckets" {
  type        = list(string)
  default     = []
  description = "Buckets that get LangSmith's two expiry rules (ttl_s/ and ttl_l/ prefixes): the payload blob bucket only. SmithDB's bucket takes none; it manages its own retention."
}

variable "ttl_days" {
  type        = object({ short = number, long = number })
  default     = { short = 14, long = 400 }
  description = "Days before ttl_s/ and ttl_l/ objects expire in the ttl_buckets."
}

variable "aws_cli_image" {
  type        = string
  description = "AWS CLI image for the bucket Job (works against any S3-compatible endpoint)."
}

variable "storage_size" {
  type        = string
  description = "PVC size for /data (objects)."
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

variable "allowed_namespaces" {
  type        = list(string)
  description = "Namespaces allowed to reach the S3 API on 9000 (NetworkPolicy). The instance's own namespace is always allowed."
}

variable "datastore_label" {
  type        = map(string)
  description = "Label shared by every datastore pod, for anti-affinity spreading."
}
