# LangSmith Engine (enable_engine). Engine runs on the deployment it shares with
# Insights (engineInsightsAgent). init-values.sh writes Engine's Helm values, and
# apply-eso.sh syncs its two keys from SSM into the langsmith-config Secret. See
# ENGINE.md.
#
# Engine calls Amazon Bedrock through the Bedrock Mantle API under a dedicated
# IRSA role. The role is dedicated rather than the shared LangSmith role: only
# Engine's API server and queue need Bedrock Mantle, and the shared role trusts
# every service account in the namespace.
#
# Insights runs on the same two service accounts, so with Engine on, init-values.sh
# annotates them with this role instead of the shared one. The role therefore also
# gets the shared role's access that these pods use: the LangSmith bucket (blob
# storage, no static keys on AWS), and Bedrock InvokeModel when
# enable_bedrock_access = true.

data "aws_partition" "current" {
  count = var.enable_engine ? 1 : 0
}

locals {
  # The chart's fullname is the release name when it contains "langsmith", and
  # "<release>-langsmith" otherwise (the same rule as modules/smithdb). Engine's
  # service accounts are <fullname>-<engineInsightsAgent.namePrefix>-<component>,
  # and langsmith-values-engine.yaml keeps namePrefix = "standalone-insights".
  # The chart cuts each of these names to 63 characters and then removes one
  # trailing "-". A long release name reaches that limit, so do the same here.
  engine_release_fullname = trimsuffix(substr(strcontains(var.langsmith_release_name, "langsmith") ? var.langsmith_release_name : "${var.langsmith_release_name}-langsmith", 0, 63), "-")
  engine_agent_fullname   = trimsuffix(substr("${local.engine_release_fullname}-standalone-insights", 0, 63), "-")
  engine_service_accounts = [
    for component in ["api-server", "queue"] : trimsuffix(substr("${local.engine_agent_fullname}-${component}", 0, 63), "-")
  ]

  engine_bedrock_policy_arn = var.enable_engine ? (
    var.engine_bedrock_policy_arn != "" ? var.engine_bedrock_policy_arn :
    "arn:${data.aws_partition.current[0].partition}:iam::aws:policy/AmazonBedrockMantleInferenceAccess"
  ) : null
}

resource "aws_iam_role" "engine" {
  count = var.enable_engine ? 1 : 0

  name = "${local.base_name}-engine-irsa"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = [for sa in local.engine_service_accounts : "system:serviceaccount:${var.langsmith_namespace}:${sa}"]
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "engine_bedrock_mantle" {
  count = var.enable_engine ? 1 : 0

  role       = aws_iam_role.engine[0].name
  policy_arn = local.engine_bedrock_policy_arn
}

resource "aws_iam_role_policy" "engine_s3" {
  count = var.enable_engine ? 1 : 0

  name   = "langsmith-s3-access"
  role   = aws_iam_role.engine[0].name
  policy = local.langsmith_s3_policy
}

resource "aws_iam_role_policy" "engine_bedrock_invoke" {
  count = var.enable_engine && var.enable_bedrock_access ? 1 : 0

  name   = "langsmith-bedrock-access"
  role   = aws_iam_role.engine[0].name
  policy = local.langsmith_bedrock_policy
}
