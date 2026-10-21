#------------------------------------------------------------------------------
# What one Redis instance exposes to the root module:
# connection details: host, port, password (sensitive) and the maxmemory
# derived from the memory limit.
#------------------------------------------------------------------------------

output "host" {
  description = "In-cluster DNS name of the instance."
  value       = "${kubernetes_service_v1.this.metadata[0].name}.${kubernetes_namespace_v1.this.metadata[0].name}.svc.cluster.local"
}

output "port" {
  description = "Redis port."
  value       = 6379
}

output "password" {
  description = "Generated password."
  value       = random_password.this.result
  sensitive   = true
}

output "maxmemory_mb" {
  description = "maxmemory set in redis.conf (75% of the memory limit)."
  value       = local.maxmemory_mb
}
