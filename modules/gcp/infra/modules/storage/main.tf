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

  # Versioning — protects against accidental deletes
  versioning {
    enabled = true
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

  # Backstop for redaction rules: LangSmith writes the unredacted large fields of
  # projects that redact at ingestion under ttl_1d/ and deletes them once their
  # runs are done. These rules remove any it could not. Versioning is on, so the
  # second rule also removes the noncurrent versions that a delete leaves behind.
  lifecycle_rule {
    condition {
      age            = 1
      matches_prefix = ["ttl_1d/"]
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 1
      matches_prefix             = ["ttl_1d/"]
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
