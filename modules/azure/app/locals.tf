#------------------------------------------------------------------------------
# Resolve infrastructure values
#
# Each value: explicit variable wins, otherwise auto-detected or precondition error.
# pull-infra-outputs.sh (make init-app) populates all infra values from the
# infra module's terraform output.
#------------------------------------------------------------------------------

locals {
  subscription_id             = var.subscription_id
  resource_group_name         = var.resource_group_name
  cluster_name                = var.cluster_name
  keyvault_name               = var.keyvault_name
  storage_account_name        = var.storage_account_name
  storage_container_name      = var.storage_container_name
  workload_identity_client_id = var.workload_identity_client_id
  namespace                   = var.langsmith_namespace
  tls_certificate_source      = var.tls_certificate_source
  ingress_controller          = var.ingress_controller

  # Helm values path — reads from the active values directory (same files the scripts path uses).
  # init-values.sh copies from examples/ into values/ on first run.
  values_path = coalesce(var.helm_values_path, "${path.module}/../helm/values")

  # Hostname resolution: explicit → dns_label (works for all ingress controllers) → empty
  hostname = coalesce(
    var.hostname,
    var.dns_label != null && var.dns_label != "" ? "${var.dns_label}.${data.azurerm_kubernetes_cluster.this.location}.cloudapp.azure.com" : null,
    ""
  )

  protocol                = local.tls_certificate_source == "none" ? "http" : "https"
  tls_enabled_for_deploys = var.tls_enabled_for_deploys != null ? var.tls_enabled_for_deploys : (local.tls_certificate_source != "none")

  # Workload Identity annotation — annotates service accounts for blob storage access.
  # Equivalent to AWS IRSA annotations.
  wi_annotations = {
    "azure.workload.identity/client-id" = local.workload_identity_client_id
  }

  # Components that need Workload Identity service account annotations.
  wi_components = concat(
    ["platformBackend", "backend", "ingestQueue", "queue"],
    var.enable_agent_deploys ? ["hostBackend", "listener", "operator"] : [],
  )

  # Agent deploys override — only the dynamic tlsEnabled field.
  agent_deploys_overrides = {
    config = {
      deployment = {
        tlsEnabled = local.tls_enabled_for_deploys
      }
    }
  }

  # Insights override — ClickHouse connection details from variables.
  insights_overrides = {
    clickhouse = {
      external = {
        host               = var.clickhouse_host
        port               = tostring(var.clickhouse_port)
        database           = var.clickhouse_database
        user               = var.clickhouse_username
        tls                = var.clickhouse_tls
        existingSecretName = "langsmith-clickhouse"
      }
    }
  }

  # Full Helm overrides — equivalent to what init-values.sh writes into values-overrides.yaml.
  overrides_values = merge(
    {
      config = {
        hostname             = local.hostname
        initialOrgAdminEmail = var.admin_email
        deployment = {
          url = "${local.protocol}://${local.hostname}"
        }
        blobStorage = {
          enabled        = true
          bucketName     = local.storage_container_name
          storageAccount = local.storage_account_name
          connectionString = ""  # empty — Workload Identity handles auth, no key needed
        }
      }
      commonEnv = concat(
        [
          { name = "AZURE_CLIENT_ID", value = local.workload_identity_client_id },
        ],
        var.enable_usage_telemetry ? [{ name = "PHONE_HOME_USAGE_REPORTING_ENABLED", value = "true" }] : [],
      )
      # Workload Identity annotations on each component's service account
      for component in local.wi_components : component => {
        serviceAccount = {
          annotations = local.wi_annotations
        }
      }
    },
    # Postgres/Redis: disable external if using in-cluster
    var.postgres_source != "external" ? { postgres = { external = { enabled = false } } } : {},
    var.redis_source != "external" ? { redis = { external = { enabled = false } } } : {},
  )
}
