locals {
  # Static names preserve the AWS role suffixes used by the compositions and
  # customer provisioning-role allowlists.
  roles = {
    eks-cluster-role                  = { name = "byoc-smith-eks-cluster-role", service = "eks.amazonaws.com" }
    eks-node-role                     = { name = "byoc-smith-eks-node-role", service = "ec2.amazonaws.com" }
    ebs-csi-role                      = { name = "byoc-smith-ebs-csi-role", service = "pods.eks.amazonaws.com" }
    karpenter-node-role               = { name = "byoc-smith-karpenter-node-role", service = "ec2.amazonaws.com" }
    karpenter-controller-role         = { name = "byoc-smith-karpenter-controller-role", service = "pods.eks.amazonaws.com" }
    postgres-monitoring-role          = { name = "byoc-smith-postgres-monitoring-role", service = "monitoring.rds.amazonaws.com" }
    smithdb-metastore-monitoring-role = { name = "byoc-smithdb-metastore-monitoring-role", service = "monitoring.rds.amazonaws.com" }
    workload-iam-role                 = { name = "byoc-smith-workload-iam-role", service = "pods.eks.amazonaws.com" }
    postgres-setup-iam-role           = { name = "byoc-postgres-setup-smith-workload-iam-role", service = "pods.eks.amazonaws.com" }
    smithdb-iam-role                  = { name = "byoc-smith-smithdb-iam-role", service = "pods.eks.amazonaws.com" }
    smithdb-setup-iam-role            = { name = "byoc-smith-smithdb-setup-iam-role", service = "pods.eks.amazonaws.com" }
    external-secrets-iam-role         = { name = "byoc-smith-external-secrets-iam-role", service = "pods.eks.amazonaws.com" }
    lbc-role                          = { name = "byoc-smith-lbc-role", service = "pods.eks.amazonaws.com" }
    clickhouse-backup-iam-role        = { name = "byoc-smith-ch-backup-role", service = "pods.eks.amazonaws.com" }
    privatelink-lambda-role           = { name = "byoc-smith-privatelink-lambda-role", service = "lambda.amazonaws.com" }
    juicefs-csi-iam-role              = { name = "byoc-smith-juicefs-csi-iam-role", service = "pods.eks.amazonaws.com" }
  }
  role_arns = { for key, role in local.roles : key => "arn:${local.partition}:iam::${local.account_id}:role/${role.name}" }

  pod_identities = {
    ebs-csi-role              = { namespace = "kube-system", service_accounts = ["ebs-csi-controller-sa"] }
    karpenter-controller-role = { namespace = "kube-system", service_accounts = ["karpenter"] }
    lbc-role                  = { namespace = "kube-system", service_accounts = ["aws-load-balancer-controller"] }
    external-secrets-iam-role = { namespace = "external-secrets", service_accounts = ["external-secrets"] }
    workload-iam-role = {
      namespace = "langsmith"
      service_accounts = concat(
        [for component in ["backend", "host-backend", "listener", "platform-backend", "ingest-queue", "queue", "agent-gateway"] : "*-langsmith-${component}"],
        ["*-fleet-tool-server", "*-fleet-trigger-server"]
      )
    }
    postgres-setup-iam-role    = { namespace = "langsmith", service_accounts = ["*-langsmith-postgres-setup"] }
    smithdb-iam-role           = { namespace = "langsmith", service_accounts = ["*-langsmith-smithdb"] }
    smithdb-setup-iam-role     = { namespace = "langsmith", service_accounts = ["*-langsmith-smithdb-setup"] }
    clickhouse-backup-iam-role = { namespace = "langsmith", service_accounts = ["langsmith-clickhouse"] }
    juicefs-csi-iam-role       = { namespace = "sandbox", service_accounts = ["sandbox-host"] }
  }

  node_policy_names = ["AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy", "AmazonEC2ContainerRegistryReadOnly", "AmazonSSMManagedInstanceCore"]
  managed_policy_names = {
    eks-cluster-role                  = ["AmazonEKSClusterPolicy"]
    eks-node-role                     = local.node_policy_names
    karpenter-node-role               = local.node_policy_names
    ebs-csi-role                      = ["service-role/AmazonEBSCSIDriverPolicy"]
    postgres-monitoring-role          = ["service-role/AmazonRDSEnhancedMonitoringRole"]
    smithdb-metastore-monitoring-role = ["service-role/AmazonRDSEnhancedMonitoringRole"]
    privatelink-lambda-role           = ["service-role/AWSLambdaBasicExecutionRole"]
  }
  managed_policy_attachments = merge({}, [for key, names in local.managed_policy_names : {
    for name in names : "${key}/${name}" => { role = key, policy = name }
  }]...)
}

resource "aws_iam_role" "this" {
  for_each             = local.roles
  name                 = each.value.name
  path                 = "/"
  description          = "Customer-owned shared LangSmith BYOC ${each.key}"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [merge({
      Effect    = "Allow"
      Principal = { Service = each.value.service }
      Action    = each.value.service == "pods.eks.amazonaws.com" ? ["sts:AssumeRole", "sts:TagSession"] : ["sts:AssumeRole"]
      }, each.value.service == "pods.eks.amazonaws.com" ? {
      Condition = {
        StringEquals = {
          "aws:RequestTag/kubernetes-namespace" = local.pod_identities[each.key].namespace
        }
        StringLike = {
          "aws:RequestTag/eks-cluster-arn"            = local.cluster_arns
          "aws:RequestTag/kubernetes-service-account" = local.pod_identities[each.key].service_accounts
        }
      }
      } : {}, each.value.service == "monitoring.rds.amazonaws.com" ? {
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = { "aws:SourceArn" = [for region in sort(tolist(var.regions)) :
          "arn:${local.partition}:rds:${region}:${local.account_id}:db:*-smith${each.key == "postgres-monitoring-role" ? "-postgres" : "db-metastore"}"
        ] }
      }
    } : {})]
  })
  # langsmith-byoc-role participates in EKS access-entry authorization. local.tags
  # enforces customer ownership to keep IAM outside the provisioner's write scope.
  tags = merge(local.tags, contains(["eks-node-role", "karpenter-node-role", "workload-iam-role", "privatelink-lambda-role"], each.key) ? { "langsmith-byoc-role" = "true" } : {})
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = local.managed_policy_attachments
  role       = aws_iam_role.this[each.value.role].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value.policy}"
}
