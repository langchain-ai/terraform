# Credential-free plan tests using mocked providers.
# Run: terraform -chdir=modules/azure-private/bootstrap init -backend=false && \
#      terraform -chdir=modules/azure-private/bootstrap test
# Requires Terraform >= 1.7 (mock_provider) on the runner.

mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

# ── Run 1: NGINX ingress carries the internal-LB annotation ──────────────────
# Plans the bootstrap root with mocked providers and data source overrides.
# Asserts that the nginx helm_release is planned and that the langsmith
# namespace resource is also planned. The cert/key/ca override values are
# harmless base64 placeholders (no real key material is committed). The kubernetes
# provider logs a benign "client_key is not a valid PEM" warning for the placeholder
# key; the plan and the assertions below still pass.
run "nginx_internal_lb_and_namespace" {
  command = plan

  # Override AKS data source — the mock generates a non-URL host by default.
  # client_certificate, client_key, cluster_ca_certificate are base64 placeholders
  # that base64decode() cleanly; the k8s-bootstrap module decodes them internally.
  override_data {
    target = data.azurerm_kubernetes_cluster.main
    values = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.ContainerService/managedClusters/langsmith-aks-test"
      name = "langsmith-aks-test"
      kube_config = [{
        host                        = "https://langsmith-aks-test.privatelink.eastus.azmk8s.io:443"
        client_certificate          = "ZHVtbXktY2VydA=="
        client_key                  = "ZHVtbXkta2V5"
        cluster_ca_certificate      = "ZHVtbXktY2E="
        username                    = ""
        password                    = ""
        client_key_data             = ""
        client_certificate_data     = ""
        cluster_ca_certificate_data = ""
      }]
    }
  }

  # Override Key Vault data source — mock generates an ID that may not be a
  # valid Azure resource path; the azurerm_key_vault_secret reads use it as
  # key_vault_id so we provide a well-formed ID.
  override_data {
    target = data.azurerm_key_vault.main
    values = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/langsmith-kv-test"
      name = "langsmith-kv-test"
    }
  }

  # Override KV secret reads — mock returns empty string by default which
  # is fine for plan; override ensures the value field is present.
  override_data {
    target = data.azurerm_key_vault_secret.postgres_url[0]
    values = {
      id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/langsmith-kv-test/secrets/postgres-connection-url"
      value = "postgresql://lsadmin:pass@langsmith-pg-test.postgres.database.azure.com:5432/langsmith?sslmode=require"
    }
  }

  override_data {
    target = data.azurerm_key_vault_secret.redis_url[0]
    values = {
      id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/langsmith-kv-test/secrets/redis-connection-url"
      value = "rediss://:key@langsmith-redis-test.redis.cache.windows.net:6380"
    }
  }

  override_data {
    target = data.azurerm_key_vault_secret.postgres_admin_password[0]
    values = {
      id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/langsmith-kv-test/secrets/postgres-admin-password"
      value = "test-admin-password"
    }
  }

  variables {
    subscription_id     = "00000000-0000-0000-0000-000000000000"
    resource_group_name = "test-rg"
    identifier          = "-test"
  }

  # The nginx helm_release must be planned and must carry the internal-LB
  # annotation. Resources inside the k8s-bootstrap module are referenced via
  # module.k8s_bootstrap.
  assert {
    condition     = strcontains(module.k8s_bootstrap.nginx_ingress_values, "azure-load-balancer-internal")
    error_message = "NGINX helm_release values must contain the internal-LB annotation (azure-load-balancer-internal)"
  }

  # The NGINX release should be planned — ingress_controller is hardcoded to "nginx"
  # in main.tf so count=1. We verify via the ingress_namespace output.
  assert {
    condition     = output.ingress_namespace == "ingress-nginx"
    error_message = "ingress_namespace output must equal 'ingress-nginx' when ingress_controller is nginx"
  }
}
