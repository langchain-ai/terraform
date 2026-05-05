# Outputs for Redis Module

output "instance_name" {
  description = "Redis instance name"
  value       = var.prevent_destroy ? google_redis_instance.langsmith_protected[0].name : google_redis_instance.langsmith[0].name
}

output "host" {
  description = "Redis host address"
  value       = var.prevent_destroy ? google_redis_instance.langsmith_protected[0].host : google_redis_instance.langsmith[0].host
}

output "port" {
  description = "Redis port"
  value       = var.prevent_destroy ? google_redis_instance.langsmith_protected[0].port : google_redis_instance.langsmith[0].port
}

output "current_location_id" {
  description = "Current location ID"
  value       = var.prevent_destroy ? google_redis_instance.langsmith_protected[0].current_location_id : google_redis_instance.langsmith[0].current_location_id
}
