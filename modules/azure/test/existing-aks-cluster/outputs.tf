// MIT License - Copyright (c) 2026 LangChain, Inc.
// NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
// See LICENSE at the root of this repository for full license text.

output "cluster_name" {
  description = "Pass to the LangSmith module as existing_cluster_name."
  value       = azurerm_kubernetes_cluster.customer.name
}

output "cluster_resource_group_name" {
  description = "Pass as existing_cluster_resource_group_name. Not the LangSmith resource group."
  value       = azurerm_resource_group.prereq.name
}

output "vnet_id" {
  value = azurerm_virtual_network.customer.id
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "postgres_subnet_id" {
  value = azurerm_subnet.postgres.id
}

output "redis_subnet_id" {
  value = azurerm_subnet.redis.id
}

output "kubeconfig_command" {
  description = "Fetch credentials before running the LangSmith apply."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.prereq.name} --name ${azurerm_kubernetes_cluster.customer.name} --overwrite-existing"
}

// The wizard has no create_cluster prompt, so these keys are hand-written. This
// emits the attach-to-existing half verbatim, leaving only the LangSmith-side
// choices (name_prefix, ingress, TLS, sizing) to fill in.
output "langsmith_tfvars" {
  description = "Paste into ../../infra/terraform.tfvars. Run: terraform output -raw langsmith_tfvars"
  value       = <<-EOT
    subscription_id = "${var.subscription_id}"
    location        = "${var.location}"

    # ── Attach to the existing cluster ─────────────────────────────────────────────────
    create_cluster                       = false
    existing_cluster_name                = "${azurerm_kubernetes_cluster.customer.name}"
    existing_cluster_resource_group_name = "${azurerm_resource_group.prereq.name}"
    # Leave true and Terraform attaches its own "large" pool (Standard_D16s_v3,
    # max 2) to a cluster it claims never to modify.
    existing_cluster_node_pools_managed  = false

    # ── Use the existing VNet ────────────────────────────────────────────────────
    # create_vnet must be false whenever create_cluster is false: the postcondition
    # on data.azurerm_kubernetes_cluster.existing requires aks_subnet_id to be one of
    # the existing cluster's node subnets, and a subnet Terraform is about to carve
    # can never be.
    create_vnet        = false
    vnet_id            = "${azurerm_virtual_network.customer.id}"
    aks_subnet_id      = "${azurerm_subnet.aks.id}"
    postgres_subnet_id = "${azurerm_subnet.postgres.id}"
    redis_subnet_id    = "${azurerm_subnet.redis.id}"
    # aks_service_cidr is deliberately absent. The cluster's ClusterIP range is
    # fixed when Azure creates it, so attaching neither requires nor uses one.

    # ── Rejected on this path, listed so nobody re-adds them ────────────────────
    # ingress_controller = "agic"          — needs a Terraform-managed VNet
    # ingress_controller = "istio-addon"    — rejected under create_cluster = false
    # create_bastion     = true             — needs a Terraform-managed VNet
    ingress_controller = "nginx"
    create_bastion     = false
  EOT
}
