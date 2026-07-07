# Shared locals for the SmithDB module. Resources are split by concern:
# rds.tf (metastore), s3.tf (object store), irsa.tf (S3 access role).

locals {
  create_rds = var.metastore_source == "create"

  rds_identifier = "${var.name}-metastore"
  rds_db_name    = "smithdb"

  # SmithDB service account created by the chart is "<chart-fullname>-smithdb".
  # Helm's fullname helper collapses "<release>-langsmith" to just "<release>" when
  # the release name already contains the chart name ("langsmith"). So:
  #   release "langsmith"      -> fullname "langsmith"        -> SA "langsmith-smithdb"
  #   release "smithdb"        -> fullname "smithdb-langsmith" -> SA "smithdb-langsmith-smithdb"
  #   release "langsmith-prod" -> fullname "langsmith-prod"   -> SA "langsmith-prod-smithdb"
  # Getting this wrong makes STS deny AssumeRoleWithWebIdentity and SmithDB S3
  # writes 403.
  smithdb_release_fullname = strcontains(var.release_name, "langsmith") ? var.release_name : "${var.release_name}-langsmith"
  smithdb_service_account  = "${local.smithdb_release_fullname}-smithdb"
  oidc_sub_pattern         = "system:serviceaccount:${var.namespace}:${local.smithdb_service_account}"

  # Resolved metastore connection — from the created RDS instance or a BYO instance.
  metastore_host     = local.create_rds ? aws_db_instance.metastore[0].address : var.external_metastore_host
  metastore_port     = local.create_rds ? aws_db_instance.metastore[0].port : var.external_metastore_port
  metastore_database = local.create_rds ? aws_db_instance.metastore[0].db_name : var.external_metastore_database
  metastore_username = local.create_rds ? aws_db_instance.metastore[0].username : var.external_metastore_username
  metastore_password = local.create_rds ? local.rds_master_password : var.external_metastore_password

  rds_master_password = local.create_rds ? coalesce(var.metastore_master_password, try(random_password.metastore[0].result, null)) : null

  irsa_role_arn = var.service_account_role_arn != null ? var.service_account_role_arn : aws_iam_role.smithdb[0].arn

  bucket_arn = aws_s3_bucket.object_store.arn

  tags = merge(var.tags, {
    "langsmith-component" = "smithdb"
  })
}
