#------------------------------------------------------------------------------
# Everything this root creates in the cluster, in dependency order:
#   metrics-server         pod metrics for HPAs and kubectl top
#   local-path             StorageClasses on node-local disk (Delete, Retain)
#   MetalLB                LoadBalancer IPs from metallb_addresses (L2)
#   namespace langsmith    where the Helm chart installs LangSmith and SmithDB
#   Envoy Gateway          the Gateway LangSmith's HTTPRoute attaches to
#   cloudflared            optional Cloudflare Tunnel connector
#   datastores             Postgres x2, Redis, RustFS: one release of
#                          charts/datastores (datastores.tf)
#   Secrets in langsmith   connection details the chart reads by name
#
# Everything waits for the budget gate (budget.tf), so nothing is created on a
# cluster that can't hold the chosen sizing profile. Sizes, names and Helm
# values come from modules/values (values.tf).
#------------------------------------------------------------------------------

module "metrics_server" {
  source = "./modules/metrics-server"
  count  = var.install_metrics_server ? 1 : 0

  chart_version        = var.metrics_server_chart_version
  kubelet_insecure_tls = var.metrics_server_kubelet_insecure_tls
  resources = {
    requests = { cpu = "${module.values.addon_pods["metrics-server"].cpu_m}m", memory = "${module.values.addon_pods["metrics-server"].mem_mi}Mi" }
    limits   = { cpu = "500m", memory = "${module.values.addon_pods["metrics-server"].mem_mi * 2}Mi" }
  }

  # Everything that runs a pod waits for the sandbox and SmithDB taints: those nodes take nothing else,
  # and a pod scheduled there before the taint stays (a datastore binds its volume to that node).
  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
}

module "local_path" {
  source = "./modules/local-path"
  count  = var.install_local_path ? 1 : 0

  storage_class_delete = module.values.storage_classes.delete
  storage_class_retain = module.values.storage_classes.retain
  image                = var.local_path_image
  helper_image         = var.local_path_helper_image
  node_path            = var.local_path_node_path
  resources = {
    requests = { cpu = "${module.values.addon_pods["local-path-provisioner"].cpu_m}m", memory = "${module.values.addon_pods["local-path-provisioner"].mem_mi}Mi" }
    limits   = { cpu = "200m", memory = "${module.values.addon_pods["local-path-provisioner"].mem_mi * 2}Mi" }
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
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
    requests = { cpu = "${module.values.addon_pods["metallb-controller"].cpu_m}m", memory = "${module.values.addon_pods["metallb-controller"].mem_mi}Mi" }
    limits   = { cpu = "500m", memory = "256Mi" }
  }
  speaker_resources = {
    requests = { cpu = "${module.values.addon_pods["metallb-speaker"].cpu_m}m", memory = "${module.values.addon_pods["metallb-speaker"].mem_mi}Mi" }
    limits   = { cpu = "200m", memory = "128Mi" }
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
}

# Terraform owns the langsmith namespace, so the Gateway (and later the
# datastore Secrets) exist before Helm installs LangSmith into it.
# Pinned pods first, as a placement that fits them assumes: arrival order once let pods free to run on
# several nodes fill the one node a SmithDB ingestion pod could use, and two of three sat Pending.
resource "kubernetes_priority_class_v1" "pinned" {
  count = var.pinned_priority_class != "" ? 1 : 0

  metadata {
    name = var.pinned_priority_class
  }
  value             = 1000000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Pods pinned to one node: they preempt pods that can run elsewhere."
}

resource "kubernetes_namespace_v1" "langsmith" {
  metadata {
    name = module.values.namespace
    # sandbox-host runs privileged with host networking: Pod Security Admission must allow it here.
    labels = var.enable_sandboxes ? { "pod-security.kubernetes.io/enforce" = "privileged" } : {}
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
}

module "envoy_gateway" {
  source = "./modules/envoy-gateway"
  count  = var.install_envoy_gateway ? 1 : 0

  chart_version     = var.envoy_gateway_chart_version
  load_balancer_ip  = var.install_metallb ? var.envoy_gateway_lb_ip : ""
  route_timeout     = var.envoy_gateway_route_timeout
  gateway_namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  gateway_name      = module.values.gateway.name
  controller_resources = {
    requests = { cpu = "${module.values.addon_pods["envoy-gateway"].cpu_m}m", memory = "${module.values.addon_pods["envoy-gateway"].mem_mi}Mi" }
    limits   = { cpu = "500m", memory = "512Mi" }
  }
  proxy_node_selector = var.envoy_proxy_node_selector
  proxy_resources = {
    requests = { cpu = "${module.values.addon_pods["envoy-proxy"].cpu_m}m", memory = "${module.values.addon_pods["envoy-proxy"].mem_mi}Mi" }
    limits   = { cpu = "1", memory = "512Mi" }
  }
  tls = var.gateway_tls_secret == "" ? null : { hostname = var.langsmith_domain, secret_name = var.gateway_tls_secret }
  # With a domain, the chart's HTTPRoute matches only that Host; keep the LAN IP
  # serving LangSmith too.
  lan_route = {
    enabled         = local.lan_route
    backend_service = "langsmith-frontend"
    backend_port    = 80
  }

  depends_on = [module.metallb, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
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
  replicas     = module.values.addon_pods["cloudflared"].replicas
  resources = {
    requests = { cpu = "${module.values.addon_pods["cloudflared"].cpu_m}m", memory = "${module.values.addon_pods["cloudflared"].mem_mi}Mi" }
    limits   = { memory = "256Mi" }
  }

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
}

# KEDA, for LangSmith Deployments only: the operator creates a ScaledObject per
# agent deployment (chart default operator.kedaEnabled: true). Sized from the
# same addon_pods entries the budget counts.
resource "helm_release" "keda" {
  count = module.values.install_keda ? 1 : 0

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
          requests = { cpu = "${module.values.addon_pods["keda-operator"].cpu_m}m", memory = "${module.values.addon_pods["keda-operator"].mem_mi}Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        metricServer = {
          requests = { cpu = "${module.values.addon_pods["keda-metrics-server"].cpu_m}m", memory = "${module.values.addon_pods["keda-metrics-server"].mem_mi}Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        webhooks = {
          requests = { cpu = "${module.values.addon_pods["keda-webhooks"].cpu_m}m", memory = "${module.values.addon_pods["keda-webhooks"].mem_mi}Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
    })
  ]

  depends_on = [terraform_data.budget, kubernetes_node_taint.sandbox_host, kubernetes_node_taint.smithdb_node]
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
    name      = module.values.secret_names.postgres
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    connection_url = "${local.postgres.langsmith.username}:${local.postgres.langsmith.password}@${local.postgres.langsmith.host}:${local.postgres.langsmith.port}/${local.postgres.langsmith.database}"
  }
  type = "Opaque"
}

# An external metastore, read from its Secret: SmithDB takes one Secret for its metastore and its
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
    host     = local.postgres.smithdb.host
    db       = local.postgres.smithdb.database
    user     = local.postgres.smithdb.username
    password = local.postgres.smithdb.password
  }
}

