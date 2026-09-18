variable "name" {
  type        = string
  description = "Name of the bastion VM"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the bastion VM"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "subnet_id" {
  type        = string
  description = "ID of the bastion subnet"
}

variable "vm_size" {
  type        = string
  description = "Azure VM SKU for the bastion host"
  default     = "Standard_B2s" # 2 vCPU, 4 GB RAM — adequate for kubectl/helm operations
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for emergency admin access (az ssh vm is the primary path)"
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed inbound SSH access to the bastion. Restrict to corporate IP ranges."
  default     = ["0.0.0.0/0"] # override in production — restrict to VPN/corporate CIDR
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags"
  default     = {}
}
