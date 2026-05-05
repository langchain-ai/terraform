#------------------------------------------------------------------------------
# LangSmith App Module (Pass 2 — Terraform)
#
# Deploys LangSmith via Helm, assuming infra (Pass 1) is complete.
# Equivalent to helm/scripts/deploy.sh but managed by Terraform.
#
# Prerequisites:
#   - AKS cluster running, Key Vault populated, langsmith-config-secret created
#   - Run: make init-app   (or provide variables manually)
#   - Run: make apply-app
#
# Secret flow: Key Vault secrets → kubernetes_secret.langsmith_config
#   (same secrets that create-k8s-secrets.sh writes manually)
#------------------------------------------------------------------------------

# ── Providers ─────────────────────────────────────────────────────────────────

provider "azurerm" {
  subscription_id = local.subscription_id
  features {}
}

data "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  resource_group_name = local.resource_group_name
}

provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_key)
}

provider "helm" {
  kubernetes {
    host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
    cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
    client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
    client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_key)
  }
}

# ── Key Vault data ────────────────────────────────────────────────────────────
# Read all required LangSmith secrets from Key Vault.
# These are the same secrets that create-k8s-secrets.sh reads manually.

data "azurerm_key_vault" "this" {
  name                = local.keyvault_name
  resource_group_name = local.resource_group_name
}

