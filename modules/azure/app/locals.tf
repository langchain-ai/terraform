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
  # Fleet's tool/trigger servers get annotated too, matching the helm/scripts
  # path (init-values.sh emits their WI blocks).
  wi_components = concat(
    ["platformBackend", "backend", "ingestQueue", "queue"],
    var.enable_agent_deploys ? ["hostBackend", "listener", "operator"] : [],
    var.enable_fleet ? ["fleetToolServer", "fleetTriggerServer"] : [],
  )

  # Ingress class per controller — mirrors helm/scripts/init-values.sh.
  # Empty for envoy-gateway (Gateway API) and none (bring your own).
  ingress_class = lookup({
    nginx         = "nginx"
    istio         = "istio"
    "istio-addon" = "istio"
    agic          = "azure-application-gateway"
  }, local.ingress_controller, "")

  # Gateway-based controllers render a Gateway/istioGateway instead of an Ingress.
  use_ingress_resource = !contains(["envoy-gateway", "istio-addon"], local.ingress_controller)

  # Ingress / gateway values, matching init-values.sh per controller.
  # NOTE: some ingress/TLS setup is imperative and ONLY helm/scripts/deploy.sh
  # performs it; the Terraform app path does not. Use the shell path (make deploy)
  # for:
  #   - letsencrypt (HTTP-01) TLS   — deploy.sh creates the letsencrypt-prod ClusterIssuer
  #   - istio                       — deploy.sh creates the "istio" IngressClass
  #   - istio-addon / envoy-gateway — deploy.sh creates the Gateway/GatewayClass and
  #                                   syncs langsmith-tls into the gateway namespace
  # The TF path is complete for: nginx and agic (their IngressClass ships with the
  # controller), TLS source none/existing, and dns01 (whose ClusterIssuer is created
  # by the infra k8s-bootstrap module, not deploy.sh).
  # Built with merge() of single-key fragments so every conditional stays a
  # map-unifiable "{ key = val } : {}" — Terraform rejects conditionals whose two
  # branches are heterogeneous objects (an object with mixed value types cannot
  # unify with the empty object {}).
  ingress_values = merge(
    {
      ingress = merge(
        { enabled = local.use_ingress_resource },
        local.use_ingress_resource && local.ingress_class != "" ? { ingressClassName = local.ingress_class } : {},
        # cert-manager wiring for the standard Ingress path (letsencrypt / dns01).
        # Split into single-key fragments so each conditional collapses to a map.
        contains(["letsencrypt", "dns01"], local.tls_certificate_source) ? { annotations = { "cert-manager.io/cluster-issuer" = "letsencrypt-prod" } } : {},
        contains(["letsencrypt", "dns01"], local.tls_certificate_source) ? { tls = [{ secretName = "langsmith-tls", hosts = [local.hostname] }] } : {},
      )
    },
    local.ingress_controller == "envoy-gateway" ? {
      gateway = { enabled = true, name = "langsmith-gateway", namespace = local.namespace }
    } : {},
    local.ingress_controller == "istio-addon" ? {
      istioGateway = { enabled = true, name = "langsmith-gateway", namespace = local.namespace }
    } : {},
  )

  # External Postgres/Redis: point the chart at the Terraform-created K8s secrets
  # (langsmith-postgres-secret / langsmith-redis-secret from the k8s-bootstrap module).
  # In-cluster mode disables external so the chart provisions its own. Built as a
  # single object with a merge()'d external block — no top-level conditional, so
  # the branch-type unification rule never trips.
  postgres_values = {
    postgres = {
      external = merge(
        { enabled = var.postgres_source == "external" },
        var.postgres_source == "external" ? {
          existingSecretName     = "langsmith-postgres-secret"
          connectionUrlSecretKey = "connection_url"
        } : {},
      )
    }
  }

  redis_values = {
    redis = {
      external = merge(
        { enabled = var.redis_source == "external" },
        var.redis_source == "external" ? {
          existingSecretName     = "langsmith-redis-secret"
          connectionUrlSecretKey = "connection_url"
        } : {},
        # Azure Managed Redis (Enterprise) connects with a standalone client and
        # requires cluster-safe operations; classic Azure Cache leaves this false.
        var.redis_source == "external" && var.redis_cluster_safe_mode ? { clusterSafeMode = true } : {},
      )
    }
  }

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

  # Dynamic Helm overrides layered on top of the Azure base (helm/values/values.yaml).
  # Equivalent to the per-deploy values init-values.sh writes into values-overrides.yaml:
  # hostname, admin email, storage account/container, Workload Identity, ingress/TLS,
  # and the external Postgres/Redis toggles. Static Azure defaults (auth, blob engine,
  # config secret name) live in the base file.
  overrides_values = merge(
    {
      config = {
        hostname             = local.hostname
        initialOrgAdminEmail = var.admin_email
        deployment = {
          url = "${local.protocol}://${local.hostname}"
        }
        blobStorage = {
          azureStorageAccountName   = local.storage_account_name
          azureStorageContainerName = local.storage_container_name
        }
      }
    },
    var.enable_usage_telemetry ? {
      commonEnv = [{ name = "PHONE_HOME_USAGE_REPORTING_ENABLED", value = "true" }]
    } : {},
    # Workload Identity per component: the pod label enables the mutating webhook,
    # the service-account annotation binds the managed identity. The webhook injects
    # AZURE_CLIENT_ID + the federated token — no static credentials needed.
    { for component in local.wi_components : component => {
      deployment     = { labels = { "azure.workload.identity/use" = "true" } }
      serviceAccount = { annotations = local.wi_annotations }
    } },
    local.ingress_values,
    local.postgres_values,
    local.redis_values,
  )
}
