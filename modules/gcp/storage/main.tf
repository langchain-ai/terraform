# Storage Module - Cloud Storage Bucket

#------------------------------------------------------------------------------
# Cloud Storage Bucket for Traces
#------------------------------------------------------------------------------
resource "google_storage_bucket" "langsmith_traces" {
  name     = var.bucket_name
  project  = var.project_id
  location = var.region

  # Storage class
  storage_class = "STANDARD"

  # Uniform bucket-level access
  uniform_bucket_level_access = true

  # Versioning (optional)
  versioning {
    enabled = false
  }

  # Lifecycle rules for automatic deletion
  dynamic "lifecycle_rule" {
    for_each = var.retention_days > 0 ? [1] : []
    content {
      condition {
        age = var.retention_days
      }
      action {
        type = "Delete"
      }
    }
  }

  # Lifecycle rule for incomplete multipart uploads
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  # CORS configuration
  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }

  # Labels
  labels = merge(var.labels, {
    "component" = "storage"
  })

  # Force destroy (set to false for production)
  force_destroy = var.force_destroy
}
