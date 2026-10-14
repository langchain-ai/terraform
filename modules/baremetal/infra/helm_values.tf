#------------------------------------------------------------------------------
# Helm values computed by Terraform (same idea as smithdb_helm_values in
# modules/gcp/infra/locals.tf). The budget and the values read the same tables,
# so they can't drift. Nothing here is secret: only Secret *names* and keys.
# helm/scripts/init-values.sh writes these outputs to helm/values/.
#------------------------------------------------------------------------------

variable "langsmith_domain" {
  type        = string
  default     = ""
  description = "Hostname for LangSmith (e.g. langsmith.lab.example.com). Empty uses the Envoy Gateway IP, as modules/gcp does without a domain."
}

variable "langsmith_url_scheme" {
  type        = string
  default     = "http"
  description = "Scheme of the URL users reach LangSmith on. https when TLS terminates in front of the gateway (e.g. a Cloudflare Tunnel); the gateway listener itself stays HTTP."

  validation {
    condition     = contains(["http", "https"], var.langsmith_url_scheme)
    error_message = "langsmith_url_scheme must be http or https."
  }

  validation {
    condition     = var.langsmith_url_scheme == "http" || var.langsmith_domain != ""
    error_message = "langsmith_url_scheme = \"https\" needs langsmith_domain: no certificate covers the bare gateway IP."
  }
}

