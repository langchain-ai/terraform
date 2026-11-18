# Plan tests with a mocked provider: no credentials and no state. Run with
# terraform init -backend=false && terraform test in the module directory.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_iam_role" {
    override_during = plan
    defaults = {
      arn = "arn:aws:iam::123456789012:role/byoc-smith-workload-iam-role"
    }
  }
}

variables {
  regions = ["us-east-1", "us-west-2"]
}

run "default" {
  command = plan

  assert {
    condition = alltrue([
      !contains(keys(aws_iam_role.this), "deployment-build-iam-role"),
      !contains(keys(aws_iam_role_policy.this), "deployment-build-iam-role"),
      length(aws_iam_role.cli_push) == 0,
      length(aws_iam_role_policy.cli_push) == 0,
      !strcontains(aws_iam_role_policy.this["workload-iam-role"].policy, "lsd/"),
      !strcontains(aws_iam_role_policy.this["workload-iam-role"].policy, "smith-deployment-sources"),
    ])
    error_message = "Without deployment_builds, there is no build role, push role, or lsd/ or source bucket grant."
  }
}

run "deployment_builds" {
  command = plan

  variables {
    deployment_builds    = true
    cmk_service_key_arns = { s3 = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }

  assert {
    condition     = aws_iam_role.this["deployment-build-iam-role"].name == "byoc-build-smith-workload-iam-role" && aws_iam_role.this["deployment-build-iam-role"].tags["langsmith-byoc-role"] == "true"
    error_message = "The build role keeps the name LangSmith observes and the tag the base image mirror admits."
  }

  assert {
    condition = jsondecode(aws_iam_role.this["deployment-build-iam-role"].assume_role_policy).Statement == [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:RequestTag/kubernetes-namespace" = "langsmith" }
        StringLike = {
          "aws:RequestTag/eks-cluster-arn"            = ["arn:aws:eks:us-east-1:123456789012:cluster/*-smith-eks", "arn:aws:eks:us-west-2:123456789012:cluster/*-smith-eks"]
          "aws:RequestTag/kubernetes-service-account" = ["lsd-build"]
        }
      }
    }]
    error_message = "Only EKS Pod Identity for langsmith/lsd-build may assume the build role."
  }

  assert {
    condition = { for statement in jsondecode(aws_iam_role_policy.this["deployment-build-iam-role"].policy).Statement : statement.Sid => statement.Resource if statement.Sid != "ECRAuthentication" } == {
      PushDeploymentBuilds = ["arn:aws:ecr:us-east-1:123456789012:repository/*-smith-deployment-builds", "arn:aws:ecr:us-west-2:123456789012:repository/*-smith-deployment-builds"]
      PullLangGraphBaseImages = [
        "arn:aws:ecr:us-east-1:808407022534:repository/byoc-langchain/langgraph-api*",
        "arn:aws:ecr:us-east-1:808407022534:repository/byoc-langchain/langgraphjs-api*",
        "arn:aws:ecr:us-west-2:808407022534:repository/byoc-langchain/langgraph-api*",
        "arn:aws:ecr:us-west-2:808407022534:repository/byoc-langchain/langgraphjs-api*"
      ]
    }
    error_message = "The build role may push to the build repositories and pull the LangGraph base images, in each region only."
  }

  assert {
    condition     = !contains(keys(output.role_names), "deployment-build-iam-role")
    error_message = "role_names lists only the names LangSmith takes at data plane creation."
  }

  assert {
    condition = jsondecode(aws_iam_role.cli_push[0].assume_role_policy).Statement == [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.this["workload-iam-role"].arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:PrincipalTag/kubernetes-namespace" = "langsmith" }
        StringLike   = { "aws:PrincipalTag/kubernetes-service-account" = "*-langsmith-host-backend" }
      }
    }]
    error_message = "Only host-backend, through the workload role, may assume the push role."
  }

  assert {
    condition = { for statement in jsondecode(aws_iam_role_policy.cli_push[0].policy).Statement : statement.Sid => statement.Resource } == {
      ECRAuthentication = ["*"]
      PushCLIImages     = ["arn:aws:ecr:us-east-1:123456789012:repository/lsd/*/local", "arn:aws:ecr:us-west-2:123456789012:repository/lsd/*/local"]
    }
    error_message = "The push role may push to lsd/*/local repositories in each region only."
  }

  assert {
    condition = { for statement in jsondecode(aws_iam_role_policy.this["workload-iam-role"].policy).Statement : statement.Sid => [statement.Action, statement.Resource] if contains(["ManageCLIBuildRepositories", "AssumeCLIPushRole", "ReadWriteCLISources", "CLISourcesKMS"], statement.Sid) } == {
      ManageCLIBuildRepositories = [
        ["ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DescribeRepositories", "ecr:PutLifecyclePolicy", "ecr:TagResource", "ecr:ListTagsForResource", "ecr:BatchDeleteImage"],
        ["arn:aws:ecr:us-east-1:123456789012:repository/lsd/*", "arn:aws:ecr:us-west-2:123456789012:repository/lsd/*"]
      ]
      AssumeCLIPushRole   = [["sts:AssumeRole", "sts:TagSession"], ["arn:aws:iam::123456789012:role/byoc-push-smith-workload-iam-role"]]
      ReadWriteCLISources = [["s3:PutObject", "s3:GetObject"], ["arn:aws:s3:::*-smith-deployment-sources/*"]]
      CLISourcesKMS       = [["kms:GenerateDataKey", "kms:Decrypt"], ["arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"]]
    }
    error_message = "The workload role may manage lsd/* repositories, assume the push role, and read and write source objects with their key."
  }
}
