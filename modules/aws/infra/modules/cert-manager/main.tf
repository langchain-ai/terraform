# cert-manager IRSA module
#
# Creates the IAM resources needed for cert-manager to perform DNS-01 ACME
# challenges against Route 53 without long-lived credentials.
#
# What this does NOT do (handled by setup-tls.sh after terraform apply):
#   - Install the cert-manager Helm chart
#   - Annotate the cert-manager ServiceAccount with this role ARN
#   - Create the ClusterIssuer or Certificate resources
#
# IRSA docs: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
# cert-manager Route53 docs: https://cert-manager.io/docs/configuration/acme/dns01/route53/

# ── IAM Policy ────────────────────────────────────────────────────────────────
# Minimal permissions for DNS-01 challenge:
#   - route53:GetChange         — poll propagation status
#   - route53:ChangeResourceRecordSets, ListResourceRecordSets — write TXT records
#   - route53:ListHostedZonesByName — cert-manager zone lookup by domain name

resource "aws_iam_policy" "cert_manager_route53" {
  name        = "${var.cluster_name}-cert-manager-route53"
  description = "Allows cert-manager to manage Route53 TXT records for DNS-01 ACME challenges"
  tags        = var.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetChange"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Sid    = "ChangeRecords"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.hosted_zone_id}"
      },
      {
        Sid      = "ListZones"
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        # Route 53 does not support resource-level permissions for
        # ListHostedZonesByName — must be * per AWS and cert-manager docs.
        Resource = "*"
      },
    ]
  })
}

# ── IRSA Role ─────────────────────────────────────────────────────────────────
# Trusted by the cert-manager ServiceAccount in the cert-manager namespace.
# The SA annotation (eks.amazonaws.com/role-arn) is applied by setup-tls.sh
# after cert-manager is installed, so the Helm chart doesn't need to be
# re-templated just to add an annotation.

resource "aws_iam_role" "cert_manager" {
  name                  = "${var.cluster_name}-cert-manager"
  force_detach_policies = true
  tags                  = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:cert-manager:cert-manager"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cert_manager_route53" {
  role       = aws_iam_role.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager_route53.arn
}
