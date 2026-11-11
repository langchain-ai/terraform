#------------------------------------------------------------------------------
# The in-cluster datastores: one Helm release of the local chart charts/datastores, which runs each
# store as a plain StatefulSet or through an operator (datastore_runtime). One release and one values
# document, so the same chart and values can be applied without this module, with your own
# Helm or Argo CD (charts/datastores/README.md). An external store (<store>_source = external)
# is not in the chart.
#
# Terraform keeps generating the passwords and S3 keys and passes them in as a second values document,
# beside the first that holds everything else (the output datastore_values): the chart then renders the
# Secrets each store reads exactly as the store modules did (names, keys, the Redis password inside
# redis.conf rather than on a command line), and the connection Secrets in LangSmith's namespace are
# built from the same passwords. Applying the chart without the module keeps the same split: the values in
# git, the passwords in a values file that is not.
#------------------------------------------------------------------------------

variable "datastore_runtime" {
  type        = string
  default     = "statefulset"
  description = "How the in-cluster Postgres and Redis run. statefulset: one plain StatefulSet each on the official image. operator: Postgres as a CloudNativePG Cluster and Redis as an OpsTree RedisReplication, the module installing both operators. RustFS has no operator and is a StatefulSet either way. Hosts, ports and Secret keys are the same in both."

  validation {
    condition     = contains(["statefulset", "operator"], var.datastore_runtime)
    error_message = "datastore_runtime must be statefulset or operator."
  }
}

variable "datastore_namespace" {
  type        = string
  default     = "langsmith-data"
  description = "The one namespace every in-cluster store runs in, beside LangSmith's, each named for its instance (postgres-langsmith, postgres-smithdb, redis-langsmith, redis-juicefs, rustfs): a shared cluster gets one data namespace per environment, not one per store. The module creates it unless it is LangSmith's own."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.datastore_namespace)) && length(var.datastore_namespace) <= 63
    error_message = "datastore_namespace must be a Kubernetes namespace name."
  }
}

variable "datastore_replicas" {
  type        = number
  default     = 1
  description = "Pods per Postgres and per Redis instance. With datastore_runtime = operator: 1, 2 or 3, a primary and up to two replicas the operator fails over to (CloudNativePG instances; a Redis replication with three Sentinels above 1), each counted by the budget with its own volume. With statefulset: 1. RustFS is one pod either way."

  validation {
    condition     = var.datastore_runtime == "operator" ? contains([1, 2, 3], var.datastore_replicas) : var.datastore_replicas == 1
    error_message = "datastore_replicas must be 1 with datastore_runtime = statefulset (a StatefulSet here is one pod with no failover) and 1, 2 or 3 with operator (a primary and up to two replicas)."
  }
}

variable "cnpg_chart_version" {
  type        = string
  default     = "0.29.1"
  description = "CloudNativePG operator Helm chart version (https://cloudnative-pg.github.io/charts; 0.29.1 is operator 1.30.1). Installed only with datastore_runtime = operator and an in-cluster Postgres."
}

variable "cnpg_postgres_image" {
  type        = string
  default     = "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie"
  description = "Postgres operand image for CloudNativePG, the same major and minor as postgres_image: the operator needs its own images (cloudnative-pg.io/documentation, Container Image Requirements)."
}

variable "redis_operator_chart_version" {
  type        = string
  default     = "0.27.0"
  description = "OpsTree Redis operator Helm chart version (https://ot-container-kit.github.io/helm-charts). Installed only with datastore_runtime = operator and an in-cluster Redis."
}

variable "opstree_redis_image" {
  type        = string
  default     = "quay.io/opstree/redis:v7.4.11"
  description = "Redis image for the OpsTree operator, the same version as redis_image: the operator drives the image's own entrypoint, so the official image does not work under it."
}

variable "redis_sentinel_image" {
  type        = string
  default     = "quay.io/opstree/redis-sentinel:v7.4.11"
  description = "Sentinel image for the OpsTree operator, the same version as opstree_redis_image. Runs with datastore_runtime = operator and datastore_replicas above 1."
}

