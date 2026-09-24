locals {
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
      }
    ])
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
    juicefs-csi-iam-role = local.s3_statements["juicefs-csi-iam-role"]
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
    account_id    = local.account_id
    partition     = local.partition
    regions_json  = jsonencode(sort(tolist(var.regions)))
    node_role_arn = local.role_arns["karpenter-node-role"]
  }
  inline_policies = merge(
    { for key, statements in local.inline_statements : key => jsonencode({ Version = "2012-10-17", Statement = statements }) },
    { lbc-role = jsonencode(jsondecode(templatefile("${path.module}/policies/load_balancer_controller.json.tftpl", local.template_vars))) }
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
  name        = "byoc-smith-karpenter-controller-policy"
  path        = "/"
  description = "Customer-owned shared LangSmith Karpenter policy for a pre-created instance profile"
  policy      = jsonencode(jsondecode(templatefile("${path.module}/policies/karpenter.json.tftpl", local.template_vars)))
  tags        = local.tags

  lifecycle {
    precondition {
      condition     = length(jsonencode(jsondecode(templatefile("${path.module}/policies/karpenter.json.tftpl", local.template_vars)))) <= 6144
      error_message = "Karpenter policy exceeds IAM's 6,144-character managed-policy limit. Reduce configured regions."
    }
  }
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  role       = aws_iam_role.this["karpenter-controller-role"].name
  policy_arn = aws_iam_policy.karpenter.arn
}
