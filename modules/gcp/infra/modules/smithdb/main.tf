# Shared locals for the SmithDB module. Resources are split by concern:
# cloudsql.tf (metastore), gcs.tf (object store), iam.tf (Workload Identity).

locals {
  create_metastore = var.metastore_source == "create"

  metastore_instance_name = var.metastore_instance_name != "" ? var.metastore_instance_name : "${var.name}-metastore"
  metastore_db_name       = "smithdb"

  # SmithDB service account created by the chart is "<chart-fullname>-smithdb".
  # Helm's fullname helper collapses "<release>-langsmith" to just "<release>" when
  # the release name already contains the chart name ("langsmith"). So:
  #   release "langsmith"      -> fullname "langsmith"        -> SA "langsmith-smithdb"
  #   release "smithdb"        -> fullname "smithdb-langsmith" -> SA "smithdb-langsmith-smithdb"
  #   release "langsmith-prod" -> fullname "langsmith-prod"   -> SA "langsmith-prod-smithdb"
  # Getting this wrong leaves the KSA without a Workload Identity binding, so
  # SmithDB's GCS reads and writes fail with 403.
  release_fullname = strcontains(var.release_name, "langsmith") ? var.release_name : "${var.release_name}-langsmith"
  ksa_name         = "${local.release_fullname}-smithdb"

  # Resolved metastore connection — from the created Cloud SQL instance or a BYO
  # instance (AlloyDB via the Auth Proxy, or any reachable Postgres 18+).
  metastore_host     = local.create_metastore ? google_sql_database_instance.metastore[0].private_ip_address : var.external_metastore_host
  metastore_port     = local.create_metastore ? 5432 : var.external_metastore_port
  metastore_database = local.create_metastore ? google_sql_database.metastore[0].name : var.external_metastore_database
  metastore_username = local.create_metastore ? var.metastore_master_username : var.external_metastore_username
  metastore_password = local.create_metastore ? local.metastore_master_password : var.external_metastore_password

  metastore_master_password = local.create_metastore ? coalesce(var.metastore_master_password, try(random_password.metastore[0].result, null)) : null

  gsa_email = var.service_account_email != null ? var.service_account_email : google_service_account.smithdb[0].email

  labels = merge(var.labels, {
    "langsmith-component" = "smithdb"
  })
}
