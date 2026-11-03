#------------------------------------------------------------------------------
# Inputs for the local-path provisioner and its two StorageClasses.
# Covers provisioner and helper images, the directory on each node, and
# resources.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "image" {
  type        = string
  description = "local-path-provisioner image (exact tag)."
}

variable "helper_image" {
  type        = string
  description = "Image for the helper pod that creates and deletes volume directories on the node (exact tag)."
}

variable "node_path" {
  type        = string
  default     = "/opt/local-path-provisioner"
  description = "Directory on every node that holds the volumes. It lives on the root LV unless you mount a dedicated disk there."
}

variable "resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Provisioner container requests and limits (from the root budget)."
}
