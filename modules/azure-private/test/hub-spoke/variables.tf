variable "subscription_id" {
  type        = string
  description = "Azure subscription ID to deploy the test scaffold into."
}

variable "resource_group_name" {
  type        = string
  description = "EXISTING resource group to deploy the scaffold into (region is inherited from it). The scaffold never creates or deletes this RG."
  default     = "rg-langsmith-test"
}

variable "prefix" {
  type        = string
  description = "Name prefix for the test scaffold resources."
  default     = "lsazp-test"
}

variable "hub_cidr" {
  type        = string
  description = "Hub VNet address space (hosts Azure Firewall)."
  default     = "10.0.0.0/16"
}

variable "spoke_cidr" {
  type        = string
  description = "Spoke VNet address space (hosts AKS + private endpoints + jumpbox). The firewall rules allow egress from this range."
  default     = "10.1.0.0/16"
}

# ── Jumpbox apply host ────────────────────────────────────────────────────────

variable "create_jumpbox" {
  type        = bool
  description = "Create the jumpbox apply-host VM. Set false for an infra-only test (the infra/ apply runs from outside the VNet). The jumpbox SUBNET is always created (azure-private's own bastion uses it). Default true."
  default     = true
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR allowed to SSH to the jumpbox (your operator IP, e.g. \"203.0.113.4/32\"). Required when create_jumpbox = true (must not be empty or 0.0.0.0/0 — enforced by a precondition on the jumpbox NSG)."
  default     = ""
}

variable "jumpbox_ssh_public_key" {
  type        = string
  description = "SSH public key for the jumpbox admin user (key auth only). Required when create_jumpbox = true."
  default     = ""
}

variable "jumpbox_vm_size" {
  type        = string
  description = "Jumpbox VM size."
  default     = "Standard_B2s"
}

variable "jumpbox_admin_username" {
  type        = string
  description = "Admin username on the jumpbox VM."
  default     = "azureuser"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all scaffold resources."
  default = {
    purpose    = "azure-private-test-scaffold"
    managed_by = "terraform"
  }
}
