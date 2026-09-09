# Shared locals for the SmithDB module. Resources are split by concern:
# rds.tf (metastore), s3.tf (object store), irsa.tf (S3 access role).

locals {
  create_rds = var.metastore_source == "create"

  # BYO security group only applies when Terraform is otherwise creating the RDS
  # instance (metastore_source = "create"). metastore_source = "external" already
  # skips the whole metastore, SG included.
  byo_metastore_security_group    = local.create_rds && var.existing_metastore_security_group_id != null && var.existing_metastore_security_group_id != ""
  create_metastore_security_group = local.create_rds && !local.byo_metastore_security_group

  # Guarded by create_metastore_security_group (not just !byo) so this never indexes
  # aws_security_group.metastore[0] when metastore_source = "external", where that
  # resource has count = 0 too.
  metastore_security_group_id = (
    local.create_metastore_security_group ? aws_security_group.metastore[0].id :
    local.byo_metastore_security_group ? var.existing_metastore_security_group_id :
    null
  )
  # Terraform owns egress only for the group it creates. A supplied group may
  # already have AWS's default allow-all egress rule, so managing it would fail
  # with a duplicate-rule error.
  manage_metastore_egress_rule = local.create_metastore_security_group

  # On a supplied group, this opt-in manages only the required ingress rule.
  # The EKS node group is created in the same apply, so its security group ID is
  # unavailable when preparing a new deployment's group rules.
  manage_metastore_ingress_rule = local.create_metastore_security_group || (local.byo_metastore_security_group && var.manage_byo_security_group_rules)

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
