# LangSmith Engine in the AWS root: the Engine IRSA role, its trust policy, its
# policies, its output, and the input checks. mock_provider means no cloud
# credentials, state, or API calls.

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

  # Engine requires Sandboxes, and Sandboxes require the JuiceFS Redis token.
  sandbox_juicefs_redis_auth_token = "fixture-not-a-real-token-0123456789"
}

# The trust policy embeds the cluster's OIDC provider, which a mock provider
# leaves unknown at plan time. Fixed module outputs make the policy known, so the
# runs below can read its JSON.
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
  }
}

run "engine_off_by_default" {
  command = plan

  variables {
    enable_sandboxes      = true
    enable_bedrock_access = true
  }

  assert {
    condition = (
      length(aws_iam_role.engine) == 0 &&
      length(aws_iam_role_policy_attachment.engine_bedrock_mantle) == 0 &&
      length(aws_iam_role_policy.engine_s3) == 0 &&
      length(aws_iam_role_policy.engine_bedrock_invoke) == 0 &&
      length(data.aws_partition.current) == 0
    )
    error_message = "Engine IAM must not be planned while enable_engine = false"
  }
  assert {
    condition     = output.engine_irsa_role_arn == null
    error_message = "engine_irsa_role_arn must be null while enable_engine = false"
  }
}

run "engine_role_trusts_only_the_two_engine_service_accounts" {
  command = plan

  variables {
    enable_sandboxes = true
    enable_engine    = true
  }

  assert {
    condition     = aws_iam_role.engine[0].name == "plantest-dev-engine-irsa"
    error_message = "The Engine role should be <name_prefix>-<environment>-engine-irsa"
  }
  assert {
    condition = (
      length(jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF"
    )
    error_message = "The Engine role should have one statement that allows AssumeRoleWithWebIdentity from the cluster's OIDC provider"
  }
  # StringEquals only: a StringLike condition, or a wildcard in a subject, would
  # let other service accounts in the namespace assume the role.
  assert {
    condition = (
      keys(jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Condition) == ["StringEquals"] &&
      toset(keys(jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Condition.StringEquals)) == toset([
        "oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF:aud",
        "oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF:sub",
      ])
    )
    error_message = "The Engine trust policy should have StringEquals conditions on aud and sub, and no other condition"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF:aud"] == "sts.amazonaws.com" &&
      jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF:sub"] == [
        "system:serviceaccount:langsmith:langsmith-standalone-insights-api-server",
        "system:serviceaccount:langsmith:langsmith-standalone-insights-queue",
      ]
    )
    error_message = "The Engine role should trust exactly langsmith-standalone-insights-api-server and -queue in the langsmith namespace, for audience sts.amazonaws.com"
  }
}

run "engine_role_gets_the_bedrock_mantle_managed_policy" {
  command = plan

  variables {
    enable_sandboxes = true
    enable_engine    = true
  }

  assert {
    condition = (
      aws_iam_role_policy_attachment.engine_bedrock_mantle[0].role == "plantest-dev-engine-irsa" &&
      aws_iam_role_policy_attachment.engine_bedrock_mantle[0].policy_arn == "arn:aws:iam::aws:policy/AmazonBedrockMantleInferenceAccess"
    )
    error_message = "The Engine role should get the AWS managed policy AmazonBedrockMantleInferenceAccess"
  }
  assert {
    condition     = length(aws_iam_role_policy.engine_bedrock_invoke) == 0
    error_message = "Without enable_bedrock_access, the Engine role should get no Bedrock InvokeModel policy"
  }
}

# The default policy ARN follows the partition, so GovCloud and China accounts
# get their own copy of the managed policy.
run "default_policy_arn_follows_the_partition" {
  command = plan

  variables {
    enable_sandboxes = true
    enable_engine    = true
  }

  override_data {
    target = data.aws_partition.current[0]
    values = {
      partition = "aws-us-gov"
    }
  }

  assert {
    condition     = aws_iam_role_policy_attachment.engine_bedrock_mantle[0].policy_arn == "arn:aws-us-gov:iam::aws:policy/AmazonBedrockMantleInferenceAccess"
    error_message = "The default Engine policy ARN should use the current partition"
  }
}

