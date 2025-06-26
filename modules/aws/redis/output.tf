output "connection_url" {
  value     = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:${aws_elasticache_cluster.redis.cache_nodes[0].port}"
  sensitive = true
}

# Copied from modules/gcp/redis/outputs.tf
locals {
  saq_monitored_keys = [
    "saq:default:queued",
    "saq:default:incomplete",
    "saq:default:active",
    "saq:adhoc:queued",
    "saq:adhoc:incomplete",
    "saq:adhoc:active",
    "saq:export:queued",
    "saq:export:incomplete",
    "saq:export:active",
    "saq:host:queued",
    "saq:host:incomplete",
    "saq:host:active",
    "saq:rules:queued",
    "saq:rules:incomplete",
    "saq:rules:active",
    "saq:upgrades:queued",
    "saq:upgrades:incomplete",
    "saq:upgrades:active",
    "session_deletes",
    "run_deletes",
  ]
}

output "instance_info" {
  value = {
    host = aws_elasticache_cluster.redis.cache_nodes[0].address
    # port = aws_elasticache_cluster.redis.cache_nodes[0].port
    name = aws_elasticache_cluster.redis.cluster_id
    monitored_keys = local.saq_monitored_keys
  }
}
