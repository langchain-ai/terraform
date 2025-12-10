# Outputs for GKE Cluster Module

output "cluster_name" {
  description = "GKE cluster name"
  value       = var.use_autopilot ? google_container_cluster.autopilot[0].name : google_container_cluster.primary[0].name
}

output "cluster_id" {
  description = "GKE cluster ID"
  value       = var.use_autopilot ? google_container_cluster.autopilot[0].id : google_container_cluster.primary[0].id
}

output "endpoint" {
  description = "GKE cluster endpoint"
  value       = var.use_autopilot ? google_container_cluster.autopilot[0].endpoint : google_container_cluster.primary[0].endpoint
  sensitive   = true
}

output "ca_certificate" {
  description = "GKE cluster CA certificate"
  value       = var.use_autopilot ? google_container_cluster.autopilot[0].master_auth[0].cluster_ca_certificate : google_container_cluster.primary[0].master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "location" {
  description = "GKE cluster location"
  value       = var.use_autopilot ? google_container_cluster.autopilot[0].location : google_container_cluster.primary[0].location
}