# An external object store, its keys read from its Secret into smithdb-config, as the metastore's.
# With object_store_secret_managed the module writes that Secret itself: read from a namespace this same
# apply creates, a first install stopped until someone made the Secret by hand and applied again.
locals {
  object_store_keys_given = var.object_store_source == "external" && var.object_store_secret_managed
}

data "kubernetes_secret_v1" "object_store" {
  count = var.object_store_source == "external" && !local.object_store_keys_given ? 1 : 0
  metadata {
    name      = var.object_store_secret
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
}

resource "kubernetes_secret_v1" "object_store" {
  count = local.object_store_keys_given ? 1 : 0
  metadata {
    name      = var.object_store_secret
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    access_key_id     = var.object_store_access_key_id
    secret_access_key = var.object_store_secret_access_key
  }
}

locals {
  object_store_keys = var.object_store_source != "external" ? {} : local.object_store_keys_given ? kubernetes_secret_v1.object_store[0].data : data.kubernetes_secret_v1.object_store[0].data
  # Where it is (modules/values), with its keys: theirs, or the ones generated for RustFS.
  object_store = merge(module.values.object_store, var.object_store_source == "external" ? {
    access_key = local.object_store_keys["access_key_id"]
    secret_key = local.object_store_keys["secret_access_key"]
  } : local.rustfs_keys)
}

# Their buckets, as charts/datastores makes ours: head-bucket first, so a bucket they made is left as it
# is, rules and all, and the keys need no right to create one that exists. Only a bucket this Job
# creates gets the blob expiry: without it the blob bucket grows without bound (57 GB in two lab days).
resource "kubernetes_job_v1" "object_store_bucket" {
  # Keyed by role, not bucket name: a Job's name is at most 63 characters and a bucket's alone can be 63
  # (Dzmitry Dubarau's review of #488).
  for_each = var.object_store_source == "external" ? { for role, bucket in var.object_store_buckets : role => bucket if role == "smithdb" || var.enable_blob_storage } : {}

  metadata {
    name      = "create-bucket-${each.key}"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "object-store-bucket-init" }
      }

      spec {
        restart_policy = "OnFailure"

        security_context {
          run_as_user     = 10001
          run_as_group    = 10001
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "create-bucket"
          image   = var.aws_cli_image
          command = ["sh", "-c"]
          args = [<<-EOT
            set -eu
            if aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
              echo "bucket $BUCKET exists: left as it is"
              exit 0
            fi
            # us-east-1 takes no LocationConstraint and refuses one; any other region needs it, since
            # Ceph RGW checks it against its zonegroup (Dzmitry Dubarau's review of #488).
            if [ "$AWS_DEFAULT_REGION" = "us-east-1" ]; then
              aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$BUCKET"
            else
              aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$BUCKET" \
                --create-bucket-configuration "LocationConstraint=$AWS_DEFAULT_REGION"
            fi
            echo "bucket $BUCKET created"
            if [ -n "$LIFECYCLE" ]; then
              aws --endpoint-url "$S3_ENDPOINT" s3api put-bucket-lifecycle-configuration \
                --bucket "$BUCKET" --lifecycle-configuration "$LIFECYCLE"
              echo "bucket $BUCKET expires ttl_s/ and ttl_l/ objects"
            fi
          EOT
          ]

          env {
            name  = "S3_ENDPOINT"
            value = var.object_store_endpoint
          }
          env {
            name  = "BUCKET"
            value = each.value
          }
          env {
            name = "LIFECYCLE"
            value = each.key == "blobs" ? jsonencode({
              Rules = [
                { ID = "ttl-short", Status = "Enabled", Filter = { Prefix = "ttl_s/" }, Expiration = { Days = var.blob_storage_ttl_days.short } },
                { ID = "ttl-long", Status = "Enabled", Filter = { Prefix = "ttl_l/" }, Expiration = { Days = var.blob_storage_ttl_days.long } },
              ]
            }) : ""
          }
          env {
            name  = "AWS_DEFAULT_REGION"
            value = var.object_store_region
          }
          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = var.object_store_secret
                key  = "access_key_id"
              }
            }
          }
          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = var.object_store_secret
                key  = "secret_access_key"
              }
            }
          }
          # aws-cli writes a cache under $HOME; the non-root user has none.
          env {
            name  = "HOME"
            value = "/tmp"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
  }

  depends_on = [kubernetes_secret_v1.object_store]
}

