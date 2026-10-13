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
  assert {
    condition     = length(module.vpc_endpoints) == 0
    error_message = "create_vpc_endpoints = false still planned the interface endpoints"
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
  assert {
    condition     = length(aws_security_group_rule.bastion_to_cluster_api) == 1
    error_message = "create_bastion = true did not open 443 from the bastion to the cluster"
  }
  assert {
    condition     = length(aws_eks_access_entry.bastion) == 0
    error_message = "create_bastion = true granted cluster admin without bastion_cluster_admin"
  }
}

run "bastion_cluster_admin_adds_the_access_entry" {
  command = plan

  variables {
    create_bastion        = true
    bastion_cluster_admin = true
    fix_bastion_names     = true
  }

  assert {
    condition     = length(aws_eks_access_entry.bastion) == 1
    error_message = "bastion_cluster_admin = true did not plan the access entry"
  }
  assert {
    condition     = aws_eks_access_policy_association.bastion[0].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "bastion_cluster_admin = true did not associate the cluster admin policy"
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

run "iam_roles_default_to_no_boundary_and_the_root_path" {
  command = plan

  variables {
    enable_smithdb = true
  }

  assert {
    condition     = module.eks.karpenter_node_iam_role_name == "karpenter-plantest-dev-eks"
    error_message = "With prefix_iam_role_names unset, the Karpenter node role lost its upstream name"
  }
  assert {
    condition     = aws_iam_role.eso[0].permissions_boundary == null
    error_message = "With iam_permissions_boundary_arn unset, the ESO role planned a boundary"
  }
  assert {
    condition     = aws_iam_role.eso[0].path == "/"
    error_message = "With iam_role_path unset, the ESO role planned a path other than /"
  }
  assert {
    condition     = length(aws_iam_role_policy.langsmith_s3) == 1
    error_message = "With existing_iam_role_arns unset, the LangSmith role lost its S3 policy"
  }
  assert {
    condition     = output.iam_role_trust_policies == {}
    error_message = "With existing_iam_role_arns unset, iam_role_trust_policies is not empty"
  }
}

# Every module that creates a role is on, so a boundary that one of them fails
# to accept stops this plan.
run "iam_boundary_and_path_reach_the_roles" {
  command = plan

  variables {
    iam_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/plantest-boundary"
    iam_role_path                = "/langsmith/"
    create_bastion               = true
    create_cert_manager_irsa     = true
    cert_manager_hosted_zone_id  = "Z00000000000000000001"
    letsencrypt_email            = "plan-tests@example.com"
    enable_smithdb               = true
  }

  assert {
    condition     = aws_iam_role.eso[0].permissions_boundary == "arn:aws:iam::123456789012:policy/plantest-boundary"
    error_message = "iam_permissions_boundary_arn did not reach the ESO role"
  }
  assert {
    condition     = aws_iam_role.eso[0].path == "/langsmith/"
    error_message = "iam_role_path did not reach the ESO role"
  }
}

run "prefix_iam_role_names_starts_the_upstream_names_with_the_base" {
  command = plan

  variables {
    prefix_iam_role_names = true
    enable_smithdb        = true
  }

  assert {
    condition     = module.eks.karpenter_node_iam_role_name == "plantest-dev-karpenter-node"
    error_message = "prefix_iam_role_names did not reach the Karpenter node role"
  }
}

# Every module that creates a role is on, so a role that one of them still
# creates or attaches a policy to shows up here.
run "existing_iam_role_arns_replace_the_roles" {
  command = plan

  variables {
    create_cert_manager_irsa    = true
    cert_manager_hosted_zone_id = "Z00000000000000000001"
    letsencrypt_email           = "plan-tests@example.com"
    enable_smithdb              = true
    existing_iam_role_arns = {
      cluster            = "arn:aws:iam::123456789012:role/plantest-cluster"
      node_group         = "arn:aws:iam::123456789012:role/plantest-node"
      karpenter_node     = "arn:aws:iam::123456789012:role/langsmith/plantest-karpenter-node"
      karpenter          = "arn:aws:iam::123456789012:role/plantest-karpenter"
      alb_controller     = "arn:aws:iam::123456789012:role/plantest-alb"
      cluster_autoscaler = "arn:aws:iam::123456789012:role/plantest-autoscaler"
      ebs_csi            = "arn:aws:iam::123456789012:role/plantest-ebs-csi"
      langsmith          = "arn:aws:iam::123456789012:role/plantest-langsmith"
      eso                = "arn:aws:iam::123456789012:role/plantest-eso"
      smithdb            = "arn:aws:iam::123456789012:role/plantest-smithdb"
      cert_manager       = "arn:aws:iam::123456789012:role/plantest-cert-manager"
    }
  }

  assert {
    condition     = length(aws_iam_role.eso) == 0 && length(aws_iam_role_policy.eso_ssm) == 0
    error_message = "existing_iam_role_arns.eso still planned the ESO role or its policy"
  }
  assert {
    condition     = length(aws_iam_role_policy.langsmith_s3) == 0
    error_message = "existing_iam_role_arns.langsmith still planned a policy on the supplied role"
  }
  assert {
    condition     = length(module.cert_manager) == 0
    error_message = "existing_iam_role_arns.cert_manager still planned the cert-manager role"
  }
  assert {
    condition     = output.langsmith_irsa_role_arn == "arn:aws:iam::123456789012:role/plantest-langsmith"
    error_message = "existing_iam_role_arns.langsmith did not reach the langsmith_irsa_role_arn output"
  }
  assert {
    condition     = output.smithdb_irsa_role_arn == "arn:aws:iam::123456789012:role/plantest-smithdb"
    error_message = "existing_iam_role_arns.smithdb did not reach the smithdb_irsa_role_arn output"
  }
  assert {
    condition     = output.cert_manager_irsa_role_arn == "arn:aws:iam::123456789012:role/plantest-cert-manager"
    error_message = "existing_iam_role_arns.cert_manager did not reach the cert_manager_irsa_role_arn output"
  }
  assert {
    condition     = module.eks.karpenter_node_iam_role_name == "plantest-karpenter-node"
    error_message = "The Karpenter node role name was not taken from the last segment of its ARN"
  }
  assert {
    condition     = toset(keys(output.iam_role_trust_policies)) == toset(["ebs_csi", "alb_controller", "cluster_autoscaler", "karpenter", "langsmith", "eso", "cert_manager", "smithdb"])
    error_message = "iam_role_trust_policies does not cover exactly the supplied IRSA roles"
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

# The sandbox-host group carries attributes outside the eks_managed_node_groups
# object type. A typed path drops them silently, and the upstream module then
# falls back to its own metadata_options default of hop limit 2, which lets pods
# reach the node's IMDS credentials.
run "sandbox_host_node_group_keeps_metadata_options_and_overrides" {
  command = plan

  variables {
    enable_sandboxes                 = true
    sandbox_juicefs_redis_auth_token = "fixture-not-a-real-token-0123456789"
    sandbox_host_node_group_overrides = {
      capacity_type = "SPOT"
      ami_type      = "AL2023_x86_64_NVIDIA"
      cpu_options   = { core_count = 24 }
    }
  }

  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].metadata_options.http_tokens == "required"
    error_message = "the sandbox-host node group lost http_tokens = required on the way to the EKS module"
  }
  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].metadata_options.http_put_response_hop_limit == 1
    error_message = "the sandbox-host node group lost its IMDS hop limit of 1 on the way to the EKS module"
  }
  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].capacity_type == "SPOT"
    error_message = "sandbox_host_node_group_overrides.capacity_type did not reach the EKS module"
  }
  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].ami_type == "AL2023_x86_64_NVIDIA"
    error_message = "sandbox_host_node_group_overrides.ami_type did not reach the EKS module"
  }
  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].cpu_options.core_count == 24
    error_message = "sandbox_host_node_group_overrides.cpu_options did not reach the EKS module"
  }
  assert {
    condition     = module.eks.eks_managed_node_group_inputs["default"].desired_size == 3
    error_message = "the default node group no longer gets desired_size from min_size"
  }
}

