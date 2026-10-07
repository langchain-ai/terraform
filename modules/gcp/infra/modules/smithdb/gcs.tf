# SmithDB object store — the durable data layer holding .vortex segments.
# Reserved for SmithDB; keep it separate from the LangSmith blob-storage bucket
# that holds run payloads and attachments.

# CMEK: it is the Cloud Storage service agent, not the SmithDB service account,
# that encrypts and decrypts objects with the customer key. Without this binding
# the bucket fails to create outright, so the grant has to land first.
data "google_storage_project_service_account" "gcs" {
  count = var.bucket_kms_key != "" ? 1 : 0

  project = var.project_id
}

resource "google_kms_crypto_key_iam_member" "gcs_service_agent" {
  count = var.bucket_kms_key != "" ? 1 : 0

  crypto_key_id = var.bucket_kms_key
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs[0].email_address}"
}

resource "google_storage_bucket" "object_store" {
  name     = var.bucket_name
  project  = var.project_id
  location = var.region

  storage_class = "STANDARD"

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Off by default, matching the AWS module. SmithDB never overwrites a segment
  # in place, so versioning buys no recovery here — it only retains a
  # noncurrent copy of every object compaction deletes, which on a write-heavy
  # store is a standing cost with no reader. Enable it only where a retention
  # policy demands it, and pair it with a noncurrent-age lifecycle rule.
  dynamic "versioning" {
    for_each = var.bucket_versioning_enabled ? [1] : []
    content {
      enabled = true
    }
  }

  # No object-expiry lifecycle rules on purpose. SmithDB owns the lifecycle of
  # its own objects; expiring or deleting live segments out from under it makes
  # data unavailable. Compaction already reclaims dead segments.
  #
  # Aborting stalled multipart uploads is safe — those are never live data.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  dynamic "encryption" {
    for_each = var.bucket_kms_key != "" ? [1] : []
    content {
      default_kms_key_name = var.bucket_kms_key
    }
  }

  labels = merge(local.labels, {
    "component" = "smithdb-object-store"
  })

  force_destroy = var.bucket_force_destroy

  depends_on = [google_kms_crypto_key_iam_member.gcs_service_agent]
}
