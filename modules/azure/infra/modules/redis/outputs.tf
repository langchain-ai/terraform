# Client mode is derived from the clustering policy so the two can never disagree.
# OSSCluster speaks the Redis Cluster protocol and answers MOVED redirects, which a
# standalone client cannot follow — it needs the cluster client. EnterpriseCluster
# hides the slot map behind a single proxy endpoint, so it needs the standalone
# client plus clusterSafeMode (no MULTI/EXEC, hash-tagged keys).

output "cluster_enabled" {
  value       = var.clustering_policy == "OSSCluster"
  description = "Whether LangSmith should set redis.external.cluster.enabled (true for OSSCluster)"
}

output "cluster_safe_mode" {
  value       = var.clustering_policy == "EnterpriseCluster"
  description = "Whether LangSmith should set redis.external.clusterSafeMode (true for EnterpriseCluster)"
}

output "connection_url" {
  # Standalone endpoint over TLS, port 10000. Used when cluster_safe_mode is on, and
  # kept in the secret either way as the rollback path. Key is URL-encoded because AMR
  # access keys contain +, /, = which would otherwise break the rediss:// URL.
  value       = "rediss://:${urlencode(azapi_resource_action.amr_keys.output.primaryKey)}@${azapi_resource.amr.output.properties.hostName}:10000"
  description = "Redis (AMR) connection string using TLS"
  sensitive   = true
}

output "cluster_node_uris" {
  # JSON array string — the shape redis.external.cluster.nodeUris and the backend's
  # REDIS_CLUSTER_DATABASE_URIS both expect. Scheme is redis://, not rediss://: TLS
  # comes from cluster.tlsEnabled. Hostname verification is off because the AMR proxy
  # hands back node IPs that are absent from the endpoint certificate's SAN list.
  value = jsonencode([
    "redis://${azapi_resource.amr.output.properties.hostName}:10000?ssl_check_hostname=false"
  ])
  description = "AMR node URIs for redis.external.cluster.nodeUris (JSON array string)"
  sensitive   = true
}

output "cluster_password" {
  # Raw key, deliberately NOT urlencode()'d. connection_url encodes it only because it
  # is embedded in a URL there; as a standalone secret value it must be verbatim or
  # authentication fails.
  value       = azapi_resource_action.amr_keys.output.primaryKey
  description = "AMR primary access key for redis.external.cluster.password"
  sensitive   = true
}
