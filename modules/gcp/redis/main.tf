# Redis Module - Memorystore Instance

#------------------------------------------------------------------------------
# Memorystore Redis Instance
#------------------------------------------------------------------------------
resource "google_redis_instance" "langsmith" {
  name         = var.instance_name
  project      = var.project_id
  region       = var.region
  display_name = "LangSmith Redis Cache (${var.environment})"

  # Configuration
  tier           = var.high_availability ? "STANDARD_HA" : "BASIC"
  memory_size_gb = var.memory_size_gb
  redis_version  = var.redis_version

  # Network
  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  # Redis configuration
  redis_configs = {
    maxmemory-policy       = "allkeys-lru"
    notify-keyspace-events = "Ex"
  }

  # Maintenance window
  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 3
        minutes = 0
      }
    }
  }

  # Labels
  labels = merge(var.labels, {
    "component" = "cache"
  })

  lifecycle {
    prevent_destroy = false
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
