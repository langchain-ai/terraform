locals {
  cluster_name   = "langsmith-aks${var.identifier}"
  key_vault_name = var.key_vault_name != "" ? var.key_vault_name : "langsmith-kv${var.identifier}"
}

# ── AKS cluster credentials ────────────────────────────────────────────────────
# Reads the cluster endpoint and credentials needed to configure the
# Kubernetes/Helm providers inside the k8s-bootstrap module.
# The kube_config certificate fields (client_certificate, client_key,
# cluster_ca_certificate) are base64-encoded in the azurerm data source.
# They are passed AS-IS to the k8s-bootstrap module, which applies
# base64decode() internally in its provider blocks.

data "azurerm_kubernetes_cluster" "main" {
  name                = local.cluster_name
  resource_group_name = var.resource_group_name
}

# ── Key Vault ──────────────────────────────────────────────────────────────────

data "azurerm_key_vault" "main" {
  name                = local.key_vault_name
  resource_group_name = var.resource_group_name
}

# ── Key Vault secrets ─────────────────────────────────────────────────────────

data "azurerm_key_vault_secret" "postgres_url" {
  count        = var.use_external_postgres ? 1 : 0
  name         = "postgres-connection-url"
  key_vault_id = data.azurerm_key_vault.main.id
}

data "azurerm_key_vault_secret" "redis_url" {
  count        = var.use_external_redis ? 1 : 0
  name         = "redis-connection-url"
  key_vault_id = data.azurerm_key_vault.main.id
}

data "azurerm_key_vault_secret" "postgres_admin_password" {
  count        = var.use_external_postgres ? 1 : 0
  name         = "postgres-admin-password"
  key_vault_id = data.azurerm_key_vault.main.id
}

# NOTE: The LangSmith license key and the other app-config secrets are NOT read
# here. They are pulled from Key Vault into `langsmith-config-secret` by
# infra/scripts/create-k8s-secrets.sh (DEPLOYMENT.md Phase 3.5), keeping the
# full app-secret set out of this root's Terraform state.

# ── Kubernetes / Helm bootstrap ────────────────────────────────────────────────
# Creates the langsmith namespace, network policies, the
# Postgres/Redis connection K8s secrets, KEDA, and the NGINX ingress controller.
# The app-config secret (langsmith-config-secret) and the TLS secret
# (langsmith-tls) are created separately by infra/scripts/create-k8s-secrets.sh
# and create-tls-secret.sh (DEPLOYMENT.md Phase 3.5).
# All Kubernetes/Helm providers are configured inside the module from the
# AKS kube_config data source above.

module "k8s_bootstrap" {
  source = "./modules/k8s-bootstrap"

  # Cluster connection — the module's provider blocks apply base64decode()
  # internally, so we pass the raw (still base64-encoded) values from the
  # data source. host is a plain URL and is not encoded.
  host                   = data.azurerm_kubernetes_cluster.main.kube_config[0].host
  client_certificate     = data.azurerm_kubernetes_cluster.main.kube_config[0].client_certificate
  client_key             = data.azurerm_kubernetes_cluster.main.kube_config[0].client_key
  cluster_ca_certificate = data.azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate

  langsmith_namespace = var.langsmith_namespace

  use_external_postgres   = var.use_external_postgres
  postgres_connection_url = var.use_external_postgres ? data.azurerm_key_vault_secret.postgres_url[0].value : ""
  postgres_admin_password = var.use_external_postgres ? data.azurerm_key_vault_secret.postgres_admin_password[0].value : ""
  use_external_redis      = var.use_external_redis
  redis_connection_url    = var.use_external_redis ? data.azurerm_key_vault_secret.redis_url[0].value : ""

  # Version overrides — null/empty means "use the module default"
  nginx_ingress_version = var.nginx_ingress_version
  keda_version          = var.keda_version != null ? var.keda_version : "2.14.0"
}
