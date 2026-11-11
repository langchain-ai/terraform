#------------------------------------------------------------------------------
# The root's inputs these values depend on, with the root's types and defaults:
# the root passes every one, and a tool planning this module alone gets the
# root's answer for whatever it leaves out. Descriptions and validations are the
# root's (../../*.tf); tests/values.tftest.hcl fails when a default here drifts
# from the root's.
#------------------------------------------------------------------------------

variable "aws_cli_image" {
  type    = string
  default = "docker.io/amazon/aws-cli:2.37.8"
}

variable "blob_storage_min_size_kb" {
  type    = number
  default = 20
}

variable "blob_storage_ttl_days" {
  type    = object({ short = number, long = number })
  default = { short = 14, long = 400 }
}

variable "clickhouse_source" {
  type    = string
  default = "off"
}

variable "clickhouse_storage_gi" {
  type    = number
  default = 50
}

variable "cloudflared_image" {
  type    = string
  default = "docker.io/cloudflare/cloudflared:2026.10.0"
}

variable "cluster_nodes" {
  type = map(object({
    cpu       = number
    memory_gi = number
    disk_gi   = number
    role      = optional(string, "worker")
  }))
}

variable "cnpg_chart_version" {
  type    = string
  default = "0.29.1"
}

variable "cnpg_postgres_image" {
  type    = string
  default = "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie"
}

variable "datastore_namespace" {
  type    = string
  default = "langsmith-data"
}

variable "datastore_replicas" {
  type    = number
  default = 1
}

variable "datastore_requests" {
  type = map(object({
    cpu_m  = number
    mem_mi = number
  }))
  default = {}
}

variable "datastore_runtime" {
  type    = string
  default = "statefulset"
}

variable "enable_blob_storage" {
  type    = bool
  default = true
}

variable "enable_cloudflare_tunnel" {
  type    = bool
  default = false
}

variable "enable_deployments" {
  type    = bool
  default = false
}

variable "enable_engine" {
  type    = bool
  default = false
}

variable "enable_fleet" {
  type    = bool
  default = false
}

variable "enable_sandboxes" {
  type    = bool
  default = false
}

variable "enable_smithdb" {
  type    = bool
  default = true
}

variable "enable_sso_oidc" {
  type    = bool
  default = false
}

variable "enable_standalone_insights" {
  type    = bool
  default = false
}

variable "enable_standalone_polly" {
  type    = bool
  default = false
}

variable "common_env" {
  type    = list(object({ name = string, value = string }))
  default = []
}

variable "enable_usage_telemetry" {
  type    = bool
  default = false
}

variable "engine_gateway_anthropic_base_url" {
  type    = string
  default = ""
}

variable "engine_gateway_auth_header" {
  type    = string
  default = ""
}

variable "engine_gateway_openai_base_url" {
  type    = string
  default = ""
}

variable "engine_intelligence_base_url" {
  type    = string
  default = "https://beacon.langchain.com/intelligence"
}

variable "engine_sandbox_tenant_id" {
  type    = string
  default = ""
}

variable "envoy_gateway_lb_ip" {
  type    = string
  default = ""
}

variable "existing_gateway" {
  type = object({
    name      = string
    namespace = string
  })
  default = null
}

variable "expected_agent_deployments" {
  type    = number
  default = 0
}

variable "gateway_tls_secret" {
  type    = string
  default = ""
}

variable "install_envoy_gateway" {
  type    = bool
  default = true
}

variable "install_local_path" {
  type    = bool
  default = true
}

variable "install_metallb" {
  type    = bool
  default = true
}

variable "install_metrics_server" {
  type    = bool
  default = true
}

variable "langsmith_domain" {
  type    = string
  default = ""
}

variable "langsmith_url_scheme" {
  type    = string
  default = "http"
}

variable "local_path_helper_image" {
  type    = string
  default = "docker.io/library/busybox:1.37.0"
}

variable "local_path_image" {
  type    = string
  default = "docker.io/rancher/local-path-provisioner:v0.0.37"
}

variable "max_request_ratio" {
  type    = number
  default = 0.7
}

variable "metallb_addresses" {
  type    = list(string)
  default = []
}

variable "node_reserved" {
  type = object({
    cpu       = number
    memory_gi = number
  })
  default = {
    cpu       = 0.5
    memory_gi = 2
  }
}

variable "object_store_buckets" {
  type    = object({ smithdb = string, blobs = string })
  default = { smithdb = "smithdb", blobs = "langsmith-blobs" }
}

variable "object_store_endpoint" {
  type    = string
  default = ""
}

variable "object_store_gi" {
  type    = number
  default = null
}

variable "object_store_path_style" {
  type    = bool
  default = true
}

variable "object_store_region" {
  type    = string
  default = "us-east-1"
}

variable "object_store_secret" {
  type    = string
  default = "object-store"
}

variable "object_store_source" {
  type    = string
  default = "in-cluster"
}

variable "opstree_redis_image" {
  type    = string
  default = "quay.io/opstree/redis:v7.4.11"
}

variable "redis_sentinel_image" {
  type    = string
  default = "quay.io/opstree/redis-sentinel:v7.4.11"
}

variable "postgres_image" {
  type    = string
  default = "docker.io/library/postgres:18.6"
}

variable "postgres_secret" {
  type    = string
  default = "langsmith-postgres"
}

variable "postgres_source" {
  type    = string
  default = "in-cluster"
}

variable "redis_image" {
  type    = string
  default = "docker.io/library/redis:7.4.11"
}

variable "redis_memory_gi" {
  type    = number
  default = null
}

variable "redis_operator_chart_version" {
  type    = string
  default = "0.27.0"
}

variable "redis_secret" {
  type    = string
  default = "langsmith-redis"
}

variable "redis_source" {
  type    = string
  default = "in-cluster"
}

variable "rustfs_image" {
  type    = string
  default = "docker.io/rustfs/rustfs:1.0.1"
}

variable "sandbox_hosts" {
  type    = list(string)
  default = []
}

variable "sandbox_juicefs_cache_gi" {
  type    = number
  default = 50
}

variable "sandbox_source_cidrs" {
  type    = list(string)
  default = []
}

variable "sizing_profile" {
  type    = string
  default = "minimum"
}

variable "smithdb_ingestion_enabled" {
  type    = bool
  default = true
}

variable "smithdb_metastore_port" {
  type    = number
  default = 5432
}

variable "smithdb_metastore_secret" {
  type    = string
  default = "smithdb-metastore"
}

variable "smithdb_metastore_source" {
  type    = string
  default = "in-cluster"
}

variable "smithdb_metastore_tls" {
  type    = bool
  default = false
}

variable "smithdb_migration_enabled" {
  type    = bool
  default = false
}

variable "smithdb_migration_parallelism" {
  type    = number
  default = 1
}

variable "smithdb_query_enabled" {
  type    = bool
  default = true
}

variable "smithdb_tier" {
  type    = string
  default = ""
}

variable "storage_class" {
  type    = string
  default = ""
}

variable "values_local_file" {
  type    = string
  default = ""
}
