# sandbox_deployment_mode = "separate_cluster": the dedicated sandbox EKS
# cluster, its IAM role, network rules and Secrets, and the input checks that
# guard it, each asserted in both directions. mock_provider means no cloud
# credentials, state, or API calls.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

# The Secrets in the sandbox cluster go through the aliased provider.
mock_provider "kubernetes" {
  alias = "sandbox"
}

variables {
  name_prefix         = "plantest"
  postgres_password   = "fixture-not-a-real-secret-Aa1"
  redis_auth_token    = "fixture-not-a-real-token-0123456789"
  acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"

  enable_sandboxes                 = true
  sandbox_juicefs_redis_auth_token = "fixture-not-a-real-token-0123456789"
  sandbox_deployment_mode          = "separate_cluster"
  langsmith_helm_chart_version     = "0.18.0"
  langsmith_api_key_salt           = "fixture-not-a-real-salt"
  sandbox_callback_signing_jwk     = "fixture-not-a-real-jwk"
  sandbox_service_auth_secret      = "fixture-not-a-real-sandbox-service-auth-secret"
}

run "same_cluster_plans_no_sandbox_cluster" {
  command = plan

  # same_cluster keeps the chart's default service-auth key, api_key_salt, so it
  # needs no dedicated secret. Both empty would trip the separate_cluster
  # secret checks if they were not gated on the mode.
  variables {
    sandbox_deployment_mode      = "same_cluster"
    langsmith_helm_chart_version = ""
    sandbox_service_auth_secret  = ""
    langsmith_api_key_salt       = ""
  }

  assert {
    condition = (
      length(module.sandbox_eks) == 0 &&
      length(aws_iam_role.sandbox_host) == 0 &&
      length(aws_iam_role_policy.sandbox_host_s3) == 0 &&
      length(aws_vpc_security_group_ingress_rule.sandbox_host_from_langsmith) == 0 &&
      length(aws_vpc_security_group_ingress_rule.sandbox_host_from_sandbox_nodes) == 0 &&
      length(kubernetes_secret_v1.sandbox_runtime) == 0 &&
      length(kubernetes_secret_v1.sandbox_juicefs_config) == 0
    )
    error_message = "same_cluster planned separate-cluster resources"
  }
  assert {
    condition     = contains(keys(module.eks.eks_managed_node_group_inputs), "sandbox_host")
    error_message = "same_cluster did not put the sandbox-host node group in the LangSmith cluster"
  }
  assert {
    condition     = length(kubernetes_secret_v1.sandbox_juicefs_csi_config) == 1
    error_message = "same_cluster did not plan the JuiceFS config Secret in the LangSmith namespace"
  }
}

run "separate_cluster_moves_sandbox_host_to_its_own_cluster" {
  command = plan

  assert {
    condition     = length(module.sandbox_eks) == 1
    error_message = "separate_cluster did not plan the sandbox cluster"
  }
  assert {
    condition     = !contains(keys(module.eks.eks_managed_node_group_inputs), "sandbox_host")
    error_message = "separate_cluster still put the sandbox-host node group in the LangSmith cluster"
  }
  assert {
    condition = (
      module.sandbox_eks[0].managed_node_group_input.metadata_options.http_tokens == "required" &&
      module.sandbox_eks[0].managed_node_group_input.metadata_options.http_put_response_hop_limit == 1
    )
    error_message = "the sandbox cluster's node group lost IMDSv2 or its hop limit of 1"
  }
  assert {
    condition     = module.sandbox_eks[0].managed_node_group_input.labels["sandbox.langsmith.com/host"] == "true"
    error_message = "the sandbox cluster's node group lost the sandbox-host label"
  }
  assert {
    condition = (
      length(kubernetes_secret_v1.sandbox_runtime) == 1 &&
      length(kubernetes_secret_v1.sandbox_juicefs_config) == 1 &&
      length(kubernetes_secret_v1.sandbox_juicefs_csi_config) == 0
    )
    error_message = "separate_cluster should plan its Secrets in the sandbox cluster only"
  }
}

