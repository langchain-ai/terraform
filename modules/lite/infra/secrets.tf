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
