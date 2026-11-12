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
}

variables {
  regions = ["us-east-1", "us-west-2"]
}

run "default" {
  command = plan

  assert {
    condition     = length([for statement in jsondecode(aws_iam_role_policy.this["workload-iam-role"].policy).Statement : statement if strcontains(jsonencode(statement.Action), "rds:")]) == 0
    error_message = "Without dedicated_deployments, the workload role gets no RDS management actions."
  }
}

run "dedicated_deployments" {
  command = plan

  variables {
    dedicated_deployments = true
  }

  assert {
    condition = { for statement in jsondecode(aws_iam_role_policy.this["workload-iam-role"].policy).Statement : statement.Sid => statement.Resource if startswith(statement.Sid, "ManageDedicated") } == {
      ManageDedicatedDeploymentDatabases = ["arn:aws:rds:us-east-1:123456789012:db:lg-*", "arn:aws:rds:us-west-2:123456789012:db:lg-*"]
    }
    error_message = "The workload role may modify and delete lg- instances in each region only."
  }

  assert {
    condition     = contains([for statement in jsondecode(aws_iam_role_policy.this["workload-iam-role"].policy).Statement : statement.Condition if statement.Sid == "CreateDedicatedDeploymentDatabasesInDataPlane"], { StringEquals = { "rds:DatabaseEngine" = "postgres" }, Bool = { "rds:StorageEncrypted" = "true" } })
    error_message = "The workload role may create only encrypted Postgres instances."
  }

  assert {
    condition     = contains([for statement in jsondecode(aws_iam_role_policy.this["workload-iam-role"].policy).Statement : [statement.Effect, statement.Action, statement.Condition] if statement.Sid == "DenyLangSmithDatabaseChanges"], ["Deny", ["rds:AddTagsToResource", "rds:ModifyDBInstance", "rds:DeleteDBInstance"], { StringEquals = { "aws:ResourceTag/managed_by" = "langsmith" } }])
    error_message = "The workload role may not tag, modify or delete the data planes' own databases."
  }
}