run "sandbox_host_node_group_null_overrides_fall_back" {
  command = plan

  variables {
    enable_sandboxes                 = true
    sandbox_juicefs_redis_auth_token = "fixture-not-a-real-token-0123456789"
    sandbox_host_node_count          = 2
    sandbox_host_node_group_overrides = {
      desired_size             = null
      iam_role_use_name_prefix = null
    }
  }

  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].desired_size == 2
    error_message = "a null desired_size override no longer falls back to min_size"
  }
  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].iam_role_use_name_prefix == true
    error_message = "a null iam_role_use_name_prefix override no longer falls back to true"
  }
  assert {
    condition     = module.eks.eks_managed_node_group_inputs["sandbox_host"].metadata_options.http_put_response_hop_limit == 1
    error_message = "the sandbox-host node group lost its IMDS hop limit of 1 on the way to the EKS module"
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

# The stack sits inside the Blueprints module, out of an assert's reach, so this
# run proves only that the null tag plans.
run "eks_blueprints_telemetry_stack_can_be_skipped" {
  command = plan

  variables {
    create_eks_blueprints_telemetry_stack = false
  }
}

# The runner rule sits inside the eks module, out of an assert's reach, so this
# run proves only that a private endpoint with a runner CIDR plans.
run "private_endpoint_with_a_runner_cidr_plans" {
  command = plan

  variables {
    enable_public_eks_cluster = false
    eks_private_access_cidrs  = ["10.100.0.0/16"]
  }
}

# Node group subnets and the public IP setting sit inside the eks and vpc
# modules, out of an assert's reach, so this run proves only that they plan.
run "private_subnet_node_groups_without_public_ips_plan" {
  command = plan

  variables {
    eks_node_groups_private_subnets_only = true
    vpc_map_public_ip_on_launch          = false
  }
}

run "create_vpc_endpoints_adds_the_default_set" {
  command = plan

  variables {
    create_vpc_endpoints = true
  }

  assert {
    condition     = length(module.vpc_endpoints) == 1
    error_message = "create_vpc_endpoints = true did not plan the interface endpoints"
  }
  assert {
    condition     = length(output.vpc_endpoint_ids) == 14
    error_message = "create_vpc_endpoints = true did not plan one endpoint per default service"
  }
}

run "no_internet_egress_drops_the_nat_gateway" {
  command = plan

  variables {
    enable_internet_egress = false
    alb_scheme             = "internal"
    create_vpc_endpoints   = true
  }

  assert {
    condition     = module.vpc[0].nat_gateway_id == null
    error_message = "enable_internet_egress = false still planned a NAT gateway"
  }
}

run "no_internet_egress_with_a_bastion_copies_tools_from_s3" {
  command = plan

  variables {
    enable_internet_egress = false
    alb_scheme             = "internal"
    create_vpc_endpoints   = true
    create_bastion         = true
    bastion_tools_s3_uri   = "s3://tools-bucket/bastion"
  }

  assert {
    condition     = length(module.bastion) == 1
    error_message = "a bastion with bastion_tools_s3_uri did not plan without internet egress"
  }
}

# Every release key at once, with both fields, so a type mismatch in any lookup
# fails the plan.
run "helm_chart_overrides_accept_every_release" {
  command = plan

  variables {
    envoy_proxy_image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/docker.io/envoyproxy/envoy:distroless-v1.33.0"
    helm_chart_overrides = {
      for k in [
        "keda", "cert_manager", "external_secrets", "envoy_gateway", "istio_base", "istiod",
        "istio_ingress", "ingress_nginx", "aws_load_balancer_controller", "metrics_server",
        "cluster_autoscaler", "karpenter",
      ] : k => { repository = "oci://123456789012.dkr.ecr.us-east-2.amazonaws.com/charts", values = "image:\n  registry: mirror.example.com\n" }
    }
  }

  assert {
    condition     = length(var.helm_chart_overrides) == 12
    error_message = "helm_chart_overrides did not accept every release key"
  }
}

run "an_existing_s3_endpoint_replaces_the_created_one" {
  command = plan

  variables {
    create_s3_gateway_endpoint = false
    s3_gateway_endpoint_id     = "vpce-0123456789abcdef0"
  }

  assert {
    condition     = module.storage.s3_vpc_endpoint_id == "vpce-0123456789abcdef0"
    error_message = "the bucket policy does not admit the existing S3 endpoint"
  }
}

run "byo_vpc_smithdb_tags_the_private_subnets" {
  command = plan

  variables {
    create_vpc      = false
    vpc_id          = "vpc-00000000000000001"
    vpc_cidr_block  = "10.0.0.0/16"
    private_subnets = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets  = ["subnet-00000000000000003", "subnet-00000000000000004"]
    enable_smithdb  = true
  }

  assert {
    condition     = length(aws_ec2_tag.smithdb_karpenter_subnet) == 2
    error_message = "with smithdb_karpenter_subnet_selector unset, SmithDB did not tag each BYO private subnet"
  }
  assert {
    condition     = local.smithdb_karpenter_subnet_tags == tomap({ "karpenter.sh/discovery" = "plantest-dev-eks" })
    error_message = "with smithdb_karpenter_subnet_selector unset, the EC2NodeClasses do not select the discovery tag"
  }
}

run "byo_vpc_smithdb_subnet_selector_skips_the_tags" {
  command = plan

  variables {
    create_vpc                        = false
    vpc_id                            = "vpc-00000000000000001"
    vpc_cidr_block                    = "10.0.0.0/16"
    private_subnets                   = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnets                    = ["subnet-00000000000000003", "subnet-00000000000000004"]
    enable_smithdb                    = true
    smithdb_karpenter_subnet_selector = { "smithdb" = "true" }
  }

  assert {
    condition     = length(aws_ec2_tag.smithdb_karpenter_subnet) == 0
    error_message = "smithdb_karpenter_subnet_selector still tagged the BYO private subnets"
  }
  assert {
    condition     = local.smithdb_karpenter_subnet_tags == tomap({ "smithdb" = "true" })
    error_message = "the EC2NodeClasses do not select smithdb_karpenter_subnet_selector"
  }
}

run "no_customer_managed_keys_leaves_aws_managed_keys" {
  command = plan

  variables {
    enable_smithdb = true
  }

  # The S3 policy embeds the bucket ARN, which is unknown at plan without this.
  override_resource {
    target          = module.storage.aws_s3_bucket.bucket
    override_during = plan
    values          = { arn = "arn:aws:s3:::plantest-dev-langsmith" }
  }

  assert {
    condition     = !strcontains(kubectl_manifest.smithdb_ec2nc_compute[0].yaml_body, "kmsKeyID")
    error_message = "with ebs_kms_key_arn unset, the SmithDB EC2NodeClass named a KMS key"
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.eso_ssm[0].policy, "kms:")
    error_message = "with ssm_kms_key_arn unset, the ESO policy granted a KMS action"
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.langsmith_s3[0].policy, "kms:")
    error_message = "with s3_kms_key_arn unset, the LangSmith S3 policy granted a KMS action"
  }
}

