variable "domain" {
  type        = string
  description = "Public DNS domain name to create the zone for (e.g. langsmith.mycompany.com)"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the DNS zone"
}

variable "ingress_ip" {
  type        = string
  description = "Public IP address of the NGINX ingress Load Balancer to point the A record at"
}

variable "cert_manager_principal_id" {
  type        = string
  description = "Principal ID of the cert-manager managed identity or service account. Granted DNS Zone Contributor for DNS-01 challenges. Leave empty to skip."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags"
  default     = {}
}