# The sizes, names and chart values are modules/values'; only the generated passwords and keys are
# added here, so nothing secret leaves this root.
locals {
  # What the rest of the root builds connection Secrets from: each store's address with its password.
  postgres = { for k, p in module.values.postgres : k => merge(p, { password = random_password.postgres[k].result }) }
  redis    = { for k, r in module.values.redis : k => merge(r, { password = random_password.redis[k].result }) }
  rustfs_keys = {
    access_key = one(random_password.rustfs_access_key[*].result)
    secret_key = one(random_password.rustfs_secret_key[*].result)
  }
  # Helm deep-merges this over the chart's values (the output datastore_values).
  datastore_secret_values = {
    postgres = { instances = { for k in module.values.postgres_in_chart : k => { password = random_password.postgres[k].result } } }
    redis    = { instances = { for k in module.values.redis_in_chart : k => { password = random_password.redis[k].result } } }
    # null without RustFS: Helm drops a null key, and Terraform will not unify an object with {}.
    rustfs = { accessKey = local.rustfs_keys.access_key, secretKey = local.rustfs_keys.secret_key }
  }
}

# URL-safe (no special characters): each sits inside a connection URL.
resource "random_password" "postgres" {
  for_each = toset(module.values.postgres_in_chart)
  length   = 32
  special  = false
}

resource "random_password" "redis" {
  for_each = toset(module.values.redis_in_chart)
  length   = 32
  special  = false
}

resource "random_password" "rustfs_access_key" {
  count   = module.values.rustfs.enabled ? 1 : 0
  length  = 20
  special = false
}

resource "random_password" "rustfs_secret_key" {
  count   = module.values.rustfs.enabled ? 1 : 0
  length  = 40
  special = false
}

# The operators are their own releases, before the chart's (modules/values, operator_charts).
resource "helm_release" "cnpg" {
  count = var.datastore_runtime == "operator" && length(module.values.postgres_in_chart) > 0 ? 1 : 0

  name             = module.values.operator_charts.postgres.release
  repository       = module.values.operator_charts.postgres.repository
  chart            = module.values.operator_charts.postgres.chart
  version          = module.values.operator_charts.postgres.version
  namespace        = module.values.operator_charts.postgres.namespace
  create_namespace = true
  # Its webhook must answer before the chart's Clusters are admitted.
  wait = true

  values = [
    yamlencode({
      resources = {
        requests = { cpu = "${module.values.addon_pods["cnpg-operator"].cpu_m}m", memory = "${module.values.addon_pods["cnpg-operator"].mem_mi}Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    })
  ]

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
}

resource "helm_release" "redis_operator" {
  count = var.datastore_runtime == "operator" && length(module.values.redis_in_chart) > 0 ? 1 : 0

  name             = module.values.operator_charts.redis.release
  repository       = module.values.operator_charts.redis.repository
  chart            = module.values.operator_charts.redis.chart
  version          = module.values.operator_charts.redis.version
  namespace        = module.values.operator_charts.redis.namespace
  create_namespace = true
  wait             = true

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
}

resource "helm_release" "datastores" {
  count = length(module.values.sized_datastores) > 0 ? 1 : 0

  name      = "langsmith-datastores"
  chart     = "${path.module}/../charts/datastores"
  namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  # Waits for every StatefulSet, then runs the bucket and database Jobs, as the store modules waited
  # for each rollout and Job. A first Postgres init on a slow disk takes minutes.
  wait    = true
  timeout = 900

  values = [yamlencode(module.values.datastore_values), yamlencode(local.datastore_secret_values)]

  # The StorageClass is named in the values, not taken from local-path's output: wait for it here.
  depends_on = [terraform_data.budget, terraform_data.sandboxes, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node, helm_release.cnpg, helm_release.redis_operator, module.local_path]
}
