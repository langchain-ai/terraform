#------------------------------------------------------------------------------
# Generated credentials. They live in Terraform's state (local and gitignored,
# as in the bare-metal module) and reach the box inside the bundle, which the
# install streams over ssh; box/install.sh applies them and deletes the file.
# Nothing here is written to the laptop's disk outside the state.
#------------------------------------------------------------------------------

# URL-safe: the Postgres and Redis passwords sit inside connection URLs.
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "random_password" "rustfs_access_key" {
  length  = 20
  special = false
}

resource "random_password" "rustfs_secret_key" {
  length  = 40
  special = false
}

resource "random_password" "api_key_salt" {
  length  = 32
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

# The chart refuses an admin password under 12 characters; one of each class keeps any policy happy.
resource "random_password" "admin" {
  length           = 24
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "-_."
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "random_password" "mission_control" {
  length  = 24
  special = false
}

resource "random_password" "mission_control_jwt" {
  length  = 48
  special = false
}

locals {
  secret = {
    postgres            = random_password.postgres.result
    redis               = random_password.redis.result
    rustfs_access_key   = random_password.rustfs_access_key.result
    rustfs_secret_key   = random_password.rustfs_secret_key.result
    api_key_salt        = random_password.api_key_salt.result
    jwt_secret          = random_password.jwt_secret.result
    admin               = random_password.admin.result
    grafana_admin       = random_password.grafana_admin.result
    mission_control     = random_password.mission_control.result
    mission_control_jwt = random_password.mission_control_jwt.result
  }
}

# The Secrets every release reads by name, in the format each chart takes. Shared by the box bundle and
# make export; a feature that is off has none.
locals {
  secret_list = concat(
    [
      { name = "langsmith-config", namespace = local.ns.langsmith, data = {
        langsmith_license_key          = var.langsmith_license_key
        api_key_salt                   = local.secret.api_key_salt
        jwt_secret                     = local.secret.jwt_secret
        initial_org_admin_password     = local.secret.admin
        blob_storage_access_key        = local.secret.rustfs_access_key
        blob_storage_access_key_secret = local.secret.rustfs_secret_key
      } },
      # The chart's format: no scheme for Postgres, a scheme for Redis.
      { name = "langsmith-postgres", namespace = local.ns.langsmith, data = {
        connection_url = "${local.postgres.user}:${local.secret.postgres}@${local.postgres.host}:${local.postgres.port}/${local.postgres.database}"
      } },
      { name = "langsmith-redis", namespace = local.ns.langsmith, data = {
        connection_url = "redis://:${local.secret.redis}@${local.redis_host}:6379/0"
      } },
      { name = "smithdb-config", namespace = local.ns.langsmith, data = {
        smithdb_metastore_host     = local.postgres.host
        smithdb_metastore_db       = local.postgres.metastore
        smithdb_metastore_user     = local.postgres.user
        smithdb_metastore_password = local.secret.postgres
        smithdb_s3_access_key      = local.secret.rustfs_access_key
        smithdb_s3_secret_key      = local.secret.rustfs_secret_key
      } },
      # The datastores chart's own Secrets, with existingSecrets (its values.yaml lists the keys).
      { name = "postgres-langsmith-credentials", namespace = local.ns.data, data = {
        POSTGRES_USER     = local.postgres.user
        POSTGRES_PASSWORD = local.secret.postgres
        POSTGRES_DB       = local.postgres.database
      } },
      { name = "redis-langsmith-credentials", namespace = local.ns.data, data = {
        password    = local.secret.redis
        "auth.conf" = "requirepass ${local.secret.redis}"
      } },
      { name = "rustfs-credentials", namespace = local.ns.data, data = {
        access-key      = local.secret.rustfs_access_key
        secret-key      = local.secret.rustfs_secret_key
        aws-credentials = "[default]\naws_access_key_id = ${local.secret.rustfs_access_key}\naws_secret_access_key = ${local.secret.rustfs_secret_key}\n"
      } },
    ],
    local.features.observability ? [
      { name = "grafana-admin", namespace = local.ns.observe, data = { admin-user = "admin", admin-password = local.secret.grafana_admin } },
      { name = "redis-exporter", namespace = local.ns.observe, data = { password = local.secret.redis } },
      { name = "postgres-exporter", namespace = local.ns.observe, data = { password = local.secret.postgres } },
    ] : [],
    local.features.mission_control ? [
      { name = "mission-control-auth", namespace = local.ns.langsmith, data = { username = "admin", password = local.secret.mission_control, jwt-secret = local.secret.mission_control_jwt } },
    ] : [],
    local.features.tunnel ? [{ name = "cloudflared", namespace = local.ns.langsmith, data = { token = var.tunnel_token } }] : [],
  )

  secret_manifests = {
    for s in local.secret_list : "${s.namespace}/${s.name}" => {
      apiVersion = "v1"
      kind       = "Secret"
      type       = "Opaque"
      metadata   = { name = s.name, namespace = s.namespace, labels = local.instance_label }
      stringData = s.data
    }
  }
  secrets_yaml = join("", [for s in values(local.secret_manifests) : "---\n${yamlencode(s)}"])
}