data "azurerm_key_vault_secret" "license_key" {
  name         = "langsmith-license-key"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "admin_password" {
  name         = "langsmith-admin-password"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "api_key_salt" {
  name         = "langsmith-api-key-salt"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "jwt_secret" {
  name         = "langsmith-jwt-secret"
  key_vault_id = data.azurerm_key_vault.this.id
}

# ── Optional addon secrets ────────────────────────────────────────────────────
# Only read when the corresponding feature is enabled. Like apply-eso.sh on AWS,
# we only include these when the SSM/KV key exists AND the flag is set.

data "azurerm_key_vault_secret" "deployments_key" {
  count        = var.enable_agent_deploys ? 1 : 0
  name         = "langsmith-deployments-encryption-key"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "agent_builder_key" {
  count        = var.enable_agent_builder ? 1 : 0
  name         = "langsmith-agent-builder-encryption-key"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "insights_key" {
  count        = var.enable_insights ? 1 : 0
  name         = "langsmith-insights-encryption-key"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "polly_key" {
  count        = var.enable_polly ? 1 : 0
  name         = "langsmith-polly-encryption-key"
  key_vault_id = data.azurerm_key_vault.this.id
}

# ── K8s Secret: langsmith-config ─────────────────────────────────────────────
# Creates (or updates) the langsmith-config-secret from Key Vault values.
# This is the Terraform equivalent of create-k8s-secrets.sh.
# The Helm chart references this secret via config.existingSecretName.

resource "kubernetes_secret_v1" "langsmith_config" {
  metadata {
    name      = "langsmith-config-secret"
    namespace = local.namespace
  }

  data = merge(
    {
      langsmith_license_key       = data.azurerm_key_vault_secret.license_key.value
      initial_org_admin_password  = data.azurerm_key_vault_secret.admin_password.value
      api_key_salt                = data.azurerm_key_vault_secret.api_key_salt.value
      jwt_secret                  = data.azurerm_key_vault_secret.jwt_secret.value
    },
    var.enable_agent_deploys ? {
      deployments_encryption_key = data.azurerm_key_vault_secret.deployments_key[0].value
    } : {},
    var.enable_agent_builder ? {
      agent_builder_encryption_key = data.azurerm_key_vault_secret.agent_builder_key[0].value
    } : {},
    var.enable_insights ? {
      insights_encryption_key = data.azurerm_key_vault_secret.insights_key[0].value
    } : {},
    var.enable_polly ? {
      polly_encryption_key = data.azurerm_key_vault_secret.polly_key[0].value
    } : {},
  )

  type = "Opaque"

  lifecycle {
    # Secret values come from Key Vault. If they change in KV, a new apply will update the K8s secret.
    # Pods pick up the new value on next restart.
    ignore_changes = []
  }
}

# ── K8s Secret: ClickHouse credentials ───────────────────────────────────────

resource "kubernetes_secret_v1" "clickhouse" {
  count = var.enable_insights ? 1 : 0

  metadata {
    name      = "langsmith-clickhouse"
    namespace = local.namespace
  }

  data = {
    clickhouse_host     = var.clickhouse_host
    clickhouse_port     = tostring(var.clickhouse_port)
    clickhouse_user     = var.clickhouse_username
    clickhouse_password = var.clickhouse_password
    clickhouse_db       = var.clickhouse_database
    clickhouse_tls      = tostring(var.clickhouse_tls)
  }

  type = "Opaque"
}

# ── langsmith-ksa for operator-spawned agent deployment pods ─────────────────
# Creates the SA with Workload Identity annotation so operator-spawned agent pods
# have blob storage access from the start. Equivalent to the langsmith-ksa
# IRSA annotation on AWS.

resource "kubernetes_service_account_v1" "langsmith_ksa" {
  count = var.enable_agent_deploys ? 1 : 0

  metadata {
    name      = "langsmith-ksa"
    namespace = local.namespace
    annotations = local.wi_annotations
    labels = {
      "azure.workload.identity/use" = "true"
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].labels]
  }
}

# ── Helm Release ──────────────────────────────────────────────────────────────

resource "helm_release" "langsmith" {
  depends_on = [kubernetes_secret_v1.langsmith_config, kubernetes_secret_v1.clickhouse]

  name             = var.release_name
  namespace        = local.namespace
  create_namespace = true
  repository       = "https://langchain-ai.github.io/helm"
  chart            = "langsmith"
  version          = var.chart_version != "" ? var.chart_version : null
  timeout          = var.helm_timeout

  # Do NOT use wait = true. The chart's post-install bootstrap job deploys
  # operator-managed agents (clio, polly, agent-builder) which can take 10+
  # minutes on a cold cluster with autoscaling.
  wait = false

  force_update = var.helm_force_update

  # Values layering — YAML files are the single source of truth (shared with helm/scripts path).
  # Files are loaded from helm/values/ (populated by make init-values from examples/).
  values = concat(
    # 1. Base Azure config (NGINX ingress, Blob WI, external PG/Redis)
    [file("${local.values_path}/langsmith-values.yaml")],
    # 2. Dynamic overrides (hostname, WI annotations, storage account)
    [yamlencode(local.overrides_values)],
    # 3. Sizing
    var.sizing == "production"       ? [file("${local.values_path}/langsmith-values-sizing-production.yaml")] : [],
    var.sizing == "production-large" ? [file("${local.values_path}/langsmith-values-sizing-production-large.yaml")] : [],
    var.sizing == "dev"              ? [file("${local.values_path}/langsmith-values-sizing-dev.yaml")] : [],
    # 4. Product addons
    var.enable_agent_deploys ? [file("${local.values_path}/langsmith-values-agent-deploys.yaml"), yamlencode(local.agent_deploys_overrides)] : [],
    var.enable_agent_builder ? [file("${local.values_path}/langsmith-values-agent-builder.yaml")] : [],
    var.enable_insights      ? [file("${local.values_path}/langsmith-values-insights.yaml"), yamlencode(local.insights_overrides)] : [],
    var.enable_polly         ? [file("${local.values_path}/langsmith-values-polly.yaml")] : [],
  )
}

#------------------------------------------------------------------------------
# Preconditions — fail early with clear messages
#------------------------------------------------------------------------------

resource "terraform_data" "validate_required" {
  lifecycle {
    precondition {
      condition     = local.subscription_id != null
      error_message = "subscription_id is required — set var.subscription_id or run: make init-app"
    }
    precondition {
      condition     = local.resource_group_name != null
      error_message = "resource_group_name is required — set var.resource_group_name or run: make init-app"
    }
    precondition {
      condition     = local.cluster_name != null
      error_message = "cluster_name is required — set var.cluster_name or run: make init-app"
    }
    precondition {
      condition     = local.keyvault_name != null
      error_message = "keyvault_name is required — set var.keyvault_name or run: make init-app"
    }
    precondition {
      condition     = local.storage_account_name != null
      error_message = "storage_account_name is required — set var.storage_account_name or run: make init-app"
    }
    precondition {
      condition     = local.workload_identity_client_id != null
      error_message = "workload_identity_client_id is required — set var.workload_identity_client_id or run: make init-app"
    }
    precondition {
      condition     = local.namespace != null
      error_message = "langsmith_namespace is required — set var.langsmith_namespace or run: make init-app"
    }
    precondition {
      condition     = local.tls_certificate_source != null
      error_message = "tls_certificate_source is required — set var.tls_certificate_source or run: make init-app"
    }
    precondition {
      condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.admin_email))
      error_message = "admin_email must be a valid email address — update it in app/terraform.tfvars"
    }
    precondition {
      condition     = !var.enable_agent_builder || var.enable_agent_deploys
      error_message = "enable_agent_builder requires enable_agent_deploys = true"
    }
    precondition {
      condition     = !var.enable_polly || var.enable_agent_deploys
      error_message = "enable_polly requires enable_agent_deploys = true"
    }
    precondition {
      condition     = !var.enable_insights || var.clickhouse_host != ""
      error_message = "clickhouse_host is required when enable_insights = true"
    }
    precondition {
      condition     = fileexists("${local.values_path}/langsmith-values.yaml")
      error_message = "Helm values files not found at ${local.values_path}/. Run: make init-values (copies templates from helm/values/examples/)"
    }
  }
}