# data_wo is never readable, so the runtime Secret's contents are checked
# through the local that feeds it.
run "separate_cluster_runtime_secret_uses_the_dedicated_service_auth_secret" {
  command = plan

  assert {
    condition     = jsonencode(sort(keys(local.sandbox_runtime_secret_data))) == jsonencode(["sandbox_callback_signing_jwk", "sandbox_service_auth_secret"])
    error_message = "the runtime Secret must hold exactly the langsmith-sandbox chart's two default keys"
  }
  assert {
    condition     = nonsensitive(local.sandbox_runtime_secret_data.sandbox_service_auth_secret == "fixture-not-a-real-sandbox-service-auth-secret")
    error_message = "the runtime Secret's sandbox_service_auth_secret must be sandbox_service_auth_secret"
  }
  assert {
    condition     = nonsensitive(local.sandbox_runtime_secret_data.sandbox_service_auth_secret != var.langsmith_api_key_salt)
    error_message = "the runtime Secret must not carry the API key salt"
  }
  assert {
    condition     = nonsensitive(local.sandbox_runtime_secret_data.sandbox_callback_signing_jwk == "fixture-not-a-real-jwk")
    error_message = "the runtime Secret's sandbox_callback_signing_jwk must be sandbox_callback_signing_jwk"
  }
}

