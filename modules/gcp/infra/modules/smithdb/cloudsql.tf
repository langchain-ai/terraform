# SmithDB metastore — a dedicated Cloud SQL Postgres instance holding SmithDB
# catalog and coordination data. It must start empty; the chart's metastore
# migration Job owns the schema. Only created when metastore_source = "create".

resource "random_password" "metastore" {
  count = local.create_metastore && var.metastore_master_password == null ? 1 : 0

  length      = 32
  special     = true
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
  # Cloud SQL accepts these; excluding quotes and backslashes keeps the value
  # safe to paste into shell and psql invocations during troubleshooting.
  override_special = "!#%*()-_=+[]{}:?"
}

# Credential for the in-chart taskdb Postgres that holds ClickHouse-to-SmithDB
# migration task state. It is a StatefulSet inside the release, not a Cloud SQL
# instance, and it only renders once the migration gate is on — but the chart
# hard-fails validation without a password, so generate it up front and let the
# gate stay a values-only flip.
resource "random_password" "taskdb" {
  length      = 32
  special     = true
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1

  override_special = "!#%*()-_=+[]{}:?"
}

resource "google_sql_database_instance" "metastore" {
  count = local.create_metastore ? 1 : 0

  name                = local.metastore_instance_name
  project             = var.project_id
  region              = var.region
  database_version    = var.metastore_database_version
  deletion_protection = var.metastore_deletion_protection

  settings {
    tier              = var.metastore_tier
    availability_type = var.metastore_high_availability ? "REGIONAL" : "ZONAL"
    disk_size         = var.metastore_disk_size
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    # As with the LangSmith metastore: the resource-level flag only stops
    # Terraform, this one makes Cloud SQL itself refuse the delete.
    deletion_protection_enabled = var.metastore_deletion_protection

    # Private IP only — the metastore is never exposed on a public address.
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      ssl_mode                                      = var.metastore_ssl_mode
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }

    user_labels = merge(local.labels, {
      "component" = "smithdb-metastore"
    })
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "google_sql_database" "metastore" {
  count = local.create_metastore ? 1 : 0

  name     = local.metastore_db_name
  project  = var.project_id
  instance = google_sql_database_instance.metastore[0].name
}

resource "google_sql_user" "metastore" {
  count = local.create_metastore ? 1 : 0

  name     = var.metastore_master_username
  project  = var.project_id
  instance = google_sql_database_instance.metastore[0].name
  password = local.metastore_master_password
}