resource "kubernetes_secret_v1" "smithdb_config" {
  metadata {
    name      = module.values.secret_names.smithdb
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

# LangSmith core reads REDIS_DATABASE_URI from connection_url. Unlike the
# Postgres core URL, the chart's Redis URL INCLUDES the scheme. /0 selects
# logical DB 0 (1 Fleet, 2 Polly, 3 Insights: redis_db_index in modules/values, as in modules/gcp).
resource "kubernetes_secret_v1" "langsmith_redis" {
  count = var.redis_source == "in-cluster" ? 1 : 0

  metadata {
    name      = module.values.secret_names.redis
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    connection_url = "redis://:${local.redis.langsmith.password}@${local.redis.langsmith.host}:${local.redis.langsmith.port}/${module.values.redis_db_index.langsmith}"
  }
  type = "Opaque"
}

#------------------------------------------------------------------------------
# Standalone products (Fleet, Polly, Insights): same Secrets as modules/gcp,
# created only for enabled flags, before Helm runs. Each gets its own logical
# database on postgres-langsmith and its own Redis DB on redis-langsmith.
# The chart reads postgres_connection_url WITH a scheme (unlike the core URL).
#------------------------------------------------------------------------------
# With an external Postgres each product's database and Secret are created outside the module (postgres_secret).
resource "kubernetes_secret_v1" "standalone_postgres" {
  for_each = var.postgres_source == "in-cluster" ? module.values.standalone_features : {}

  metadata {
    name      = "langsmith-${each.key}-postgres"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    postgres_connection_url = "postgresql://${urlencode(local.postgres.langsmith.username)}:${urlencode(local.postgres.langsmith.password)}@${local.postgres.langsmith.host}:${local.postgres.langsmith.port}/${each.value}?sslmode=disable"
  }
  type = "Opaque"

  depends_on = [helm_release.datastores]
}

# With an external Redis each product's Redis and Secret are created outside the module (redis_secret).
resource "kubernetes_secret_v1" "standalone_redis" {
  for_each = var.redis_source == "in-cluster" ? module.values.standalone_features : {}

  metadata {
    name      = "langsmith-${each.key}-redis"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    redis_connection_url = "redis://:${local.redis.langsmith.password}@${local.redis.langsmith.host}:${local.redis.langsmith.port}/${module.values.redis_db_index[each.key]}"
  }
  type = "Opaque"
}
