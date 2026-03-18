# dns: Provisions a Route 53 hosted zone and ACM certificate for LangSmith.
# Route 53: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html
# ACM:      https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html
# DNS validation: https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html

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
  subject_alternative_names = ["*.${var.domain_name}"]
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

