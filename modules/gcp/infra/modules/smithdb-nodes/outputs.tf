output "instance_store_pool_name" {
  description = "Name of the Local SSD-backed SmithDB node pool"
  value       = google_container_node_pool.instance_store.name
}

output "compute_pool_name" {
  description = "Name of the SmithDB compute node pool"
  value       = google_container_node_pool.compute.name
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
