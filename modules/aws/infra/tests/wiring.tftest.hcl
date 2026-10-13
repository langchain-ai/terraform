# Conditional wiring in the AWS root: every optional module, asserted in both
# directions. mock_provider means no cloud credentials, no state, and no API
# calls, so these run in the PR path.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  name_prefix       = "plantest"
  postgres_password = "fixture-not-a-real-secret-Aa1"
  redis_auth_token  = "fixture-not-a-real-token-0123456789"

  # tls_certificate_source defaults to acm, which requires either a certificate
  # ARN or a domain. The ARN keeps the dns module off by default, so it gets its
  # own run below.
  acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "optional_modules_absent_when_flags_are_false" {
  command = plan

  variables {
    create_firewall          = false
    create_cloudtrail        = false
    create_waf               = false
    create_bastion           = false
    create_cert_manager_irsa = false
    enable_sandboxes         = false
    enable_smithdb           = false
  }

  assert {
    condition     = length(module.firewall) == 0
    error_message = "create_firewall = false still planned the firewall"
  }
  assert {
    condition     = length(module.cloudtrail) == 0
    error_message = "create_cloudtrail = false still planned CloudTrail"
  }
  assert {
    condition     = length(module.waf) == 0
    error_message = "create_waf = false still planned the WAF"
  }
  assert {
    condition     = length(module.bastion) == 0
    error_message = "create_bastion = false still planned the bastion"
  }
  assert {
    condition     = length(module.cert_manager) == 0
    error_message = "create_cert_manager_irsa = false still planned the cert-manager IRSA role"
  }
  assert {
    condition     = length(module.sandbox_juicefs_redis) == 0
    error_message = "enable_sandboxes = false still planned the JuiceFS Redis"
  }
  assert {
    condition     = length(module.smithdb) == 0
    error_message = "enable_smithdb = false still planned SmithDB"
  }
}

# ── Optional modules, one flag at a time ─────────────────────────────────────
# Every run flips exactly one flag, so a run that also plans a sibling module
# means two gates read the same variable.

# The firewall module is overridden for the same reason as the dns module below,
# but here the cause is worth a second look: it does
# for_each = toset(var.private_route_table_ids) over route table IDs that the VPC
# module creates in the same run, and no provider reports a created resource's ID
# at plan time. A greenfield plan with create_firewall = true therefore looks
# like it cannot succeed in one pass.
run "create_firewall_adds_only_the_firewall" {
  command = plan

  variables {
    create_firewall = true
  }

  override_module {
    target = module.firewall
    outputs = {
      firewall_arn         = "arn:aws:network-firewall:us-east-2:123456789012:firewall/plan-tests"
      firewall_endpoint_id = "vpce-00000000000000001"
      firewall_subnet_id   = "subnet-00000000000000005"
      firewall_policy_arn  = "arn:aws:network-firewall:us-east-2:123456789012:firewall-policy/plan-tests"
      rule_group_arn       = "arn:aws:network-firewall:us-east-2:123456789012:stateful-rulegroup/plan-tests"
    }
  }

  assert {
    condition     = length(module.firewall) == 1
    error_message = "create_firewall = true did not plan the firewall"
  }
  assert {
    condition     = length(module.waf) == 0
    error_message = "create_firewall = true also planned the WAF"
  }
}

run "create_cloudtrail_adds_only_cloudtrail" {
  command = plan

  variables {
    create_cloudtrail = true
  }

  assert {
    condition     = length(module.cloudtrail) == 1
    error_message = "create_cloudtrail = true did not plan CloudTrail"
  }
  assert {
    condition     = length(module.waf) == 0
    error_message = "create_cloudtrail = true also planned the WAF"
  }
}

run "create_waf_adds_only_the_waf" {
  command = plan

  variables {
    create_waf = true
  }

  assert {
    condition     = length(module.waf) == 1
    error_message = "create_waf = true did not plan the WAF"
  }
  assert {
    condition     = length(module.cloudtrail) == 0
    error_message = "create_waf = true also planned CloudTrail"
  }
}

run "create_bastion_adds_only_the_bastion" {
  command = plan

  variables {
    create_bastion = true
  }

  assert {
    condition     = length(module.bastion) == 1
    error_message = "create_bastion = true did not plan the bastion"
  }
  assert {
    condition     = length(module.waf) == 0
    error_message = "create_bastion = true also planned the WAF"
  }
}

