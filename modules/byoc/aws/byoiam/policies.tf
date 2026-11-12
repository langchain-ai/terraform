locals {
  bedrock_assume_role_statements = [
    {
      Sid      = "AssumeBedrockRoles"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = ["arn:${local.partition}:iam::*:role/*"]
      Condition = {
        StringEquals = { "iam:ResourceTag/LangSmithBedrock" = "true" }
        Null         = { "sts:ExternalId" = "false" }
      }
    },
    {
      Sid      = "TagBedrockRoleSessions"
      Effect   = "Allow"
      Action   = ["sts:TagSession"]
      Resource = ["arn:${local.partition}:iam::*:role/*"]
      Condition = {
        StringEquals = { "iam:ResourceTag/LangSmithBedrock" = "true" }
        "ForAllValues:StringEquals" = { "aws:TagKeys" = [
          "eks-cluster-arn", "eks-cluster-name", "kubernetes-namespace",
          "kubernetes-service-account", "kubernetes-pod-name", "kubernetes-pod-uid"
        ] }
      }
    }
  ]
  regional_condition = { StringEquals = { "aws:RequestedRegion" = sort(tolist(var.regions)) } }
  s3_condition       = { StringEquals = { "s3:ResourceAccount" = local.account_id } }
  rds_secret_arns = [for region in sort(tolist(var.regions)) :
    "arn:${local.partition}:secretsmanager:${region}:${local.account_id}:secret:rds!db-*"
  ]
  application_secret_arns = [for region in sort(tolist(var.regions)) :
    "arn:${local.partition}:secretsmanager:${region}:${local.account_id}:secret:langsmith/*"
  ]

  # Explicit bucket/object ARNs and account conditions work for writes too;
  # existing-object tag conditions cannot authorize a new object's PutObject.
  s3_permissions = {
    workload-iam-role = {
      buckets        = ["*-smith-blob"]
      bucket_actions = ["s3:ListBucket", "s3:GetBucketLocation"]
      object_actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      object_prefix  = ""
    }
    smithdb-iam-role = {
      buckets        = ["*-smithdb-blob"]
      bucket_actions = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
      object_actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
      object_prefix  = ""
    }
    clickhouse-backup-iam-role = {
      buckets        = ["*-smith-clickhouse-backups"]
      bucket_actions = ["s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
      object_actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
      object_prefix  = "clickhouse/"
    }
    juicefs-csi-iam-role = {
      buckets        = ["*-smith-sandbox-snapshots"]
      bucket_actions = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
      object_actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
      object_prefix  = ""
    }
  }
  migration_source_blob_statements = length(var.workload_migration_source_blob_bucket_arns) == 0 ? [] : concat([
    {
      Sid      = "ReadMigrationSourceBlobObjects"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = [for arn in var.workload_migration_source_blob_bucket_arns : "${arn}/*"]
    },
    {
      Sid      = "ListMigrationSourceBlobBuckets"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = var.workload_migration_source_blob_bucket_arns
    }
    ], length(var.workload_migration_source_blob_kms_key_arns) == 0 ? [] : [{
      Sid      = "DecryptMigrationSourceBlobObjects"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = var.workload_migration_source_blob_kms_key_arns
      Condition = {
        StringLike = {
          "kms:EncryptionContext:aws:s3:arn" = concat(
            var.workload_migration_source_blob_bucket_arns,
            [for arn in var.workload_migration_source_blob_bucket_arns : "${arn}/*"]
          )
        }
      }
  }])
  # The LangSmith app names dedicated deployment databases lg-<id> and tags them
  # langgraph-cloud. It can tag any lg-* instance, so the tag doesn't fence off
  # the data planes' own databases; the Deny on their managed_by tag does.
  dedicated_deployment_database_arns = [for region in sort(tolist(var.regions)) :
    "arn:${local.partition}:rds:${region}:${local.account_id}:db:lg-*"
  ]
  dedicated_deployment_statements = [for statement in [
    {
      Sid       = "CreateDedicatedDeploymentDatabases"
      Effect    = "Allow"
      Action    = ["rds:CreateDBInstance", "rds:AddTagsToResource"]
      Resource  = local.dedicated_deployment_database_arns
      Condition = { Null = { "aws:RequestTag/langgraph-cloud" = "false" } }
    },
    {
      Sid    = "CreateDedicatedDeploymentDatabasesInDataPlane"
      Effect = "Allow"
      Action = ["rds:CreateDBInstance"]
      Resource = flatten([for region in sort(tolist(var.regions)) : [
        "arn:${local.partition}:rds:${region}:${local.account_id}:subgrp:*-smith-postgres-subnet-group",
        "arn:${local.partition}:rds:${region}:${local.account_id}:pg:default.postgres*"
      ]])
      Condition = {
        StringEquals = { "rds:DatabaseEngine" = "postgres" }
        Bool         = { "rds:StorageEncrypted" = "true" }
      }
    },
    {
      Sid       = "ManageDedicatedDeploymentDatabases"
      Effect    = "Allow"
      Action    = ["rds:ModifyDBInstance", "rds:DeleteDBInstance"]
      Resource  = local.dedicated_deployment_database_arns
      Condition = { Null = { "aws:ResourceTag/langgraph-cloud" = "false" } }
    },
    {
      Sid      = "DescribeDedicatedDeploymentDatabases"
      Effect   = "Allow"
      Action   = ["rds:DescribeDBInstances"]
      Resource = local.dedicated_deployment_database_arns
    },
    {
      Sid       = "DescribeSecurityGroups"
      Effect    = "Allow"
      Action    = ["ec2:DescribeSecurityGroups"]
      Resource  = ["*"]
      Condition = local.regional_condition
    },
    {
      Sid       = "DenyLangSmithDatabaseChanges"
      Effect    = "Deny"
      Action    = ["rds:AddTagsToResource", "rds:ModifyDBInstance", "rds:DeleteDBInstance"]
      Resource  = [for region in sort(tolist(var.regions)) : "arn:${local.partition}:rds:${region}:${local.account_id}:db:*"]
      Condition = { StringEquals = { "aws:ResourceTag/managed_by" = "langsmith" } }
    }
  ] : statement if var.dedicated_deployments]
  s3_statements = { for key, permission in local.s3_permissions : key => [
    {
      Sid       = "BucketAccess"
      Effect    = "Allow"
      Action    = permission.bucket_actions
      Resource  = [for bucket in permission.buckets : "arn:${local.partition}:s3:::${bucket}"]
      Condition = local.s3_condition
    },
    {
      Sid       = "ObjectAccess"
      Effect    = "Allow"
      Action    = permission.object_actions
      Resource  = [for bucket in permission.buckets : "arn:${local.partition}:s3:::${bucket}/${permission.object_prefix}*"]
      Condition = local.s3_condition
    }
  ] }
  setup_statements = { for role, db_name_pattern in {
    postgres-setup-iam-role = "*-smith-postgres"
    smithdb-setup-iam-role  = "*-smithdb-metastore"
    } : role => [{
      Sid      = "ReadRDSMasterSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = local.rds_secret_arns
      Condition = { ArnLike = {
        "secretsmanager:ResourceTag/aws:rds:primaryDBInstanceArn" = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:rds:${region}:${local.account_id}:db:${db_name_pattern}"
        ]
      } }
    }]
  }

  cmk_via = { for service in ["s3", "secretsmanager"] : service => {
    "kms:ViaService" = [for region in sort(tolist(var.regions)) : "${service}.${region}.amazonaws.com"]
  } }
  cmk_bucket_context = { for key, permission in local.s3_permissions : key => flatten([
    for bucket in permission.buckets : ["arn:${local.partition}:s3:::${bucket}", "arn:${local.partition}:s3:::${bucket}/*"]
  ]) }
  cmk_s3_keys  = compact([lookup(var.cmk_service_key_arns, "s3", "")])
  cmk_rds_keys = compact([lookup(var.cmk_service_key_arns, "rds", "")])
  cmk_eks_keys = compact([lookup(var.cmk_service_key_arns, "eks", "")])
  cmk_rds_secret_statement = {
    Sid       = "DecryptRDSMasterSecrets"
    Effect    = "Allow"
    Action    = ["kms:Decrypt"]
    Resource  = local.cmk_rds_keys
    Condition = { StringEquals = local.cmk_via.secretsmanager, StringLike = { "kms:EncryptionContext:SecretARN" = local.rds_secret_arns } }
  }
  cmk_bucket_statements = { for key, context in local.cmk_bucket_context : key => [for statement in [{
    Sid       = "BucketKMS"
    Effect    = "Allow"
    Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
    Resource  = local.cmk_s3_keys
    Condition = { StringEquals = local.cmk_via.s3, StringLike = { "kms:EncryptionContext:aws:s3:arn" = context } }
  }] : statement if length(local.cmk_s3_keys) > 0] }
  cmk_statements = merge(local.cmk_bucket_statements, {
    workload-iam-role = concat(local.cmk_bucket_statements["workload-iam-role"], [for statement in [{
      Sid       = "ReadMigrationInventoryKMS"
      Effect    = "Allow"
      Action    = ["kms:Decrypt"]
      Resource  = local.cmk_s3_keys
      Condition = { StringEquals = local.cmk_via.s3, StringLike = { "kms:EncryptionContext:aws:s3:arn" = ["arn:${local.partition}:s3:::*-smithdb-blob", "arn:${local.partition}:s3:::*-smithdb-blob/byoc-migration/*"] } }
    }] : statement if length(local.cmk_s3_keys) > 0])
    smithdb-iam-role = concat(local.cmk_bucket_statements["smithdb-iam-role"], [for statement in [{
      Sid       = "ReadLangsmithBlobKMS"
      Effect    = "Allow"
      Action    = ["kms:Decrypt"]
      Resource  = local.cmk_s3_keys
      Condition = { StringEquals = local.cmk_via.s3, StringLike = { "kms:EncryptionContext:aws:s3:arn" = ["arn:${local.partition}:s3:::*-smith-blob", "arn:${local.partition}:s3:::*-smith-blob/*"] } }
    }] : statement if length(local.cmk_s3_keys) > 0])
    postgres-setup-iam-role = [for statement in [local.cmk_rds_secret_statement] : statement if length(local.cmk_rds_keys) > 0]
    smithdb-setup-iam-role  = [for statement in [local.cmk_rds_secret_statement] : statement if length(local.cmk_rds_keys) > 0]
    external-secrets-iam-role = [for statement in [merge(local.cmk_rds_secret_statement, {
      Sid       = "DecryptSecrets"
      Condition = { StringEquals = local.cmk_via.secretsmanager, StringLike = { "kms:EncryptionContext:SecretARN" = concat(local.application_secret_arns, local.rds_secret_arns) } }
    })] : statement if length(local.cmk_rds_keys) > 0]
    eks-cluster-role = [for statement in [{
      Sid      = "ClusterSecretsKMS"
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
      Resource = local.cmk_eks_keys
    }] : statement if length(local.cmk_eks_keys) > 0]
  })

  inline_statements = {
    workload-iam-role = concat(local.s3_statements["workload-iam-role"], [
      {
        Sid    = "RDSIAMAuthentication"
        Effect = "Allow"
        Action = ["rds-db:connect"]
        Resource = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:rds-db:${region}:${local.account_id}:dbuser:*/langsmith_admin"
        ]
      },
      {
        Sid    = "RedisIAMAuthentication"
        Effect = "Allow"
        Action = ["elasticache:Connect"]
        Resource = flatten([for region in sort(tolist(var.regions)) : [
          "arn:${local.partition}:elasticache:${region}:${local.account_id}:replicationgroup:*-smith-redis",
          "arn:${local.partition}:elasticache:${region}:${local.account_id}:user:*-smith-redis-user"
        ]])
      },
      {
        Sid      = "DescribeRedis"
        Effect   = "Allow"
        Action   = ["elasticache:DescribeReplicationGroups"]
        Resource = [for region in sort(tolist(var.regions)) : "arn:${local.partition}:elasticache:${region}:${local.account_id}:replicationgroup:*-smith-redis"]
      },
      {
        Sid       = "ReadCloudWatchMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:GetMetricData"]
        Resource  = ["*"]
        Condition = local.regional_condition
      },
      {
        Sid       = "ReadMigrationInventory"
        Effect    = "Allow"
        Action    = ["s3:GetObject"]
        Resource  = ["arn:${local.partition}:s3:::*-smithdb-blob/byoc-migration/*"]
        Condition = local.s3_condition
      },
      {
        Sid      = "ListMigrationInventory"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:${local.partition}:s3:::*-smithdb-blob"]
        Condition = merge(local.s3_condition, {
          StringLike = { "s3:prefix" = "byoc-migration/*" }
        })
      }
      ], [
      {
        Sid       = "ECRAuthentication"
        Effect    = "Allow"
        Action    = ["ecr:GetAuthorizationToken"]
        Resource  = ["*"]
        Condition = { StringEquals = { "aws:RequestedRegion" = sort(tolist(var.regions)) } }
      },
      {
        Sid    = "PullSandboxBlueprints"
        Effect = "Allow"
        Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:ecr:${region}:${local.artifact_account_id}:repository/byoc-smithbox-*"
        ]
      },
      {
        Sid      = "AssumeSandboxECRRoles"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = ["arn:${local.partition}:iam::*:role/*"]
        Condition = {
          StringEquals = { "iam:ResourceTag/LangSmithSandboxECR" = "true" }
          Null         = { "sts:ExternalId" = "false" }
        }
      },
      {
        Sid       = "TagSandboxECRRoleSessions"
        Effect    = "Allow"
        Action    = ["sts:TagSession"]
        Resource  = ["arn:${local.partition}:iam::*:role/*"]
        Condition = { StringEquals = { "iam:ResourceTag/LangSmithSandboxECR" = "true" } }
      }
      ], [{
        Sid    = "EngineBedrockInference"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:${local.partition}:bedrock:*::foundation-model/*",
          "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/*",
          "arn:${local.partition}:bedrock:*:${local.account_id}:application-inference-profile/*"
        ]
    }], local.bedrock_assume_role_statements, local.migration_source_blob_statements, local.dedicated_deployment_statements)
    postgres-setup-iam-role = local.setup_statements["postgres-setup-iam-role"]
    smithdb-setup-iam-role  = local.setup_statements["smithdb-setup-iam-role"]
    smithdb-iam-role = concat(local.s3_statements["smithdb-iam-role"], [
      {
        Sid       = "ReadLangsmithBlobObjects"
        Effect    = "Allow"
        Action    = ["s3:GetObject"]
        Resource  = ["arn:${local.partition}:s3:::*-smith-blob/*"]
        Condition = local.s3_condition
      },
      {
        Sid       = "ReadLangsmithBlobBucket"
        Effect    = "Allow"
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = ["arn:${local.partition}:s3:::*-smith-blob"]
        Condition = local.s3_condition
      },
      {
        Sid    = "SmithDBIAMAuthentication"
        Effect = "Allow"
        Action = ["rds-db:connect"]
        Resource = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:rds-db:${region}:${local.account_id}:dbuser:*/smithdb"
        ]
      }
    ])
    external-secrets-iam-role = [{
      Sid      = "ReadApplicationSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = local.application_secret_arns
      }, {
      Sid      = "ReadSmithDBMasterSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = local.rds_secret_arns
      # RDS supplies this protected association tag on its managed secret;
      # custom tags on the DB instance do not establish secret ownership.
      Condition = { ArnLike = {
        "secretsmanager:ResourceTag/aws:rds:primaryDBInstanceArn" = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:rds:${region}:${local.account_id}:db:*-smithdb-metastore"
        ]
      } }
    }]
    clickhouse-backup-iam-role = concat(local.s3_statements["clickhouse-backup-iam-role"], [{
      Sid      = "ListBackupPrefix"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = ["arn:${local.partition}:s3:::*-smith-clickhouse-backups"]
      Condition = merge(local.s3_condition, {
        StringLike = { "s3:prefix" = ["clickhouse", "clickhouse/*"] }
      })
    }])
    juicefs-csi-iam-role = concat(local.s3_statements["juicefs-csi-iam-role"], [{
      Sid    = "JuiceFSRedisIAMAuthentication"
      Effect = "Allow"
      Action = ["elasticache:Connect"]
      Resource = flatten([for region in sort(tolist(var.regions)) : [
        "arn:${local.partition}:elasticache:${region}:${local.account_id}:replicationgroup:*-smith-redis",
        "arn:${local.partition}:elasticache:${region}:${local.account_id}:user:*-smith-juicefs-redis-user"
      ]])
    }])
    playground-iam-role = local.bedrock_assume_role_statements
    privatelink-lambda-role = [
      {
        Sid    = "ManageEKSAPITargets"
        Effect = "Allow"
        Action = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
        Resource = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:elasticloadbalancing:${region}:${local.account_id}:targetgroup/*-smith-eks-api-tg/*"
        ]
      },
      {
        # DescribeTargetHealth does not support resource-level permissions.
        Sid       = "DescribeEKSAPITargetHealth"
        Effect    = "Allow"
        Action    = ["elasticloadbalancing:DescribeTargetHealth"]
        Resource  = ["*"]
        Condition = local.regional_condition
      },
      {
        Sid       = "DescribeENIs"
        Effect    = "Allow"
        Action    = ["ec2:DescribeNetworkInterfaces"]
        Resource  = ["*"]
        Condition = local.regional_condition
      },
      {
        Sid       = "ECRAuthentication"
        Effect    = "Allow"
        Action    = ["ecr:GetAuthorizationToken"]
        Resource  = ["*"]
        Condition = { StringEquals = { "aws:RequestedRegion" = sort(tolist(var.regions)) } }
      },
      {
        Sid    = "PullPrivateLinkImage"
        Effect = "Allow"
        Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:ecr:${region}:${local.artifact_account_id}:repository/byoc-privatelink-lambdas"
        ]
      }
    ]
  }
  template_vars = {
    account_id            = local.account_id
    partition             = local.partition
    regions_json          = jsonencode(sort(tolist(var.regions)))
    node_role_arn         = local.role_arns["karpenter-node-role"]
    instance_profile_name = var.karpenter_instance_profile_name
  }
  karpenter_policy_base = jsondecode(templatefile("${path.module}/policies/karpenter.json.tftpl", local.template_vars))
  ebs_kms_key_arns      = distinct(concat(var.ebs_kms_key_arns, compact([lookup(var.cmk_service_key_arns, "ebs", "")])))
  ebs_kms_condition = {
    StringEquals = { "kms:ViaService" = [for region in sort(tolist(var.regions)) : "ec2.${region}.amazonaws.com"] }
  }
  ebs_kms_statements = [for statement in [
    {
      Sid       = "AllowVolumeKMS"
      Effect    = "Allow"
      Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:DescribeKey", "kms:GenerateDataKeyWithoutPlaintext"]
      Resource  = local.ebs_kms_key_arns
      Condition = local.ebs_kms_condition
    },
    {
      Sid       = "AllowVolumeKMSGrants"
      Effect    = "Allow"
      Action    = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
      Resource  = local.ebs_kms_key_arns
      Condition = merge(local.ebs_kms_condition, { Bool = { "kms:GrantIsForAWSResource" = "true" } })
    }
  ] : statement if length(local.ebs_kms_key_arns) > 0]
  karpenter_policy = jsonencode(merge(local.karpenter_policy_base, {
    Statement = concat(local.karpenter_policy_base.Statement, local.ebs_kms_statements)
  }))
  inline_policies = merge(
    { for key in setunion(keys(local.inline_statements), keys(local.cmk_statements)) : key => jsonencode({
      Version   = "2012-10-17"
      Statement = concat(lookup(local.inline_statements, key, []), lookup(local.cmk_statements, key, []))
    }) if length(concat(lookup(local.inline_statements, key, []), lookup(local.cmk_statements, key, []))) > 0 },
    { lbc-role = jsonencode(jsondecode(templatefile("${path.module}/policies/load_balancer_controller.json.tftpl", local.template_vars))) },
    { for key, statements in { ebs-csi-role = local.ebs_kms_statements } : key => jsonencode({ Version = "2012-10-17", Statement = statements }) if length(statements) > 0 }
  )
}

resource "aws_iam_role_policy" "this" {
  for_each = local.inline_policies
  name     = "langsmith-byoc"
  role     = aws_iam_role.this[each.key].name
  policy   = each.value

  lifecycle {
    precondition {
      condition     = length(each.value) <= 10240
      error_message = "Inline role policy exceeds IAM's 10,240-character aggregate limit. Reduce configured resource patterns/regions or split the IAM installation."
    }
  }
}

resource "aws_iam_policy" "karpenter" {
  name        = var.karpenter_controller_policy_name
  path        = "/"
  description = "Customer-owned shared LangSmith Karpenter policy for a pre-created instance profile"
  policy      = local.karpenter_policy
  tags        = local.tags

  lifecycle {
    precondition {
      condition     = length(local.karpenter_policy) <= 6144
      error_message = "Karpenter policy exceeds IAM's 6,144-character managed-policy limit. Reduce configured regions or KMS keys."
    }
  }
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  role       = aws_iam_role.this["karpenter-controller-role"].name
  policy_arn = aws_iam_policy.karpenter.arn
}
