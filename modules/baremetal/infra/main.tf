#------------------------------------------------------------------------------
# Everything this root creates in the cluster, in dependency order:
#   metrics-server         pod metrics for HPAs and kubectl top
#   local-path             StorageClasses on node-local disk (Delete, Retain)
#   MetalLB                LoadBalancer IPs from metallb_addresses (L2)
#   namespace langsmith    where the Helm chart installs LangSmith and SmithDB
#   Envoy Gateway          the Gateway LangSmith's HTTPRoute attaches to
#   cloudflared            optional Cloudflare Tunnel connector
#   Postgres x2            LangSmith database and SmithDB metastore
#   Redis                  run buffer and task queues
#   RustFS                 S3 buckets for SmithDB data and payload blobs
#   Secrets in langsmith   connection details the chart reads by name
#
# Everything waits for the budget gate (budget.tf), so nothing is created on a
# cluster that can't hold the chosen sizing profile. Sizes come from locals.tf;
# Helm values for the chart are built in helm_values.tf.
#------------------------------------------------------------------------------

module "metrics_server" {
  source = "./modules/metrics-server"
  count  = var.install_metrics_server ? 1 : 0

  chart_version        = var.metrics_server_chart_version
  kubelet_insecure_tls = var.metrics_server_kubelet_insecure_tls
  resources = {
    requests = { cpu = "${local.addon_pods["metrics-server"].cpu_m}m", memory = "${local.addon_pods["metrics-server"].mem_mi}Mi" }
    limits   = { cpu = "500m", memory = "${local.addon_pods["metrics-server"].mem_mi * 2}Mi" }
  }

  # Everything that runs a pod waits for the sandbox taint: a sandbox node takes nothing else, and a pod
  # scheduled there before the taint stays (a datastore binds its volume to that node).
  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

module "local_path" {
  source = "./modules/local-path"
  count  = var.install_local_path ? 1 : 0