# Every key at once, with every resource it reaches enabled, so a type mismatch
# in any of the wiring fails the plan.
run "customer_managed_keys_reach_every_resource" {
  command = plan

  variables {
    enable_smithdb                   = true
    enable_sandboxes                 = true
    sandbox_juicefs_redis_auth_token = "fixture-not-a-real-token-0123456789"
    postgres_source                  = "external"
    redis_source                     = "external"
    rds_kms_key_arn                  = "arn:aws:kms:us-east-2:123456789012:key/0123abcd-0123-0123-0123-0123456789ab"
    elasticache_kms_key_arn          = "arn:aws:kms:us-east-2:123456789012:key/0123abcd-0123-0123-0123-0123456789ac"
    ebs_kms_key_arn                  = "arn:aws:kms:us-east-2:123456789012:key/mrk-0123456789abcdef0123456789abcdef"
    eks_secrets_kms_key_arn          = "arn:aws:kms:us-east-2:123456789012:key/0123abcd-0123-0123-0123-0123456789ae"
    ssm_kms_key_arn                  = "arn:aws:kms:us-east-2:123456789012:key/0123abcd-0123-0123-0123-0123456789af"
    s3_kms_key_arn                   = "arn:aws:kms:us-east-2:123456789012:key/0123abcd-0123-0123-0123-0123456789b0"
  }

  override_resource {
    target          = module.storage.aws_s3_bucket.bucket
    override_during = plan
    values          = { arn = "arn:aws:s3:::plantest-dev-langsmith" }
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.eso_ssm[0].policy, var.ssm_kms_key_arn)
    error_message = "the ESO policy does not grant kms:Decrypt on ssm_kms_key_arn"
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.langsmith_s3[0].policy, var.s3_kms_key_arn)
    error_message = "the LangSmith S3 policy does not grant the use of s3_kms_key_arn"
  }

  assert {
    condition     = strcontains(kubectl_manifest.smithdb_ec2nc_compute[0].yaml_body, var.ebs_kms_key_arn)
    error_message = "the SmithDB EC2NodeClass does not name ebs_kms_key_arn"
  }
  assert {
    condition     = strcontains(kubectl_manifest.smithdb_ec2nc_instance_store[0].yaml_body, var.ebs_kms_key_arn)
    error_message = "the SmithDB instance-store EC2NodeClass does not name ebs_kms_key_arn"
  }
}
