# Client mode derives from the policy so the two cannot disagree: OSSCluster answers
# MOVED redirects (cluster client), EnterpriseCluster proxies one endpoint (standalone
# client plus clusterSafeMode).

output "cluster_enabled" {
  value       = var.clustering_policy == "OSSCluster"
  description = "Sets redis.external.cluster.enabled — true for OSSCluster"
}

output "cluster_safe_mode" {
  value       = var.clustering_policy == "EnterpriseCluster"
  description = "Sets redis.external.clusterSafeMode — true for EnterpriseCluster"
}

output "connection_url" {
  # Key is URL-encoded: AMR access keys contain +, /, = which break the rediss:// URL.
  # Written in both modes — the standalone client uses it, cluster mode keeps it as the
  # rollback path.
  value       = "rediss://:${urlencode(azapi_resource_action.amr_keys.output.primaryKey)}@${azapi_resource.amr.output.properties.hostName}:10000"
  description = "Redis (AMR) connection string using TLS"
  sensitive   = true
}

output "cluster_node_uris" {
  # JSON array string — the shape REDIS_CLUSTER_DATABASE_URIS expects. TLS comes from
  # cluster.tlsEnabled, hence redis://; AMR returns node IPs absent from the endpoint
  # cert's SAN list, hence ssl_check_hostname=false.
  value = jsonencode([
    "redis://${azapi_resource.amr.output.properties.hostName}:10000?ssl_check_hostname=false"
  ])
  description = "AMR node URIs for redis.external.cluster.nodeUris (JSON array string)"
  sensitive   = true
}

output "cluster_password" {
  # Not urlencode()'d — connection_url encodes only because the key sits in a URL there.
  # Encoded here, auth fails.
  value       = azapi_resource_action.amr_keys.output.primaryKey
  description = "AMR primary access key for redis.external.cluster.password"
  sensitive   = true
}