# The DNS-01 Let's Encrypt path. The hosted zone and the contact address are
# required alongside the flag, so all three move together.
run "cert_manager_irsa_adds_only_cert_manager" {
  command = plan

  variables {
    create_cert_manager_irsa    = true
    cert_manager_hosted_zone_id = "Z00000000000000000001"
    letsencrypt_email           = "plan-tests@example.com"
  }

  assert {
    condition     = length(module.cert_manager) == 1
    error_message = "create_cert_manager_irsa = true did not plan the cert-manager IRSA role"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "create_cert_manager_irsa = true also planned the dns module"
  }
}

run "enable_sandboxes_adds_the_juicefs_redis" {
  command = plan

  variables {
    enable_sandboxes                 = true
    sandbox_juicefs_redis_auth_token = "fixture-not-a-real-token-0123456789"
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 1
    error_message = "enable_sandboxes = true did not plan the JuiceFS Redis"
  }
  assert {
    condition     = length(module.redis) == 1
    error_message = "the shared Redis is separate from the JuiceFS Redis and must still be planned"
  }
}

run "enable_smithdb_adds_only_smithdb" {
  command = plan

  variables {
    enable_smithdb = true
  }

  assert {
    condition     = length(module.smithdb) == 1
    error_message = "enable_smithdb = true did not plan SmithDB"
  }
  assert {
    condition     = length(module.bastion) == 0
    error_message = "enable_smithdb = true also planned the bastion"
  }
}

# ── DNS, which is gated on two variables rather than a flag ──────────────────
# A domain with no certificate ARN means Terraform provisions the Route 53 zone
# and the ACM certificate. Supplying the ARN means the customer already has one.