# Without "langsmith" in the release name, the chart's fullname is
# <release>-langsmith, and the service account names follow it.
run "custom_policy_release_and_namespace" {
  command = plan

  variables {
    enable_sandboxes          = true
    enable_engine             = true
    engine_bedrock_policy_arn = "arn:aws:iam::123456789012:policy/engine-bedrock-narrow"
    langsmith_release_name    = "acme"
    langsmith_namespace       = "ls"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.engine_bedrock_mantle[0].policy_arn == "arn:aws:iam::123456789012:policy/engine-bedrock-narrow"
    error_message = "engine_bedrock_policy_arn should replace the managed policy"
  }
  assert {
    condition = jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF:sub"] == [
      "system:serviceaccount:ls:acme-langsmith-standalone-insights-api-server",
      "system:serviceaccount:ls:acme-langsmith-standalone-insights-queue",
    ]
    error_message = "The trust subjects should follow the chart's fullname rule and the namespace"
  }
}

# The chart cuts a service account name to 63 characters, then removes one
# trailing "-". The trust subjects must follow, or IRSA rejects the pods.
run "long_release_name_follows_the_chart_truncation" {
  command = plan

  variables {
    enable_sandboxes       = true
    enable_engine          = true
    langsmith_release_name = "langsmith-production-eu-central-1-blue"
  }

  assert {
    condition = jsondecode(aws_iam_role.engine[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-2.amazonaws.com/id/0123456789ABCDEF:sub"] == [
      "system:serviceaccount:langsmith:langsmith-production-eu-central-1-blue-standalone-insights-api",
      "system:serviceaccount:langsmith:langsmith-production-eu-central-1-blue-standalone-insights-queu",
    ]
    error_message = "The trust subjects should match the chart's 63-character service account names"
  }
}

# Engine and Insights run on two service accounts that lose the shared role when
# Engine is on. The Engine role must keep the shared role's bucket access, which
# the chart's blob storage settings use with no static keys on AWS.
run "engine_role_keeps_the_shared_bucket_access" {
  command = plan

  variables {
    enable_sandboxes = true
    enable_engine    = true
  }

  # The policy embeds the bucket ARN, which a mock provider leaves unknown at
  # plan time.
  override_resource {
    target          = module.storage.aws_s3_bucket.bucket
    override_during = plan
    values = {
      arn = "arn:aws:s3:::plantest-dev-traces-0a1b2c3d"
    }
  }

  assert {
    condition = (
      aws_iam_role_policy.engine_s3[0].role == "plantest-dev-engine-irsa" &&
      aws_iam_role_policy.engine_s3[0].policy == aws_iam_role_policy.langsmith_s3[0].policy &&
      jsondecode(aws_iam_role_policy.engine_s3[0].policy).Statement[0].Resource == [
        "arn:aws:s3:::plantest-dev-traces-0a1b2c3d",
        "arn:aws:s3:::plantest-dev-traces-0a1b2c3d/*",
      ]
    )
    error_message = "The Engine role should get the same S3 policy as the shared role, on the LangSmith bucket"
  }
}

# The same two service accounts, for enable_bedrock_access.
run "bedrock_access_also_reaches_the_engine_role" {
  command = plan

  variables {
    enable_sandboxes      = true
    enable_engine         = true
    enable_bedrock_access = true
  }

  assert {
    condition = (
      aws_iam_role_policy.engine_bedrock_invoke[0].role == "plantest-dev-engine-irsa" &&
      aws_iam_role_policy.engine_bedrock_invoke[0].policy == aws_iam_role_policy.langsmith_bedrock[0].policy
    )
    error_message = "With enable_bedrock_access, the Engine role should get the same Bedrock policy as the shared role"
  }
}

run "engine_irsa_role_arn_output" {
  command = plan

  variables {
    enable_sandboxes = true
    enable_engine    = true
  }

  # A role ARN is computed, so a mock provider leaves it unknown at plan time.
  override_resource {
    target          = aws_iam_role.engine[0]
    override_during = plan
    values = {
      arn = "arn:aws:iam::123456789012:role/plantest-dev-engine-irsa"
    }
  }

  assert {
    condition     = output.engine_irsa_role_arn == "arn:aws:iam::123456789012:role/plantest-dev-engine-irsa"
    error_message = "engine_irsa_role_arn should be the Engine role's ARN"
  }
}

run "engine_requires_sandboxes" {
  command = plan

  variables {
    enable_sandboxes = false
    enable_engine    = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "engine_inputs_reject_malformed_values" {
  command = plan

  variables {
    engine_bedrock_policy_arn             = "AmazonBedrockMantleInferenceAccess"
    engine_sandbox_tenant_id              = "Workspace 2"
    engine_intelligence_base_url          = "http://beacon.example.com/intelligence"
    langsmith_engine_usage_signing_secret = "too-short"
  }

  expect_failures = [
    var.engine_bedrock_policy_arn,
    var.engine_sandbox_tenant_id,
    var.engine_intelligence_base_url,
    var.langsmith_engine_usage_signing_secret,
  ]
}
