# Shared locals for the SmithDB module.
# Resources are split by concern: rds.tf (metastore), s3.tf (object store), irsa.tf (S3 access role).

locals {
  byo_metastore_security_group    = var.existing_security_group_id != null && var.existing_security_group_id != ""
  create_metastore_security_group = !local.byo_metastore_security_group

  metastore_security_group_id = local.create_metastore_security_group ? aws_security_group.metastore[0].id : var.existing_security_group_id
  # Terraform owns egress only for the group it creates. A supplied group may
  # already have AWS's default allow-all egress rule, so managing it would fail
  # with a duplicate-rule error.
  manage_metastore_egress_rule = local.create_metastore_security_group

  # On a supplied group, this opt-in manages only the required ingress rule.
  # The EKS node group is created in the same apply, so its security group ID is unavailable when preparing a new deployment's group rules.
  manage_metastore_ingress_rule = local.create_metastore_security_group || (local.byo_metastore_security_group && var.manage_existing_security_group_rules)

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

  metastore_host     = aws_db_instance.metastore.address
  metastore_port     = aws_db_instance.metastore.port
  metastore_database = aws_db_instance.metastore.db_name
  metastore_username = aws_db_instance.metastore.username
  metastore_password = local.rds_master_password

  rds_master_password = coalesce(var.metastore_master_password, try(random_password.metastore[0].result, null))

  irsa_role_arn = var.service_account_role_arn != null ? var.service_account_role_arn : aws_iam_role.smithdb[0].arn

  bucket_arn = aws_s3_bucket.object_store.arn

  tags = merge(var.tags, {
    "langsmith-component" = "smithdb"
  })
}