# The dns module itself is overridden. It builds its ACM validation records with
# a for_each over the certificate's domain_validation_options, which no provider
# reports until apply, so planning the module body fails before any assertion
# runs. Overriding it still exercises the gate, which is what this run is for.
run "a_domain_without_a_certificate_arn_plans_dns" {
  command = plan

  variables {
    langsmith_domain    = "plan-tests.example.com"
    acm_certificate_arn = ""
  }

  override_module {
    target = module.dns
    outputs = {
      zone_id         = "Z00000000000000000001"
      name_servers    = ["ns-1.awsdns-00.com", "ns-2.awsdns-00.net"]
      certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }

  assert {
    condition     = length(module.dns) == 1
    error_message = "a domain with no certificate ARN did not plan the dns module"
  }
}

run "a_certificate_arn_plans_no_dns" {
  command = plan

  variables {
    langsmith_domain = "plan-tests.example.com"
  }

  assert {
    condition     = length(module.dns) == 0
    error_message = "an existing certificate ARN still planned the dns module"
  }
}

# ── Bring your own VPC ───────────────────────────────────────────────────────

run "create_vpc_false_plans_no_vpc" {
  command = plan

  variables {
    create_vpc      = false
    vpc_id          = "vpc-00000000000000001"
    vpc_cidr_block  = "10.0.0.0/16"
    private_subnets = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets  = ["subnet-00000000000000003", "subnet-00000000000000004"]
  }

  assert {
    condition     = length(module.vpc) == 0
    error_message = "create_vpc = false still planned a VPC"
  }
}

# ── EKS network mode ─────────────────────────────────────────────────────────
# custom-networking moves pods to their own subnets. Everything downstream (the
# vpc-cni add-on, Karpenter's reserved ENI, the pod CIDRs in the security group
# rules) keys off pod_subnet_ids_by_az and pod_cidr_blocks, so the runs assert
# those two and the subnets behind them.

run "node_subnet_mode_plans_no_pod_subnets" {
  command = plan

  variables {
    # Add-ons of different shapes, one of them vpc-cni, must plan in either
    # mode. Both modes route them through the vpc-cni filter in the eks module.
    eks_addons = {
      coredns    = { most_recent = true, timeouts = { create = "25m" } }
      kube-proxy = { addon_version = "v1.34.0-eksbuild.1" }
      vpc-cni    = { most_recent = true, configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\"}}" }
    }
  }

  assert {
    condition     = length(module.vpc[0].pod_subnets) == 0
    error_message = "eks_network_mode = node-subnet still planned pod subnets"
  }
  assert {
    condition     = length(local.pod_subnet_ids_by_az) == 0 && length(local.pod_cidr_blocks) == 0
    error_message = "eks_network_mode = node-subnet still turned on custom networking"
  }
  assert {
    condition     = local.alb_ingress_cidr_blocks == tolist(["0.0.0.0/0"])
    error_message = "eks_network_mode = node-subnet changed the ALB ingress CIDRs"
  }
}

run "custom_networking_plans_a_pod_subnet_per_az" {
  command = plan

  variables {
    eks_network_mode = "custom-networking"
    # Add-ons of different shapes, one of them vpc-cni, must plan in either
    # mode. Both modes route them through the vpc-cni filter in the eks module.
    eks_addons = {
      coredns    = { most_recent = true, timeouts = { create = "25m" } }
      kube-proxy = { addon_version = "v1.34.0-eksbuild.1" }
      vpc-cni    = { most_recent = true, configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\"}}" }
    }
  }

  assert {
    condition     = length(module.vpc[0].pod_subnets) == 3
    error_message = "custom networking did not plan one pod subnet per AZ"
  }
  assert {
    condition     = keys(local.pod_subnet_ids_by_az) == tolist(["us-east-2a", "us-east-2b", "us-east-2c"])
    error_message = "custom networking did not key the pod subnets by AZ"
  }
  assert {
    condition     = local.pod_cidr_blocks == tolist(["100.64.0.0/16"])
    error_message = "custom networking did not add eks_pod_cidr to the security group rules"
  }
}

run "custom_networking_admits_pods_to_a_restricted_alb" {
  command = plan

  variables {
    eks_network_mode        = "custom-networking"
    alb_scheme              = "internal"
    alb_allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  assert {
    condition     = local.alb_ingress_cidr_blocks == tolist(["10.0.0.0/16", "100.64.0.0/16"])
    error_message = "custom networking did not add eks_pod_cidr to the ALB ingress rules"
  }
}

run "byo_custom_networking_uses_the_supplied_pod_subnets" {
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

  # One AZ for every subnet: a mock would invent a different one per subnet.
  override_data {
    target = data.aws_subnet.pod
    values = { availability_zone = "us-east-2a", cidr_block = "100.64.0.0/18", vpc_id = "vpc-00000000000000001" }
  }
  override_data {
    target = data.aws_subnet.cluster
    values = { availability_zone = "us-east-2a" }
  }

  assert {
    condition     = local.pod_subnet_ids_by_az == tomap({ "us-east-2a" = "subnet-00000000000000005" })
    error_message = "a BYO VPC did not key the supplied pod subnet by its AZ"
  }
  assert {
    condition     = local.pod_cidr_blocks == tolist(["100.64.0.0/18"])
    error_message = "a BYO VPC did not add the pod subnet CIDR to the security group rules"
  }
}

# ── Data plane source switches ───────────────────────────────────────────────
# in-cluster means the chart runs it, so Terraform must plan nothing.

run "external_postgres_is_planned" {
  command = plan

  variables {
    postgres_source = "external"
  }

  assert {
    condition     = length(module.postgres) == 1
    error_message = "postgres_source = external did not plan RDS"
  }
}

run "in_cluster_postgres_plans_nothing" {
  command = plan

  variables {
    postgres_source = "in-cluster"
  }

  assert {
    condition     = length(module.postgres) == 0
    error_message = "postgres_source = in-cluster still planned RDS"
  }
}

run "external_redis_is_planned" {
  command = plan

  variables {
    redis_source = "external"
  }

  assert {
    condition     = length(module.redis) == 1
    error_message = "redis_source = external did not plan ElastiCache"
  }
}

run "in_cluster_redis_plans_nothing" {
  command = plan

  variables {
    redis_source = "in-cluster"
  }

  assert {
    condition     = length(module.redis) == 0
    error_message = "redis_source = in-cluster still planned ElastiCache"
  }
}

# ── Add-on storage switches ──────────────────────────────────────────────────
# fleet_storage decides who owns the Fleet database and Redis index: Terraform
# on the shared RDS and ElastiCache, or the chart's own in-cluster StatefulSets.
# Chart v0.16 added the in-cluster path, so both directions need a run.

run "external_fleet_storage_plans_the_shared_credentials" {
  command = plan

  variables {
    enable_fleet    = true
    fleet_storage   = "external"
    postgres_source = "external"
    redis_source    = "external"
  }

  assert {
    condition     = length(kubernetes_secret.fleet_postgres) == 1
    error_message = "fleet_storage = external did not plan the Fleet Postgres secret"
  }
  assert {
    condition     = length(kubernetes_secret.fleet_redis) == 1
    error_message = "fleet_storage = external did not plan the Fleet Redis secret"
  }
}

run "in_cluster_fleet_storage_plans_no_shared_credentials" {
  command = plan

  variables {
    enable_fleet    = true
    fleet_storage   = "in-cluster"
    postgres_source = "external"
    redis_source    = "external"
  }

  assert {
    condition     = length(kubernetes_secret.fleet_postgres) == 0
    error_message = "fleet_storage = in-cluster still planned the Fleet Postgres secret"
  }
  assert {
    condition     = length(kubernetes_secret.fleet_redis) == 0
    error_message = "fleet_storage = in-cluster still planned the Fleet Redis secret"
  }
}