# Values that a mock provider leaves unknown at plan time are pinned here so
# the policies and rules below can be read.
run "separate_cluster_iam_and_network_are_scoped" {
  command = plan

  override_module {
    target = module.eks
    outputs = {
      cluster_name                       = "plantest-dev-eks"
      cluster_endpoint                   = "https://0123456789ABCDEF.gr7.us-east-2.eks.amazonaws.com"
      cluster_certificate_authority_data = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
      oidc_provider                      = "oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF"
      oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF"
      langsmith_irsa_role_arn            = "arn:aws:iam::123456789012:role/plantest-dev-eks-irsa-role"
      langsmith_irsa_role_name           = "plantest-dev-eks-irsa-role"
      node_security_group_id             = "sg-00000000000000001"
      karpenter_node_iam_role_name       = "plantest-dev-karpenter-node"
      eks_managed_node_group_inputs      = {}
    }
  }

  override_module {
    target = module.sandbox_eks
    outputs = {
      cluster_name                       = "plantest-dev-sandbox-eks"
      cluster_endpoint                   = "https://FEDCBA9876543210.gr7.us-east-2.eks.amazonaws.com"
      cluster_certificate_authority_data = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
      oidc_provider                      = "oidc.eks.us-east-2.amazonaws.com/id/FEDCBA9876543210"
      oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-2.amazonaws.com/id/FEDCBA9876543210"
      node_security_group_id             = "sg-00000000000000002"
      managed_node_group_input           = {}
    }
  }

  override_resource {
    target          = module.storage.aws_s3_bucket.bucket
    override_during = plan
    values = {
      arn = "arn:aws:s3:::plantest-dev-traces-0a1b2c3d"
    }
  }

  assert {
    condition = jsondecode(aws_iam_role.sandbox_host[0].assume_role_policy).Statement[0].Condition.StringEquals == {
      "oidc.eks.us-east-2.amazonaws.com/id/FEDCBA9876543210:aud" = "sts.amazonaws.com"
      "oidc.eks.us-east-2.amazonaws.com/id/FEDCBA9876543210:sub" = "system:serviceaccount:langsmith-sandbox:sandbox-host"
    }
    error_message = "the sandbox role must trust exactly the sandbox-host ServiceAccount in the sandbox cluster"
  }
  assert {
    condition = jsondecode(aws_iam_role_policy.sandbox_host_s3[0].policy).Statement == [
      {
        Sid    = "JuiceFSObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "arn:aws:s3:::plantest-dev-traces-0a1b2c3d/sandbox-juicefs/*"
      },
      {
        Sid      = "JuiceFSList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::plantest-dev-traces-0a1b2c3d"
        Condition = {
          StringLike = { "s3:prefix" = "sandbox-juicefs/*" }
        }
      },
    ]
    error_message = "the sandbox role's S3 access must be limited to the JuiceFS prefix"
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.sandbox_host_from_langsmith[0].security_group_id == "sg-00000000000000002" &&
      aws_vpc_security_group_ingress_rule.sandbox_host_from_langsmith[0].referenced_security_group_id == "sg-00000000000000001" &&
      aws_vpc_security_group_ingress_rule.sandbox_host_from_langsmith[0].from_port == 19190 &&
      aws_vpc_security_group_ingress_rule.sandbox_host_from_langsmith[0].to_port == 19190 &&
      aws_vpc_security_group_ingress_rule.sandbox_host_from_langsmith[0].cidr_ipv4 == null
    )
    error_message = "TCP 19190 on the sandbox nodes must be open to the LangSmith node security group only"
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.sandbox_host_from_sandbox_nodes[0].security_group_id == "sg-00000000000000002" &&
      aws_vpc_security_group_ingress_rule.sandbox_host_from_sandbox_nodes[0].referenced_security_group_id == "sg-00000000000000002" &&
      aws_vpc_security_group_ingress_rule.sandbox_host_from_sandbox_nodes[0].from_port == 19190 &&
      aws_vpc_security_group_ingress_rule.sandbox_host_from_sandbox_nodes[0].to_port == 19190
    )
    error_message = "TCP 19190 between sandbox nodes must be allowed by security group reference"
  }
  assert {
    condition     = length(local.alb_allowed_security_group_ids) == 0
    error_message = "an internet-facing ALB cannot match the sandbox security group, so none should be added"
  }
}

run "an_internal_alb_admits_the_sandbox_nodes" {
  command = plan

  variables {
    alb_scheme              = "internal"
    alb_allowed_cidr_blocks = ["10.10.0.0/16"]
  }

  override_module {
    target = module.sandbox_eks
    outputs = {
      cluster_name                       = "plantest-dev-sandbox-eks"
      cluster_endpoint                   = "https://FEDCBA9876543210.gr7.us-east-2.eks.amazonaws.com"
      cluster_certificate_authority_data = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
      oidc_provider                      = "oidc.eks.us-east-2.amazonaws.com/id/FEDCBA9876543210"
      oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-2.amazonaws.com/id/FEDCBA9876543210"
      node_security_group_id             = "sg-00000000000000002"
      managed_node_group_input           = {}
    }
  }

  assert {
    condition     = jsonencode(local.alb_allowed_security_group_ids) == jsonencode(["sg-00000000000000002"])
    error_message = "an internal ALB should admit the sandbox node security group"
  }
  assert {
    condition     = jsonencode(local.alb_ingress_cidr_blocks) == jsonencode(["10.10.0.0/16"])
    error_message = "the sandbox cluster widened the ALB CIDR allowlist"
  }
}

# ── Input checks ─────────────────────────────────────────────────────────────

run "a_prerelease_0_18_chart_is_accepted" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.18.0-rc.45"
  }

  assert {
    condition     = length(module.sandbox_eks) == 1
    error_message = "an exact 0.18 prerelease chart should be accepted for separate_cluster"
  }
}

run "the_default_chart_line_is_rejected" {
  command = plan

  variables {
    langsmith_helm_chart_version = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "a_0_17_chart_is_rejected" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.17.5"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "a_chart_range_is_rejected" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.18.0 - 0.18.9"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "a_missing_runtime_secret_value_is_rejected" {
  command = plan

  variables {
    sandbox_callback_signing_jwk = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "a_missing_service_auth_secret_is_rejected" {
  command = plan

  variables {
    sandbox_service_auth_secret = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "a_short_service_auth_secret_is_rejected" {
  command = plan

  variables {
    sandbox_service_auth_secret = "fixture-too-short"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "reusing_the_api_key_salt_as_the_service_auth_secret_is_rejected" {
  command = plan

  variables {
    langsmith_api_key_salt      = "fixture-not-a-real-salt-reused-for-sandboxes"
    sandbox_service_auth_secret = "fixture-not-a-real-salt-reused-for-sandboxes"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "a_narrowed_internet_facing_alb_is_rejected" {
  command = plan

  variables {
    alb_scheme              = "internet-facing"
    alb_allowed_cidr_blocks = ["203.0.113.0/24"]
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "a_customer_managed_bucket_key_is_granted_to_the_sandbox_role" {
  command = plan

  variables {
    s3_kms_key_arn = "arn:aws:kms:us-east-2:123456789012:key/00000000-0000-0000-0000-000000000000"
  }

  override_resource {
    target          = module.storage.aws_s3_bucket.bucket
    override_during = plan
    values = {
      arn = "arn:aws:s3:::plantest-dev-traces-0a1b2c3d"
    }
  }

  assert {
    condition = contains(jsondecode(aws_iam_role_policy.sandbox_host_s3[0].policy).Statement, {
      Sid      = "JuiceFSKms"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = "arn:aws:kms:us-east-2:123456789012:key/00000000-0000-0000-0000-000000000000"
    })
    error_message = "with s3_kms_key_arn set, the sandbox role must be able to use that key and no other"
  }
}
