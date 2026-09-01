# The cross-variable interlocks on terraform_data.validate_inputs in main.tf.
# Each run takes a working configuration, breaks exactly one rule, and expects
# the plan to be rejected.
#
# expect_failures names the resource, not the individual precondition, so a run
# proves that the combination is rejected rather than which message the customer
# sees. That is why each run changes one thing: the rest of the configuration is
# the one tests/wiring.tftest.hcl plans clean.

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

# ── Data plane credentials ───────────────────────────────────────────────────

# Three rules have no run here: external Postgres with an empty password, and
# either Redis with an empty auth token. An empty value also fails a check inside
# the module that consumes it, the postgres module's own variable validation and
# the ElastiCache schema validator, and expect_failures cannot name an object
# inside a child module, so the run fails on a failure it cannot declare. All
# three rules are enforced twice over.

run "sandboxes_without_a_redis_instance_type_are_rejected" {
  command = plan

  variables {
    enable_sandboxes                    = true
    sandbox_juicefs_redis_instance_type = ""
    sandbox_juicefs_redis_auth_token    = "fixture-not-a-real-token-0123456789"
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── TLS ──────────────────────────────────────────────────────────────────────

run "acm_without_a_certificate_or_a_domain_is_rejected" {
  command = plan

  variables {
    tls_certificate_source = "acm"
    acm_certificate_arn    = ""
    langsmith_domain       = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "letsencrypt_without_an_email_is_rejected" {
  command = plan

  variables {
    tls_certificate_source = "letsencrypt"
    letsencrypt_email      = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

# Both paths create ClusterIssuer/letsencrypt-prod, so only one can run.
run "letsencrypt_with_cert_manager_irsa_is_rejected" {
  command = plan

  variables {
    tls_certificate_source      = "letsencrypt"
    letsencrypt_email           = "plan-tests@example.com"
    create_cert_manager_irsa    = true
    cert_manager_hosted_zone_id = "Z00000000000000000001"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "cert_manager_irsa_without_a_hosted_zone_is_rejected" {
  command = plan

  variables {
    create_cert_manager_irsa = true
    letsencrypt_email        = "plan-tests@example.com"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "cert_manager_irsa_without_an_email_is_rejected" {
  command = plan

  variables {
    create_cert_manager_irsa    = true
    cert_manager_hosted_zone_id = "Z00000000000000000001"
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── Bring your own VPC ───────────────────────────────────────────────────────

# Two bring-your-own-VPC rules have no run here: create_vpc = false with none of
# the VPC inputs, and create_vpc = false with create_firewall = true. Terraform
# keeps planning past an expected failure, so each run reaches the configuration
# the precondition exists to prevent and fails there instead, on a null VPC ID
# and on module.vpc[0] against an empty tuple. A precondition is testable this
# way only when the configuration it rejects still evaluates.

run "byo_vpc_serving_the_internet_without_public_subnets_is_rejected" {
  command = plan

  variables {
    create_vpc      = false
    alb_scheme      = "internet-facing"
    vpc_id          = "vpc-00000000000000001"
    vpc_cidr_block  = "10.0.0.0/16"
    private_subnets = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets  = []
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── Feature dependencies ─────────────────────────────────────────────────────

run "agent_builder_without_deployments_is_rejected" {
  command = plan

  variables {
    enable_agent_builder = true
    enable_deployments   = false
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "polly_without_deployments_is_rejected" {
  command = plan

  variables {
    enable_polly       = true
    enable_deployments = false
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "fleet_without_deployments_is_rejected" {
  command = plan

  variables {
    enable_fleet       = true
    enable_deployments = false
  }

  expect_failures = [terraform_data.validate_inputs]
}

# Fleet, standalone Polly, and standalone Insights each take a database on the
# shared RDS and an index on the shared ElastiCache, so neither can be
# in-cluster.
run "fleet_with_in_cluster_postgres_is_rejected" {
  command = plan

  variables {
    enable_fleet       = true
    enable_deployments = true
    postgres_source    = "in-cluster"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "standalone_polly_with_in_cluster_redis_is_rejected" {
  command = plan

  variables {
    enable_standalone_polly = true
    redis_source            = "in-cluster"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "standalone_insights_with_in_cluster_postgres_is_rejected" {
  command = plan

  variables {
    enable_standalone_insights = true
    postgres_source            = "in-cluster"
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── SmithDB ──────────────────────────────────────────────────────────────────

run "external_smithdb_metastore_without_connection_details_is_rejected" {
  command = plan

  variables {
    enable_smithdb           = true
    smithdb_metastore_source = "external"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "smithdb_integration_gates_without_smithdb_are_rejected" {
  command = plan

  variables {
    enable_smithdb            = false
    smithdb_ingestion_enabled = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "smithdb_migration_without_ingestion_is_rejected" {
  command = plan

  variables {
    enable_smithdb            = true
    smithdb_ingestion_enabled = false
    smithdb_migration_enabled = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "smithdb_query_without_ingestion_is_rejected" {
  command = plan

  variables {
    enable_smithdb            = true
    smithdb_ingestion_enabled = false
    smithdb_query_enabled     = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── Ingress ──────────────────────────────────────────────────────────────────
# gateway_target_port can only describe one controller, so a second one leaves
# both permanently unhealthy.

run "two_ingress_controllers_are_rejected" {
  command = plan

  variables {
    enable_envoy_gateway = true
    enable_nginx_ingress = true
  }

  expect_failures = [terraform_data.validate_inputs]
}