  image        = var.local_path_image
  helper_image = var.local_path_helper_image
  node_path    = var.local_path_node_path
  resources = {
    requests = { cpu = "${local.addon_pods["local-path-provisioner"].cpu_m}m", memory = "${local.addon_pods["local-path-provisioner"].mem_mi}Mi" }
    limits   = { cpu = "200m", memory = "${local.addon_pods["local-path-provisioner"].mem_mi * 2}Mi" }
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

module "metallb" {
  source = "./modules/metallb"
  count  = var.install_metallb ? 1 : 0

  chart_version = var.metallb_chart_version
  # The gateway's pool only for our Envoy; the IP only for our MetalLB: another load balancer cannot serve an address outside its own pools, and the Service would stay <pending>.
  gateway_ip       = var.install_envoy_gateway ? var.envoy_gateway_lb_ip : ""
  addresses        = var.metallb_addresses
  l2_node_selector = var.metallb_l2_node_selector
  controller_resources = {
    requests = { cpu = "${local.addon_pods["metallb-controller"].cpu_m}m", memory = "${local.addon_pods["metallb-controller"].mem_mi}Mi" }
    limits   = { cpu = "500m", memory = "256Mi" }
  }
  speaker_resources = {
    requests = { cpu = "${local.addon_pods["metallb-speaker"].cpu_m}m", memory = "${local.addon_pods["metallb-speaker"].mem_mi}Mi" }
    limits   = { cpu = "200m", memory = "128Mi" }
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

# Terraform owns the langsmith namespace, so the Gateway (and later the
# datastore Secrets) exist before Helm installs LangSmith into it.
resource "kubernetes_namespace_v1" "langsmith" {
  metadata {
    name = "langsmith"
    # sandbox-host runs privileged with host networking: Pod Security Admission must allow it here.
    labels = var.enable_sandboxes ? { "pod-security.kubernetes.io/enforce" = "privileged" } : {}
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

module "envoy_gateway" {
  source = "./modules/envoy-gateway"
  count  = var.install_envoy_gateway ? 1 : 0

  chart_version     = var.envoy_gateway_chart_version
  load_balancer_ip  = var.install_metallb ? var.envoy_gateway_lb_ip : ""
  route_timeout     = var.envoy_gateway_route_timeout
  gateway_namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  controller_resources = {
    requests = { cpu = "${local.addon_pods["envoy-gateway"].cpu_m}m", memory = "${local.addon_pods["envoy-gateway"].mem_mi}Mi" }
    limits   = { cpu = "500m", memory = "512Mi" }
  }
  proxy_node_selector = var.envoy_proxy_node_selector
  proxy_resources = {
    requests = { cpu = "${local.addon_pods["envoy-proxy"].cpu_m}m", memory = "${local.addon_pods["envoy-proxy"].mem_mi}Mi" }
    limits   = { cpu = "1", memory = "512Mi" }
  }
  tls = var.gateway_tls_secret == "" ? null : { hostname = var.langsmith_domain, secret_name = var.gateway_tls_secret }
  # With a domain, the chart's HTTPRoute matches only that Host; keep the LAN IP
  # serving LangSmith too.
  lan_route = {
    enabled         = var.langsmith_domain != ""
    backend_service = "langsmith-frontend"
    backend_port    = 80
  }

  depends_on = [module.metallb]
}

# The pinned IP must come from MetalLB's pool, or the Service stays <pending>.
resource "terraform_data" "envoy_lb_ip_check" {
  input = var.envoy_gateway_lb_ip

  lifecycle {
    precondition {
      condition     = !var.install_metallb || !local.lb_ip_in_pool
      error_message = "envoy_gateway_lb_ip ${var.envoy_gateway_lb_ip} is inside metallb_addresses (${join(", ", var.metallb_addresses)}). The gateway gets its own pool; keep its IP out of metallb_addresses so no other Service can take it."
    }
  }
}

# Cloudflare Tunnel connector. Its origin is the Envoy proxy's in-cluster
# Service (output cloudflare_tunnel.origin_service_url), so the public path
# doesn't depend on MetalLB.
module "cloudflared" {
  source = "./modules/cloudflared"
  count  = var.enable_cloudflare_tunnel ? 1 : 0

  image        = var.cloudflared_image
  tunnel_token = var.cloudflare_tunnel_token
  replicas     = local.addon_pods["cloudflared"].replicas
  resources = {
    requests = { cpu = "${local.addon_pods["cloudflared"].cpu_m}m", memory = "${local.addon_pods["cloudflared"].mem_mi}Mi" }
    limits   = { memory = "256Mi" }
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

# KEDA, for LangSmith Deployments only: the operator creates a ScaledObject per
# agent deployment (chart default operator.kedaEnabled: true). Sized from the
# same addon_pods entries the budget counts.
resource "helm_release" "keda" {
  count = local.install_keda ? 1 : 0

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_chart_version
  namespace        = "keda"
  create_namespace = true
  wait             = true

  values = [
    yamlencode({
      resources = {
        operator = {
          requests = { cpu = "${local.addon_pods["keda-operator"].cpu_m}m", memory = "${local.addon_pods["keda-operator"].mem_mi}Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        metricServer = {
          requests = { cpu = "${local.addon_pods["keda-metrics-server"].cpu_m}m", memory = "${local.addon_pods["keda-metrics-server"].mem_mi}Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        webhooks = {
          requests = { cpu = "${local.addon_pods["keda-webhooks"].cpu_m}m", memory = "${local.addon_pods["keda-webhooks"].mem_mi}Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
    })
  ]

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

#------------------------------------------------------------------------------
# Datastores. Shared label + preferred anti-affinity spreads them across
# workers; sizes come from local.datastores (the budget).
#------------------------------------------------------------------------------
locals {
  datastore_label = { "langsmith.lab/datastore" = "true" }
}

module "postgres_langsmith" {
  source = "./modules/postgres"
  count  = var.postgres_source == "in-cluster" ? 1 : 0

  namespace          = "postgres-langsmith"
  image              = var.postgres_image
  database           = "langsmith"
  username           = "langsmith"
  storage_size       = local.datastores_k8s.postgres_langsmith.storage
  storage_class      = local.storage_class_retain
  resources          = { requests = local.datastores_k8s.postgres_langsmith.requests, limits = local.datastores_k8s.postgres_langsmith.limits }
  memory_limit_mi    = local.datastores.postgres_langsmith.lim_mem_mi
  allowed_namespaces = [kubernetes_namespace_v1.langsmith.metadata[0].name]
  datastore_label    = local.datastore_label
  extra_databases    = values(local.standalone_features)

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

module "postgres_smithdb" {
  source = "./modules/postgres"
  count  = var.smithdb_metastore_source == "in-cluster" ? 1 : 0

  namespace          = "postgres-smithdb"
  image              = var.postgres_image
  database           = "smithdb_metastore"
  username           = "smithdb"
  storage_size       = local.datastores_k8s.postgres_smithdb.storage
  storage_class      = local.storage_class_retain
  resources          = { requests = local.datastores_k8s.postgres_smithdb.requests, limits = local.datastores_k8s.postgres_smithdb.limits }
  memory_limit_mi    = local.datastores.postgres_smithdb.lim_mem_mi
  allowed_namespaces = [kubernetes_namespace_v1.langsmith.metadata[0].name]
  datastore_label    = local.datastore_label

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

#------------------------------------------------------------------------------
# Consumer Secrets in the langsmith namespace (pods only read Secrets in their
# own namespace). Formats follow chart 0.17.6:
#   langsmith-postgres  connection_url = user:pass@host:port/db  (NO scheme; the
#                       chart builds POSTGRES_DATABASE_URI from it)
#   smithdb-config      SmithDB's single config Secret (smithdb.config.existingSecretName):
#                       metastore keys now, MinIO S3 keys added with the MinIO module
#------------------------------------------------------------------------------
resource "kubernetes_secret_v1" "langsmith_postgres" {
  count = var.postgres_source == "in-cluster" ? 1 : 0

  metadata {
    name      = "langsmith-postgres"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    connection_url = "${module.postgres_langsmith[0].username}:${module.postgres_langsmith[0].password}@${module.postgres_langsmith[0].host}:${module.postgres_langsmith[0].port}/${module.postgres_langsmith[0].database}"
  }
  type = "Opaque"
}

# The customer's metastore, read from their Secret: SmithDB takes one Secret for its metastore and its
# object store together (smithdb.config.existingSecretName), so the keys are copied into smithdb-config.
data "kubernetes_secret_v1" "smithdb_metastore" {
  count = var.smithdb_metastore_source == "external" ? 1 : 0
  metadata {
    name      = var.smithdb_metastore_secret
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
}

locals {
  metastore = var.smithdb_metastore_source == "external" ? {
    host     = data.kubernetes_secret_v1.smithdb_metastore[0].data["smithdb_metastore_host"]
    db       = data.kubernetes_secret_v1.smithdb_metastore[0].data["smithdb_metastore_db"]
    user     = data.kubernetes_secret_v1.smithdb_metastore[0].data["smithdb_metastore_user"]
    password = data.kubernetes_secret_v1.smithdb_metastore[0].data["smithdb_metastore_password"]
    } : {
    host     = module.postgres_smithdb[0].host
    db       = module.postgres_smithdb[0].database
    user     = module.postgres_smithdb[0].username
    password = module.postgres_smithdb[0].password
  }
}

# The customer's object store, its keys read from their Secret into smithdb-config, as the metastore's.
data "kubernetes_secret_v1" "object_store" {
  count = var.object_store_source == "external" ? 1 : 0
  metadata {
    name      = var.object_store_secret
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
}

locals {
  object_store = var.object_store_source == "external" ? {
    endpoint   = var.object_store_endpoint
    region     = var.object_store_region
    path_style = var.object_store_path_style
    smithdb    = var.object_store_buckets.smithdb
    blobs      = var.object_store_buckets.blobs
    access_key = data.kubernetes_secret_v1.object_store[0].data["access_key_id"]
    secret_key = data.kubernetes_secret_v1.object_store[0].data["secret_access_key"]
    } : {
    endpoint   = module.rustfs_smithdb[0].endpoint
    region     = "us-east-1" # any value; RustFS ignores it, the SDK needs one
    path_style = true
    smithdb    = module.rustfs_smithdb[0].bucket
    blobs      = local.blob_bucket
    access_key = module.rustfs_smithdb[0].access_key
    secret_key = module.rustfs_smithdb[0].secret_key
  }
}

resource "kubernetes_secret_v1" "smithdb_config" {
  metadata {
    name      = "smithdb-config"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    smithdb_metastore_host     = local.metastore.host
    smithdb_metastore_db       = local.metastore.db
    smithdb_metastore_user     = local.metastore.user
    smithdb_metastore_password = local.metastore.password
    smithdb_s3_access_key      = local.object_store.access_key
    smithdb_s3_secret_key      = local.object_store.secret_key
  }
  type = "Opaque"
}

module "redis_langsmith" {
  source = "./modules/redis"
  count  = var.redis_source == "in-cluster" ? 1 : 0

  namespace          = "redis-langsmith"
  image              = var.redis_image
  persistence        = "rdb"
  storage_size       = local.datastores_k8s.redis_langsmith.storage
  storage_class      = local.storage_class_retain
  resources          = { requests = local.datastores_k8s.redis_langsmith.requests, limits = local.datastores_k8s.redis_langsmith.limits }
  memory_limit_mi    = local.datastores.redis_langsmith.lim_mem_mi
  allowed_namespaces = [kubernetes_namespace_v1.langsmith.metadata[0].name]
  datastore_label    = local.datastore_label

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

# LangSmith core reads REDIS_DATABASE_URI from connection_url. Unlike the
# Postgres core URL, the chart's Redis URL INCLUDES the scheme. /0 selects
# logical DB 0 (1 Fleet, 2 Polly, 3 Insights: local.redis_db_index, as in modules/gcp).
resource "kubernetes_secret_v1" "langsmith_redis" {
  count = var.redis_source == "in-cluster" ? 1 : 0

  metadata {
    name      = "langsmith-redis"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    connection_url = "redis://:${module.redis_langsmith[0].password}@${module.redis_langsmith[0].host}:${module.redis_langsmith[0].port}/${local.redis_db_index.langsmith}"
  }
  type = "Opaque"
}

# SmithDB's object store. RustFS instead of MinIO (community edition no longer
# maintained). Bucket "smithdb"; SmithDB writes under its smithdb/ prefix.
module "rustfs_smithdb" {
  source = "./modules/rustfs"
  count  = var.object_store_source == "in-cluster" ? 1 : 0

  namespace          = "rustfs-smithdb"
  image              = var.rustfs_image
  bucket             = "smithdb"
  extra_buckets      = concat(var.enable_blob_storage ? [local.blob_bucket] : [], var.enable_sandboxes ? [local.juicefs_bucket] : [])
  ttl_buckets        = var.enable_blob_storage ? [local.blob_bucket] : []
  ttl_days           = var.blob_storage_ttl_days
  aws_cli_image      = var.aws_cli_image
  storage_size       = local.datastores_k8s.rustfs_smithdb.storage
  storage_class      = local.storage_class_retain
  resources          = { requests = local.datastores_k8s.rustfs_smithdb.requests, limits = local.datastores_k8s.rustfs_smithdb.limits }
  allowed_namespaces = [kubernetes_namespace_v1.langsmith.metadata[0].name]
  allowed_cidrs      = var.enable_sandboxes ? var.sandbox_source_cidrs : []
  datastore_label    = local.datastore_label

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host]
}

#------------------------------------------------------------------------------
# Standalone products (Fleet, Polly, Insights): same Secrets as modules/gcp,
# created only for enabled flags, before Helm runs. Each gets its own logical
# database on postgres-langsmith and its own Redis DB on redis-langsmith.
# The chart reads postgres_connection_url WITH a scheme (unlike the core URL).
#------------------------------------------------------------------------------
# With an external Postgres each product's database and Secret are the customer's (postgres_secret).
resource "kubernetes_secret_v1" "standalone_postgres" {
  for_each = var.postgres_source == "in-cluster" ? local.standalone_features : {}

  metadata {
    name      = "langsmith-${each.key}-postgres"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    postgres_connection_url = "postgresql://${urlencode(module.postgres_langsmith[0].username)}:${urlencode(module.postgres_langsmith[0].password)}@${module.postgres_langsmith[0].host}:${module.postgres_langsmith[0].port}/${each.value}?sslmode=disable"
  }
  type = "Opaque"

  depends_on = [module.postgres_langsmith]
}

# With an external Redis each product's Redis and Secret are the customer's (redis_secret).
resource "kubernetes_secret_v1" "standalone_redis" {
  for_each = var.redis_source == "in-cluster" ? local.standalone_features : {}

  metadata {
    name      = "langsmith-${each.key}-redis"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    redis_connection_url = "redis://:${module.redis_langsmith[0].password}@${module.redis_langsmith[0].host}:${module.redis_langsmith[0].port}/${local.redis_db_index[each.key]}"
  }
  type = "Opaque"
}
