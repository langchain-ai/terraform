# Tag propagation in the AWS root. Provider default_tags cover every resource
# Terraform creates directly; these runs assert that the same tags reach the
# resources that controllers create outside Terraform, where a tag-enforcing SCP
# or tag policy would otherwise reject the create call.

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

  owner       = "platform@example.com"
  cost_center = "cc-1234"
  tags = {
    team    = "data platform"
    product = "langsmith"
  }
}

run "common_tags_reach_the_controllers" {
  command = plan

  variables {
    enable_smithdb = true
  }

  assert {
    condition = alltrue([
      for k in ["team", "product", "owner", "cost-center", "environment"] :
      contains(keys(local.common_tags), k)
    ])
    error_message = "common_tags is missing a custom tag or a built-in one"
  }
  assert {
    condition     = tomap(jsondecode(module.eks.controller_tag_inputs.ebs_csi_configuration_values).controller.extraVolumeTags) == tomap(local.common_tags)
    error_message = "the EBS CSI add-on does not tag the volumes and snapshots it creates"
  }
  assert {
    condition     = tomap(yamldecode(module.eks.controller_tag_inputs.load_balancer_controller_values[0]).defaultTags) == tomap(local.common_tags)
    error_message = "the load balancer controller does not tag the ALB, target groups, and security groups it creates"
  }
  assert {
    condition     = tomap(yamldecode(nonsensitive(kubectl_manifest.smithdb_ec2nc_instance_store[0].yaml_body)).spec.tags) == tomap(local.common_tags)
    error_message = "the SmithDB instance-store EC2NodeClass does not tag what Karpenter launches"
  }
  assert {
    condition     = tomap(yamldecode(nonsensitive(kubectl_manifest.smithdb_ec2nc_compute[0].yaml_body)).spec.tags) == tomap(local.common_tags)
    error_message = "the SmithDB compute EC2NodeClass does not tag what Karpenter launches"
  }
  # The upstream node group module puts its tags in the launch template's
  # tag_specifications for instances, volumes, and ENIs, but only when it builds
  # the launch template itself.
  assert {
    condition = alltrue([
      for g in values(module.eks.eks_managed_node_group_inputs) :
      try(g.use_custom_launch_template, true) && try(g.create_launch_template, true)
    ])
    error_message = "a managed node group skips the launch template that tags its instances, volumes, and ENIs"
  }
}

# By default this module takes over the vpc-cni EKS installs, so the CNI's pod
# ENIs carry the tags from the first node on.
run "common_tags_reach_the_pod_enis_by_default" {
  command = plan

  assert {
    condition     = module.eks.vpc_cni_inputs.module_managed && !module.eks.vpc_cni_inputs.blueprints_managed
    error_message = "the eks module does not own vpc-cni by default, so EKS's self-managed CNI creates untagged pod ENIs"
  }
  assert {
    condition     = tomap(jsondecode(jsondecode(module.eks.controller_tag_inputs.vpc_cni_configuration_values).env.ADDITIONAL_ENI_TAGS)) == tomap(local.common_tags)
    error_message = "the default vpc-cni add-on does not tag the pod ENIs it creates"
  }
  # Taking over an existing cluster's CNI must fail on hand-edited aws-node
  # settings rather than revert them, and must not install an older version.
  assert {
    condition     = module.eks.vpc_cni_inputs.resolve_on_create == "NONE" && module.eks.vpc_cni_inputs.most_recent == true
    error_message = "the default vpc-cni add-on would overwrite hand-edited aws-node settings or could downgrade the CNI"
  }
  assert {
    condition     = module.eks.vpc_cni_inputs.dataplane_wait_duration == "2m"
    error_message = "node groups do not wait for the vpc-cni add-on, so their first pod ENIs go untagged"
  }
}

# Custom networking also owns vpc-cni. Created pod subnets leave its
# configuration unknown at plan, so this run brings its own.
run "common_tags_reach_the_pod_enis_under_custom_networking" {
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
    values = { availability_zone = "us-east-2a" }
  }

  assert {
    condition     = tomap(jsondecode(jsondecode(module.eks.controller_tag_inputs.vpc_cni_configuration_values).env.ADDITIONAL_ENI_TAGS)) == tomap(local.common_tags)
    error_message = "the vpc-cni add-on does not tag the pod ENIs it creates"
  }
  # Existing custom-networking add-ons keep their create settings and version.
  assert {
    condition     = module.eks.vpc_cni_inputs.resolve_on_create == null && module.eks.vpc_cni_inputs.most_recent == null
    error_message = "the custom networking vpc-cni add-on changed its conflict resolution or version selection"
  }
}

# A vpc-cni entry in eks_addons stays with the Blueprints add-on, at the state
# address it already has. The operator's own env settings must survive next to
# the tags.
run "common_tags_reach_the_pod_enis_when_eks_addons_lists_vpc_cni" {
  command = plan

  variables {
    eks_addons = {
      coredns = { most_recent = true }
      vpc-cni = { most_recent = true, configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\"}}" }
    }
  }

  assert {
    condition     = tomap(jsondecode(jsondecode(module.eks.controller_tag_inputs.vpc_cni_configuration_values).env.ADDITIONAL_ENI_TAGS)) == tomap(local.common_tags)
    error_message = "a vpc-cni entry in eks_addons does not tag the pod ENIs it creates"
  }
  assert {
    condition     = jsondecode(module.eks.controller_tag_inputs.vpc_cni_configuration_values).env.ENABLE_PREFIX_DELEGATION == "true"
    error_message = "adding the ENI tags dropped the operator's own vpc-cni env settings"
  }
  assert {
    condition     = !module.eks.vpc_cni_inputs.module_managed && module.eks.vpc_cni_inputs.blueprints_managed
    error_message = "a vpc-cni entry in eks_addons moved out of the Blueprints add-on, which would create a second vpc-cni add-on"
  }
  assert {
    condition     = module.eks.vpc_cni_inputs.dataplane_wait_duration == "30s"
    error_message = "node groups wait for a vpc-cni add-on this module does not create"
  }
}

run "tags_reject_a_value_aws_or_a_controller_would_refuse" {
  command = plan

  variables {
    tags = {
      "aws:team"              = "data"
      "kubernetes.io/role"    = "x"
      "karpenter.sh/nodepool" = "x"
      "team,product"          = "x"
      "owner"                 = "a\"b"
    }
  }

  expect_failures = [var.tags]
}
