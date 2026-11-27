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

# ── VPC CNI custom networking ────────────────────────────────────────────────
# The subnet lookups are overridden because a mock invents a different random
# AZ for every subnet. override_data gives every instance of a data source the
# same values, so the pod subnets all share one AZ and the cluster subnets all
# share one AZ, which is exactly what the two AZ rules need.

run "byo_custom_networking_without_pod_subnets_is_rejected" {
  command = plan

  variables {
    eks_network_mode = "custom-networking"
    create_vpc       = false
    vpc_id           = "vpc-00000000000000001"
    vpc_cidr_block   = "10.0.0.0/16"
    private_subnets  = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets   = ["subnet-00000000000000003", "subnet-00000000000000004"]
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "pod_subnet_ids_with_a_created_vpc_are_rejected" {
  command = plan

  variables {
    eks_network_mode   = "custom-networking"
    eks_pod_subnet_ids = ["subnet-00000000000000005"]
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "pod_subnet_ids_in_node_subnet_mode_are_rejected" {
  command = plan

  variables {
    create_vpc         = false
    vpc_id             = "vpc-00000000000000001"
    vpc_cidr_block     = "10.0.0.0/16"
    private_subnets    = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets     = ["subnet-00000000000000003", "subnet-00000000000000004"]
    eks_pod_subnet_ids = ["subnet-00000000000000005"]
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "two_pod_subnets_in_one_az_are_rejected" {
  command = plan

  variables {
    eks_network_mode   = "custom-networking"
    create_vpc         = false
    vpc_id             = "vpc-00000000000000001"
    vpc_cidr_block     = "10.0.0.0/16"
    private_subnets    = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets     = ["subnet-00000000000000003", "subnet-00000000000000004"]
    eks_pod_subnet_ids = ["subnet-00000000000000005", "subnet-00000000000000006"]
  }

  override_data {
    target = data.aws_subnet.pod
    values = { availability_zone = "us-east-2a", cidr_block = "100.64.0.0/18", vpc_id = "vpc-00000000000000001" }
  }
  override_data {
    target = data.aws_subnet.cluster
    values = { availability_zone = "us-east-2a" }
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "pod_subnets_missing_a_cluster_az_are_rejected" {
  command = plan

  variables {
    eks_network_mode   = "custom-networking"
    create_vpc         = false
    vpc_id             = "vpc-00000000000000001"
    vpc_cidr_block     = "10.0.0.0/16"
    private_subnets    = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets     = ["subnet-00000000000000003", "subnet-00000000000000004"]
    eks_pod_subnet_ids = ["subnet-00000000000000005"]
  }

  override_data {
    target = data.aws_subnet.pod
    values = { availability_zone = "us-east-2a", cidr_block = "100.64.0.0/18", vpc_id = "vpc-00000000000000001" }
  }
  override_data {
    target = data.aws_subnet.cluster
    values = { availability_zone = "us-east-2b" }
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "pod_subnets_in_another_vpc_are_rejected" {
  command = plan

  variables {
    eks_network_mode   = "custom-networking"
    create_vpc         = false
    vpc_id             = "vpc-00000000000000001"
    vpc_cidr_block     = "10.0.0.0/16"
    private_subnets    = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets     = ["subnet-00000000000000003", "subnet-00000000000000004"]
    eks_pod_subnet_ids = ["subnet-00000000000000005"]
  }

  override_data {
    target = data.aws_subnet.pod
    values = { availability_zone = "us-east-2a", cidr_block = "100.64.0.0/18", vpc_id = "vpc-00000000000000009" }
  }
  override_data {
    target = data.aws_subnet.cluster
    values = { availability_zone = "us-east-2a" }
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── SmithDB ──────────────────────────────────────────────────────────────────

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
    enable_istio_gateway = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

# Envoy Gateway v1.9 is tested on Kubernetes 1.33 to 1.36. Below the range the plan
# is rejected, above it the check warns.

run "envoy_gateway_on_eks_below_1_33_is_rejected" {
  command = plan

  variables {
    enable_envoy_gateway = true
    eks_cluster_version  = "1.32"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "envoy_gateway_on_an_old_eks_is_allowed_when_it_is_off" {
  command = plan

  variables {
    enable_envoy_gateway = false
    enable_nginx_ingress = true
    eks_cluster_version  = "1.32"
  }
}

run "envoy_gateway_on_eks_above_1_36_warns" {
  command = plan

  variables {
    enable_envoy_gateway = true
    eks_cluster_version  = "1.37"
  }

  expect_failures = [check.envoy_gateway_kubernetes_range]
}
