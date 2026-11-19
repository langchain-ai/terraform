output "resource_group_name" {
  description = "RG to pass to azure-private as resource_group_name (it deploys into this same RG)."
  value       = data.azurerm_resource_group.test.name
}

output "location" {
  description = "Region (azure-private inherits region from the RG)."
  value       = data.azurerm_resource_group.test.location
}

output "vnet_id" {
  description = "Spoke VNet ID → azure-private var: vnet_id"
  value       = azurerm_virtual_network.spoke.id
}

output "aks_subnet_id" {
  description = "→ azure-private var: aks_subnet_id"
  value       = azurerm_subnet.aks.id
}

output "postgres_subnet_id" {
  description = "→ azure-private var: postgres_subnet_id (private endpoint subnet)"
  value       = azurerm_subnet.postgres.id
}

output "redis_subnet_id" {
  description = "→ azure-private var: redis_subnet_id (private endpoint subnet)"
  value       = azurerm_subnet.redis.id
}

output "bastion_subnet_id" {
  description = "→ azure-private var: bastion_subnet_id (jumpbox subnet)"
  value       = azurerm_subnet.jumpbox.id
}

output "firewall_private_ip" {
  description = "Firewall private IP the AKS subnet default-routes to (FYI)."
  value       = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

output "jumpbox_public_ip" {
  description = "Public IP of the jumpbox apply host (null when create_jumpbox = false)."
  value       = one(azurerm_public_ip.jumpbox[*].ip_address)
}

output "jumpbox_ssh" {
  description = "SSH to the apply host (run the bootstrap from here)."
  value       = var.create_jumpbox ? "ssh ${var.jumpbox_admin_username}@${one(azurerm_public_ip.jumpbox[*].ip_address)}" : "jumpbox not created (create_jumpbox = false)"
}

# Ready-to-paste azure-private tfvars. Note the CIDRs are chosen to NOT overlap
# the hub/spoke VNets (azure-private's default aks_service_cidr = 10.0.64.0/20
# WOULD overlap the hub 10.0.0.0/16, so it is overridden here).
output "bootstrap_tfvars" {
  description = "Paste into modules/azure-private/bootstrap/terraform.tfvars (or supply as -var flags). Needs only subscription_id, resource_group_name, and identifier."
  value       = <<-EOT
    subscription_id     = "<your-subscription-id>"
    resource_group_name = "${data.azurerm_resource_group.test.name}"
    identifier          = "<same identifier used for infra/>"
  EOT
}

output "azure_private_tfvars" {
  description = "Paste into modules/azure-private/infra/terraform.tfvars (fill in subscription_id + secrets)."
  value       = <<-EOT
    subscription_id     = "<your-subscription-id>"
    resource_group_name = "${data.azurerm_resource_group.test.name}"

    vnet_id            = "${azurerm_virtual_network.spoke.id}"
    aks_subnet_id      = "${azurerm_subnet.aks.id}"
    postgres_subnet_id = "${azurerm_subnet.postgres.id}"
    redis_subnet_id    = "${azurerm_subnet.redis.id}"
    bastion_subnet_id  = "${azurerm_subnet.jumpbox.id}"

    # Non-overlapping with hub (${var.hub_cidr}) / spoke (${var.spoke_cidr}):
    aks_service_cidr   = "10.2.0.0/20"
    aks_dns_service_ip = "10.2.0.10"
    aks_pod_cidr       = "10.244.0.0/16"

    aks_private_dns_zone_id     = ""     # System-managed zone (auto-linked to the spoke VNet)
    aks_create_cluster_identity = true   # module-created user-assigned identity (default)

    bastion_admin_ssh_public_key = "<ssh-ed25519 ...>"
    bastion_allowed_ssh_cidrs    = ["<your-operator-cidr/32>"]

    # secrets — supply via TF_VAR_* or setup-env.sh:
    # postgres_admin_password / langsmith_license_key / langsmith_api_key_salt / langsmith_jwt_secret
  EOT
}
