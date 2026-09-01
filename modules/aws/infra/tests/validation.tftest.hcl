# Variable validation in the AWS root. Every validation block in variables.tf is
# fed a value it must reject.
#
# Bad values are grouped by class rather than given one run each. Terraform
# reports every variable validation error in a single pass, so a group costs one
# plan and still names the variable whose validation stopped firing: the run
# fails with the expected failure that did not occur. A variable with two
# validations needs two runs, since expect_failures names the variable and not
# the individual block.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  name_prefix         = "plantest"
  postgres_password   = "fixture-not-a-real-secret-Aa1"
  redis_auth_token    = "fixture-not-a-real-token-0123456789"
  acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "enums_reject_an_unlisted_value" {
  command = plan

  variables {
    postgres_source          = "rds"
    redis_source             = "elasticache"
    alb_scheme               = "public"
    environment              = "qa"
    tls_certificate_source   = "self-signed"
    clickhouse_source        = "langsmith-managed"
    sizing_profile           = "small"
    smithdb_metastore_source = "import"
    smithdb_node_arch        = "x86_64"
  }

  expect_failures = [
    var.postgres_source,
    var.redis_source,
    var.alb_scheme,
    var.environment,
    var.tls_certificate_source,
    var.clickhouse_source,
    var.sizing_profile,
    var.smithdb_metastore_source,
    var.smithdb_node_arch,
  ]
}

run "names_and_ids_reject_a_malformed_value" {
  command = plan

  variables {
    region                      = "us-east"
    eks_cluster_version         = "1.31.0"
    name_prefix                 = "Prod"
    langsmith_namespace         = "LangSmith"
    acm_certificate_arn         = "arn:aws:acm:us-east-2:123456789012:certificate"
    cert_manager_hosted_zone_id = "hostedzone/Z00000000000000000001"
  }

  expect_failures = [
    var.region,
    var.eks_cluster_version,
    var.name_prefix,
    var.langsmith_namespace,
    var.acm_certificate_arn,
    var.cert_manager_hosted_zone_id,
  ]
}

run "cidrs_reject_a_non_cidr" {
  command = plan

  variables {
    vpc_cidr_block       = "10.0.0.0"
    firewall_subnet_cidr = "10.0.32.0"
  }

  expect_failures = [
    var.vpc_cidr_block,
    var.firewall_subnet_cidr,
  ]
}

run "sizes_and_counts_reject_a_value_below_the_floor" {
  command = plan

  variables {
    postgres_storage_gb                            = 4
    postgres_max_storage_gb                        = 4
    sandbox_host_node_count                        = 0
    sandbox_host_local_nvme_expected_device_count  = 0
    sandbox_juicefs_redis_snapshot_retention_limit = -1
  }

  expect_failures = [
    var.postgres_storage_gb,
    var.postgres_max_storage_gb,
    var.sandbox_host_node_count,
    var.sandbox_host_local_nvme_expected_device_count,
    var.sandbox_juicefs_redis_snapshot_retention_limit,
  ]
}

run "sizes_and_counts_reject_a_value_above_the_ceiling" {
  command = plan

  variables {
    postgres_storage_gb                            = 65537
    postgres_max_storage_gb                        = 65537
    sandbox_juicefs_redis_snapshot_retention_limit = 36
  }

  expect_failures = [
    var.postgres_storage_gb,
    var.postgres_max_storage_gb,
    var.sandbox_juicefs_redis_snapshot_retention_limit,
  ]
}

# RDS rejects these characters in a master password, and the ones that survive
# RDS still have to travel through a connection URL.
run "postgres_password_rejects_a_reserved_character" {
  command = plan

  variables {
    postgres_password = "fixture/not-a-real-secret"
  }

  expect_failures = [var.postgres_password]
}
