# Outputs for Networking Module

output "vpc_id" {
  description = "VPC network ID"
  value       = google_compute_network.vpc.id
}

output "vpc_name" {
  description = "VPC network name"
  value       = google_compute_network.vpc.name
}

output "vpc_self_link" {
  description = "VPC network self link"
  value       = google_compute_network.vpc.self_link
}

output "subnet_id" {
  description = "Subnet ID"
  value       = google_compute_subnetwork.subnet.id
}

output "subnet_name" {
  description = "Subnet name"
  value       = google_compute_subnetwork.subnet.name
}

output "subnet_self_link" {
  description = "Subnet self link"
  value       = google_compute_subnetwork.subnet.self_link
}

output "pods_range_name" {
  description = "Name of the secondary range for pods"
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range for services"
  value       = "services"
}

output "private_service_connection" {
  description = "Private service connection for managed services (null if private networking disabled)"
  value       = var.enable_private_service_connection ? google_service_networking_connection.private_vpc_connection[0].id : null
}

output "private_networking_enabled" {
  description = "Whether private networking is enabled"
  value       = var.enable_private_service_connection
}

output "router_name" {
  description = "Cloud Router name"
  value       = google_compute_router.router.name
}

