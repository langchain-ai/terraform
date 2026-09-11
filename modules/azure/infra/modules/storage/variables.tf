variable "storage_account_name" {
  type        = string
  description = "Name of the storage account"
}

variable "container_name" {
  type        = string
  description = "Name of the container"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name of the storage account"
}

variable "location" {
  type        = string
  description = "Location of the storage account"
}

variable "ttl_enabled" {
  type        = bool
  description = "Whether to enable time to live for blobs by adding a lifecycle policy"
  default     = true
}

variable "ttl_short_days" {
  type        = number
  description = "Time to live for short-lived blobs in days"
  default     = 14
}

variable "ttl_long_days" {
  type        = number
  description = "Time to live for long-lived blobs in days"
  default     = 400
}

variable "workload_identity_principal_id" {
  type        = string
  description = "Principal ID of the User-Assigned Managed Identity created by the k8s-cluster module. Granted Storage Blob Data Contributor on this account."
}

variable "workload_identity_client_id" {
  type        = string
  description = "Client ID of the User-Assigned Managed Identity. Passed through as an output for k8s-bootstrap annotation."
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}

variable "allowed_ips" {
  type        = list(string)
  description = "Public IPs / CIDRs allowed through the default-deny storage firewall. Add operator workstations, CI runner egress, or other clients that legitimately need to reach the data plane. AKS pod traffic uses a service endpoint allowlist (allowed_subnet_ids), not this list."
  default     = []
}

variable "allowed_subnet_ids" {
  type        = list(string)
  description = "Subnet IDs allowlisted via the Microsoft.Storage service endpoint. Typically the AKS subnet so pods can reach the blob data plane while the rest of the internet is denied. The subnet must have service_endpoints = [\"Microsoft.Storage\", ...] configured. Ignored when private_endpoint_enabled is true, because the account then has no public endpoint to filter."
  default     = []
}

variable "private_endpoint_enabled" {
  type        = bool
  description = "Reach this account over a Private Endpoint and turn off its public endpoint. Terraform manages the account through Azure Resource Manager, so provisioning is unaffected."
  default     = false
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "Subnet that holds the Private Endpoint. Required when private_endpoint_enabled is true."
  default     = ""
}

variable "private_dns_zone_id" {
  type        = string
  description = "privatelink.blob.core.windows.net zone the endpoint registers in. Owned by the root module, because a zone name links to a VNet once and both storage accounts share it. Required when private_endpoint_enabled is true."
  default     = ""
}
