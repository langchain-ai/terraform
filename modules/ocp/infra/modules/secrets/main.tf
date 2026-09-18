# OCP Secrets module
# Creates the datastore Secrets the LangSmith chart reads via existingSecretName.
#
# Key names are fixed by chart 0.16: both secrets carry a single `connection_url`
# key. Renaming it means also setting postgres.external.connectionUrlSecretKey /
# redis.external.connectionUrlSecretKey in Helm values.
#
# Only the datastore secrets live here, because only Terraform knows the connection
# URLs. The application-level secret (langsmith-secrets — license key, api_key_salt,
# jwt_secret, encryption keys) is written by helm/scripts/generate-secrets.sh, which
# also creates these two when POSTGRES_CONNECTION_URL / REDIS_CONNECTION_URL are
# exported. Supply each URL in one place, not both.
#
# Each resource is inert until its URL is set, so a cluster whose datastores are
# managed outside Terraform can leave these variables empty.
#
# Both URLs embed a password and therefore land in Terraform state in plaintext:
# keep state in an encrypted remote backend (see backend.tf.example). For production,
# replace this module with External Secrets Operator or the Vault Agent Injector.

resource "kubernetes_secret" "postgres" {
  count = var.postgres_connection_url != "" ? 1 : 0

  metadata {
    name      = "langsmith-postgres"
    namespace = var.namespace
  }

  data = {
    connection_url = var.postgres_connection_url
  }

  type = "Opaque"
}

resource "kubernetes_secret" "redis" {
  count = var.redis_connection_url != "" ? 1 : 0

  metadata {
    name      = "langsmith-redis"
    namespace = var.namespace
  }

  data = {
    connection_url = var.redis_connection_url
  }

  type = "Opaque"
}
