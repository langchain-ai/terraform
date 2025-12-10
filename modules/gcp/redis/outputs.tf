# Outputs for Redis Module

output "instance_name" {
  description = "Redis instance name"
  value       = google_redis_instance.langsmith.name
}

output "host" {
  description = "Redis host address"
  value       = google_redis_instance.langsmith.host
}

output "port" {
  description = "Redis port"
  value       = google_redis_instance.langsmith.port
}

output "current_location_id" {
  description = "Current location ID"
  value       = google_redis_instance.langsmith.current_location_id
}
