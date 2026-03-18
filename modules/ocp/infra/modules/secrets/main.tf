# OCP Secrets module
# Creates a Kubernetes Secret from literal values for LangSmith on OpenShift.
#
# For production deployments, replace this module with an External Secrets Operator
# or HashiCorp Vault Agent integration to avoid storing plaintext values in Terraform state.

resource "random_password" "langsmith_secret_key" {
  length  = 64
  special = false
}

resource "kubernetes_secret" "langsmith" {
  metadata {
    name      = "langsmith-secrets"
    namespace = var.namespace
  }

  data = {
    "langsmith-secret-key" = random_password.langsmith_secret_key.result
    "postgres-password"    = var.postgres_password
    "redis-password"       = var.redis_password
  }

  type = "Opaque"
}
