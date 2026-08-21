# AWS DNS module
#
# Requests a DNS-validated ACM certificate and manages its validation records.
# It supports two hosted-zone modes:
#   - create_zone = true creates a public hosted zone exactly matching
#     domain_name. Its NS records must be delegated from the parent zone before
#     the new zone becomes authoritative.
#   - create_zone = false writes records into existing_zone_id. That public
#     hosted zone may exactly match domain_name or be one of its parent zones.
#     An already-authoritative existing zone needs no new NS delegation.
#
# Reusing a zone does not import or otherwise manage the zone itself. The root
# module separately creates the ALB alias record in the same selected zone.
# Public ACM certificates require publicly resolvable validation records, so a
# private hosted zone is not suitable for existing_zone_id.

resource "aws_route53_zone" "langsmith" {
  count = var.create_zone ? 1 : 0
  name  = var.domain_name
}

locals {
  zone_id = var.create_zone ? aws_route53_zone.langsmith[0].zone_id : var.existing_zone_id
}

resource "aws_acm_certificate" "langsmith" {
  count                     = var.create_certificate ? 1 : 0
  domain_name               = var.domain_name
  subject_alternative_names = var.include_wildcard_san ? ["*.${var.domain_name}"] : []
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.create_certificate ? {
    for dvo in aws_acm_certificate.langsmith[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = local.zone_id
}

resource "aws_acm_certificate_validation" "langsmith" {
  count                   = var.create_certificate && var.wait_for_validation ? 1 : 0
  certificate_arn         = aws_acm_certificate.langsmith[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
