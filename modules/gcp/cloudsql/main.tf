# Cloud SQL Module - PostgreSQL Instance

#------------------------------------------------------------------------------
# Cloud SQL Instance
#------------------------------------------------------------------------------
resource "google_sql_database_instance" "postgres" {
  name                = var.instance_name
  project             = var.project_id
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.high_availability ? "REGIONAL" : "ZONAL"
    disk_size         = var.disk_size
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      ssl_mode                                      = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
      enable_private_path_for_google_cloud_services = true
    }

    # Backup configuration
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

    # Maintenance window
    maintenance_window {
      day          = 7 # Sunday
      hour         = 3
      update_track = "stable"
    }

    # Insights
    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }

    dynamic "database_flags" {
      for_each = var.database_flags
      content {
        name  = database_flags.value.name
        value = database_flags.value.value
      }
    }

    # Labels
    user_labels = merge(var.labels, {
      "component" = "database"
    })
  }


  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

#------------------------------------------------------------------------------
# Database
#------------------------------------------------------------------------------
resource "google_sql_database" "langsmith" {
  name     = var.database_name
  project  = var.project_id
  instance = google_sql_database_instance.postgres.name
}

#------------------------------------------------------------------------------
# Database User
#------------------------------------------------------------------------------
resource "google_sql_user" "langsmith" {
  name     = var.username
  project  = var.project_id
  instance = google_sql_database_instance.postgres.name
  password = var.password
}
