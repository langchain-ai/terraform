output "instance_store_pool_name" {
  description = "Name of the Local SSD-backed SmithDB node pool"
  value       = try(google_container_node_pool.instance_store[0].name, null)
}

output "compute_pool_name" {
  description = "Name of the SmithDB compute node pool"
  value       = try(google_container_node_pool.compute[0].name, null)
}

output "instance_store_node_selector" {
  description = "Node selector label the Helm values overlay uses to pin SmithDB cache workloads"
  value       = { "smithdb-local/instance-store" = "true" }
}

output "compute_node_selector" {
  description = "Node selector label the Helm values overlay uses to pin SmithDB compute workloads"
  value       = { "smithdb-local/compute" = "true" }
}

output "local_ssd_capacity_gb" {
  description = "Raw Local SSD capacity per instance-store node in GB. Usable ephemeral-storage is lower after filesystem and kubelet reservations."
  value       = var.instance_store_local_ssd_count * 375
}

output "general_pool_name" {
  description = "Name of the general-purpose SmithDB node pool"
  value       = try(google_container_node_pool.general[0].name, null)
}

output "legacy_pool_config" {
  description = "Retained cache pool shape during a transition or with local SSD"
  value = var.create_legacy_pools ? {
    machine_type    = google_container_node_pool.instance_store[0].node_config[0].machine_type
    disk_size_gb    = google_container_node_pool.instance_store[0].node_config[0].disk_size_gb
    local_ssd_count = var.instance_store_local_ssd_count
  } : null
}
