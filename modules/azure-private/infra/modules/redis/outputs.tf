output "connection_url" {
  # AMR endpoint over TLS, OSS cluster, port 10000. Key is URL-encoded because AMR
  # access keys contain +, /, = which would otherwise break the rediss:// URL.
  value       = "rediss://:${urlencode(azapi_resource_action.amr_keys.output.primaryKey)}@${azapi_resource.amr.output.properties.hostName}:10000"
  description = "Redis (AMR) connection string using TLS"
  sensitive   = true
}

output "cluster_safe_mode" {
  # AMR is always an OSS cluster — LangSmith must connect as a standalone client to
  # the endpoint (redis.external.clusterSafeMode: true), not a cluster client.
  value       = true
  description = "Whether LangSmith should set redis.external.clusterSafeMode (true for AMR)"
}
