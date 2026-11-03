#------------------------------------------------------------------------------
# Every size, name and Helm value this root installs, computed with no provider
# in modules/values from the same inputs: the budget, the datastores chart's
# values, LangSmith's and SmithDB's values, and the Secrets' names. The resources
# here take them from it, and a tool that needs the module's values plans that
# module alone, with no cluster, credentials or mocks, and gets the same answer.
#------------------------------------------------------------------------------

module "values" {
  source = "./modules/values"

  aws_cli_image                     = var.aws_cli_image
  blob_storage_min_size_kb          = var.blob_storage_min_size_kb
  blob_storage_ttl_days             = var.blob_storage_ttl_days
  clickhouse_source                 = var.clickhouse_source
  clickhouse_storage_gi             = var.clickhouse_storage_gi
  cloudflared_image                 = var.cloudflared_image
  cluster_nodes                     = var.cluster_nodes
  cnpg_chart_version                = var.cnpg_chart_version
  cnpg_postgres_image               = var.cnpg_postgres_image
  datastore_namespace               = var.datastore_namespace
  datastore_replicas                = var.datastore_replicas
  datastore_requests                = var.datastore_requests
  datastore_runtime                 = var.datastore_runtime
  enable_blob_storage               = var.enable_blob_storage
  enable_cloudflare_tunnel          = var.enable_cloudflare_tunnel
  enable_deployments                = var.enable_deployments
  enable_engine                     = var.enable_engine
  enable_fleet                      = var.enable_fleet
  enable_sandboxes                  = var.enable_sandboxes
  enable_smithdb                    = var.enable_smithdb
  enable_sso_oidc                   = var.enable_sso_oidc
  enable_standalone_insights        = var.enable_standalone_insights
  enable_standalone_polly           = var.enable_standalone_polly
  enable_usage_telemetry            = var.enable_usage_telemetry
  engine_gateway_anthropic_base_url = var.engine_gateway_anthropic_base_url
  engine_gateway_auth_header        = var.engine_gateway_auth_header
  engine_gateway_openai_base_url    = var.engine_gateway_openai_base_url
  engine_intelligence_base_url      = var.engine_intelligence_base_url
  engine_sandbox_tenant_id          = var.engine_sandbox_tenant_id
  envoy_gateway_lb_ip               = var.envoy_gateway_lb_ip
  existing_gateway                  = var.existing_gateway
  expected_agent_deployments        = var.expected_agent_deployments
  gateway_tls_secret                = var.gateway_tls_secret
  install_envoy_gateway             = var.install_envoy_gateway
  install_local_path                = var.install_local_path
  install_metallb                   = var.install_metallb
  install_metrics_server            = var.install_metrics_server
  langsmith_domain                  = var.langsmith_domain
  langsmith_url_scheme              = var.langsmith_url_scheme
  local_path_helper_image           = var.local_path_helper_image
  local_path_image                  = var.local_path_image
  max_request_ratio                 = var.max_request_ratio
  metallb_addresses                 = var.metallb_addresses
  node_reserved                     = var.node_reserved
  object_store_buckets              = var.object_store_buckets
  object_store_endpoint             = var.object_store_endpoint
  object_store_gi                   = var.object_store_gi
  object_store_path_style           = var.object_store_path_style
  object_store_region               = var.object_store_region
  object_store_secret               = var.object_store_secret
  object_store_source               = var.object_store_source
  opstree_redis_image               = var.opstree_redis_image
  postgres_image                    = var.postgres_image
  postgres_secret                   = var.postgres_secret
  postgres_source                   = var.postgres_source
  redis_image                       = var.redis_image
  redis_memory_gi                   = var.redis_memory_gi
  redis_operator_chart_version      = var.redis_operator_chart_version
  redis_secret                      = var.redis_secret
  redis_source                      = var.redis_source
  rustfs_image                      = var.rustfs_image
  sandbox_hosts                     = var.sandbox_hosts
  sandbox_juicefs_cache_gi          = var.sandbox_juicefs_cache_gi
  sandbox_source_cidrs              = var.sandbox_source_cidrs
  sizing_profile                    = var.sizing_profile
  smithdb_ingestion_enabled         = var.smithdb_ingestion_enabled
  smithdb_metastore_port            = var.smithdb_metastore_port
  smithdb_metastore_secret          = var.smithdb_metastore_secret
  smithdb_metastore_source          = var.smithdb_metastore_source
  smithdb_metastore_tls             = var.smithdb_metastore_tls
  smithdb_migration_enabled         = var.smithdb_migration_enabled
  smithdb_migration_parallelism     = var.smithdb_migration_parallelism
  smithdb_query_enabled             = var.smithdb_query_enabled
  smithdb_tier                      = var.smithdb_tier
  storage_class                     = var.storage_class
  values_local_file                 = var.values_local_file
}