locals {
  langsmith_host = var.langsmith_domain != "" ? var.langsmith_domain : var.envoy_gateway_lb_ip
  # The chart assumes https:// when the hostname has no scheme, so the scheme
  # is explicit.
  langsmith_url = "${var.langsmith_url_scheme}://${local.langsmith_host}"

  blob_bucket = "langsmith-blobs"

  langsmith_values = merge(
    {
      config = merge(
        { hostname = local.langsmith_url },
        # Deployments: the operator builds each agent's endpoint URL from the
        # hostname, so tlsEnabled must match its scheme (a mismatch leaves agent
        # deployments stuck in DEPLOYING).
        var.enable_deployments ? {
          deployment = {
            enabled    = true
            tlsEnabled = var.langsmith_url_scheme == "https"
          }
        } : {},
        # Payload offload to the same RustFS as SmithDB, separate bucket. Keys
        # come from langsmith-config (deploy.sh copies them from smithdb-config).
        var.enable_blob_storage ? {
          blobStorage = {
            enabled              = true
            engine               = "S3"
            bucketName           = local.blob_bucket
            apiURL               = module.rustfs_smithdb.endpoint
            s3UsePathStyle       = true
            minBlobStorageSizeKb = tostring(var.blob_storage_min_size_kb)
          }
        } : {},
      )
      gateway = {
        enabled   = true
        name      = module.envoy_gateway.gateway.name
        namespace = module.envoy_gateway.gateway.namespace
      }
    },
    # Deployments components, sized from the same table the budget counts
    # (feature_pod_sizes), so the two can't drift. Limits are the chart defaults.
    var.enable_deployments ? {
      hostBackend = { deployment = { resources = {
        requests = { cpu = "${local.feature_pod_sizes.deployments["host-backend"].cpu_m}m", memory = "${local.feature_pod_sizes.deployments["host-backend"].mem_mi}Mi" }
        limits   = { cpu = "1000m", memory = "2Gi" }
      } } }
      listener = { deployment = { resources = {
        requests = { cpu = "${local.feature_pod_sizes.deployments.listener.cpu_m}m", memory = "${local.feature_pod_sizes.deployments.listener.mem_mi}Mi" }
        limits   = { cpu = "2000m", memory = "4Gi" }
      } } }
      operator = { deployment = { resources = {
        requests = { cpu = "${local.feature_pod_sizes.deployments.operator.cpu_m}m", memory = "${local.feature_pod_sizes.deployments.operator.mem_mi}Mi" }
        limits   = { cpu = "2000m", memory = "4Gi" }
      } } }
    } : {},
    # Same env var as modules/aws: extended usage reporting on every component.
    var.enable_usage_telemetry ? {
      commonEnv = [{ name = "PHONE_HOME_USAGE_REPORTING_ENABLED", value = "true" }]
    } : {},
  )

  #----------------------------------------------------------------------------
  # SmithDB. minimal (minimum, lab): the chart's small tier with explicit
  # resources, like modules/gcp, plus cache sized by deployment.volumes (an
  # explicit resources block does not change cache size) and HPAs pinned to 1.
  # Larger tiers keep the chart tier and use PVC caches on the default class.
  #----------------------------------------------------------------------------
  smithdb_minimal = local.smithdb_tier_name == "minimal"

  smithdb_scheduling_values = {
    for kind, comps in { cache = local.smithdb_cache_components, compute = ["compaction", "clusterManager"] } : kind => (
      # Through JSON: Terraform won't unify an object with {} in a conditional
      # ("Inconsistent conditional result types"); strings always unify, and
      # jsondecode gives back a dynamically typed value.
      jsondecode(local.smithdb_scheduling[kind] != null ? jsonencode({
        nodeSelector = local.smithdb_scheduling[kind].node_selector
        tolerations  = local.smithdb_scheduling[kind].tolerations
      }) : "{}")
    )
  }

  smithdb_component_values = {
    for c, t in local.smithdb_tier : c => merge(
      {
        deployment = merge(
          contains(local.smithdb_cache_components, c) ? local.smithdb_scheduling_values.cache : local.smithdb_scheduling_values.compute,
          local.smithdb_minimal ? {
            resources = t.cache != "0" ? {
              requests = merge(t.requests, { "ephemeral-storage" = t.cache })
              limits   = merge(t.limits, { "ephemeral-storage" = t.cache })
            } : { requests = t.requests, limits = t.limits }
          } : {},
          local.smithdb_minimal && t.cache != "0" ? {
            volumes = [{ name = "cache", emptyDir = { sizeLimit = t.cache } }]
          } : {},
        )
      },
      local.smithdb_minimal && contains(local.smithdb_cache_components, c) ? {
        autoscaling = { hpa = { minReplicas = 1, maxReplicas = 1 } }
      } : {},
    )
  }

  smithdb_values = {
    smithdb = merge(
      {
        enabled      = true
        resourceTier = local.smithdb_minimal ? "small" : local.smithdb_tier_name
        langsmith = {
          ingestion = { enabled = true }
          query     = { enabled = true }
          migration = { enabled = false } # needs ClickHouse; we run SmithDB-only
        }
        config = {
          existingSecretName = kubernetes_secret_v1.smithdb_config.metadata[0].name
          metastore = {
            hostSecretKey     = "smithdb_metastore_host"
            databaseSecretKey = "smithdb_metastore_db"
            usernameSecretKey = "smithdb_metastore_user"
            passwordSecretKey = "smithdb_metastore_password"
            port              = "5432"
            useSsl            = false
          }
          objectStore = {
            type   = "s3"
            bucket = module.rustfs_smithdb.bucket
            s3 = {
              region                   = "us-east-1" # any value; RustFS ignores it, the SDK needs one
              endpoint                 = module.rustfs_smithdb.endpoint
              allowHttp                = true # in-cluster RustFS speaks plain HTTP
              accessKeyIdSecretKey     = "smithdb_s3_access_key"
              secretAccessKeySecretKey = "smithdb_s3_secret_key"
            }
          }
        }
      },
      local.smithdb_minimal ? {} : { cache = { storageClassName = module.local_path.storage_class_delete } },
      local.smithdb_component_values,
    )
  }
}

output "langsmith_helm_values" {
  description = "Environment overrides for the LangSmith chart (hostname, gateway). init-values.sh writes it as YAML. No secrets."
  value       = local.langsmith_values
}

output "smithdb_helm_values" {
  description = "SmithDB values for the sizing profile (resources, cache, object store, metastore keys). init-values.sh writes it as YAML. No secrets."
  value       = local.smithdb_values
}

output "langsmith_url" {
  description = "URL to open LangSmith."
  value       = local.langsmith_url
}
