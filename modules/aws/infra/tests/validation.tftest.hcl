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

run "transition_requires_smithdb" {
  command = plan
  variables {
    enable_smithdb          = false
    smithdb_transition_mode = true
  }
  expect_failures = [var.smithdb_transition_mode]
}

run "smithdb_capacity_requires_headroom" {
  command = plan
  variables {
    smithdb_node_min_count = 2
    smithdb_node_max_count = 2
  }
  expect_failures = [var.smithdb_node_max_count]
}

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
    smithdb_metastore_source = "import"
    smithdb_node_arch        = "x86_64"
    smithdb_cache_storage    = "nvme"
    eks_network_mode         = "overlay"
  }

  expect_failures = [
    var.postgres_source,
    var.redis_source,
    var.alb_scheme,
    var.environment,
    var.tls_certificate_source,
    var.clickhouse_source,
    var.smithdb_metastore_source,
    var.smithdb_node_arch,
    var.smithdb_cache_storage,
    var.eks_network_mode,
  ]
}

# enable_agent_builder is a bool the root accepts only as false, not an enum, so
# it needs its own run. Chart v0.16 replaced it with enable_fleet and the
# variable survives only so an existing tfvars file still plans.
run "enable_agent_builder_is_rejected_when_true" {
  command = plan

  variables {
    enable_agent_builder = true
  }

  expect_failures = [var.enable_agent_builder]
}

run "names_and_ids_reject_a_malformed_value" {
  command = plan

  variables {
    region                       = "us-east"
    eks_cluster_version          = "1.31.0"
    name_prefix                  = "Prod"
    langsmith_namespace          = "LangSmith"
    acm_certificate_arn          = "arn:aws:acm:us-east-2:123456789012:certificate"
    cert_manager_hosted_zone_id  = "hostedzone/Z00000000000000000001"
    dns_existing_zone_id         = "hostedzone/Z00000000000000000001"
    langsmith_helm_chart_version = "0.15.0"
  }

  expect_failures = [
    var.region,
    var.eks_cluster_version,
    var.name_prefix,
    var.langsmith_namespace,
    var.acm_certificate_arn,
    var.cert_manager_hosted_zone_id,
    var.dns_existing_zone_id,
    var.langsmith_helm_chart_version,
  ]
}

# The chart version regex moves with every chart line cut, so it is also checked
# from the other side: the previous line must fail and the pinned line must pass.
run "chart_version_rejects_the_previous_line" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.16.11"
  }

  expect_failures = [
    var.langsmith_helm_chart_version,
  ]
}

run "chart_version_accepts_the_pinned_line" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.17.0"
  }

  assert {
    condition     = var.langsmith_helm_chart_version == "0.17.0"
    error_message = "a 0.17.x langsmith_helm_chart_version failed validation"
  }
}

run "chart_version_accepts_the_0_18_line" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.18.0-rc.28"
  }

  assert {
    condition     = var.langsmith_helm_chart_version == "0.18.0-rc.28"
    error_message = "a 0.18.x langsmith_helm_chart_version failed validation"
  }
}

run "cidrs_reject_a_non_cidr" {
  command = plan

  variables {
    vpc_cidr_block       = "10.0.0.0"
    firewall_subnet_cidr = "10.0.32.0"
    eks_pod_cidr         = "100.64.0.0"
  }

  expect_failures = [
    var.vpc_cidr_block,
    var.firewall_subnet_cidr,
    var.eks_pod_cidr,
  ]
}

# eks_pod_cidr is a valid CIDR here, but its pod subnets would be /29s, which
# AWS rejects.
run "eks_pod_cidr_rejects_a_prefix_longer_than_26" {
  command = plan

  variables {
    eks_pod_cidr = "100.64.0.0/27"
  }

  expect_failures = [var.eks_pod_cidr]
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

# A 0.17 tfvars file that still runs PostgreSQL in the cluster must fail at plan,
# not silently get a new RDS instance.
run "postgres_source_rejects_in_cluster" {
  command = plan

  variables {
    postgres_source = "in-cluster"
  }

  expect_failures = [var.postgres_source]
}

run "redis_source_rejects_in_cluster" {
  command = plan

  variables {
    redis_source = "in-cluster"
  }

  expect_failures = [var.redis_source]
}

# A 0.17 tfvars file that still keeps Fleet, Chat or Insights in the cluster, or
# still uses a standalone switch, must fail at plan rather than move the feature
# to a new, empty database or silently turn it off.
run "addon_storage_rejects_in_cluster" {
  command = plan

  variables {
    enable_fleet     = true
    enable_polly     = true
    enable_insights  = true
    fleet_storage    = "in-cluster"
    insights_storage = "in-cluster"
    polly_storage    = "in-cluster"
  }

  expect_failures = [
    var.fleet_storage,
    var.insights_storage,
    var.polly_storage,
  ]
}

# The 0.17 QuickStart wrote "in-cluster" for add-ons that were off, where the
# value does nothing, so those tfvars must still plan.
run "addon_storage_in_cluster_is_ignored_while_the_addon_is_off" {
  command = plan

  variables {
    enable_fleet     = false
    enable_polly     = false
    enable_insights  = false
    enable_engine    = false
    fleet_storage    = "in-cluster"
    insights_storage = "in-cluster"
    polly_storage    = "in-cluster"
  }
}

run "standalone_switches_are_rejected" {
  command = plan

  variables {
    enable_standalone_polly    = true
    enable_standalone_insights = true
  }

  expect_failures = [
    var.enable_standalone_polly,
    var.enable_standalone_insights,
  ]
}

# A 0.17 tfvars file with an external metastore must fail at plan rather than
# point SmithDB at a new, empty RDS instance.
run "smithdb_metastore_source_rejects_external" {
  command = plan

  variables {
    smithdb_metastore_source = "external"
  }

  expect_failures = [var.smithdb_metastore_source]
}

# The 0.17 names of the metastore security group settings must fail at plan
# rather than be ignored, which would swap the supplied group for a new one or
# delete the ingress rule on it.
run "renamed_smithdb_security_group_settings_are_rejected" {
  command = plan

  variables {
    smithdb_existing_metastore_security_group_id = "sg-0123456789abcdef4"
    smithdb_manage_byo_security_group_rules      = true
  }

  expect_failures = [
    var.smithdb_existing_metastore_security_group_id,
    var.smithdb_manage_byo_security_group_rules,
  ]
}

run "smithdb_metastore_takes_a_supplied_security_group" {
  command = plan

  variables {
    smithdb_metastore_existing_security_group_id           = "sg-0123456789abcdef4"
    smithdb_metastore_manage_existing_security_group_rules = true
  }

  assert {
    condition     = output.smithdb_metastore_security_group_id == "sg-0123456789abcdef4"
    error_message = "smithdb_metastore_existing_security_group_id should be the security group on the metastore"
  }
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
