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

  # Lifecycle rules for TTL prefixes (matching LangSmith TTL structure)
  lifecycle_rule {
      condition {
      age            = var.ttl_short_days
      matches_prefix = ["ttl_s/"]
      }
      action {
        type = "Delete"
      }
  }

  lifecycle_rule {
    condition {
      age            = var.ttl_long_days
      matches_prefix = ["ttl_l/"]
    }
    action {
      type = "Delete"
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
