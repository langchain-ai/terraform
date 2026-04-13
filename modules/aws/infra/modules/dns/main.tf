# AWS DNS module (optional — not wired into main.tf by default)
#
# Provisions a Route 53 hosted zone and DNS-validated ACM certificate.
#
# Most customers already manage DNS zones outside of this stack (shared zones,
# separate teams, or existing domain registrars). The default deployment path
# expects a pre-existing ACM certificate ARN passed via `acm_certificate_arn`
# in terraform.tfvars — this module is NOT required for that flow.
#
# Important caveat — registrar delegation:
#   Creating a Route 53 zone does NOT make it authoritative. The domain's NS
#   records must be updated at the registrar to point to the Route 53 name
#   servers — a manual step that Terraform cannot automate (unless the registrar
#   is also Route 53, which is uncommon in enterprise). Without this delegation:
#     - ACM DNS validation hangs indefinitely (cert never issues)
#     - `terraform apply` blocks or times out on aws_acm_certificate_validation
#   This makes the module inherently two-pass: apply once to get name servers,
#   delegate at the registrar, then apply again for cert validation to complete.
#
# When to use this module:
#   - The customer wants Terraform to own the full DNS lifecycle (zone + cert)
#   - There is no pre-existing Route 53 zone or ACM certificate
#   - The deployment is greenfield with no shared DNS infrastructure
#   - The registrar delegation step is understood and acceptable
#
# To wire in, add a module block in main.tf:
#
#   module "dns" {
#     source      = "./modules/dns"
#     domain_name = var.langsmith_domain
#     create_zone = true           # false to use existing_zone_id instead
#   }
#
# Then feed the certificate ARN into the ALB module:
#
#   acm_certificate_arn = module.dns.certificate_arn
#
# instead of:
#
#   acm_certificate_arn = var.acm_certificate_arn

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
  subject_alternative_names = []
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
