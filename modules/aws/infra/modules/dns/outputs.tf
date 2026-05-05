output "zone_id" {
  description = "Route 53 hosted zone ID"
  value       = local.zone_id
}

output "name_servers" {
  description = "Route 53 name servers (only populated when create_zone = true)"
  value       = var.create_zone ? aws_route53_zone.langsmith[0].name_servers : []
}

output "certificate_arn" {
  description = "ACM certificate ARN. When wait_for_validation = true, blocks until DNS validation completes. Empty string if create_certificate = false."
  value = (
    !var.create_certificate ? "" :
    var.wait_for_validation ? aws_acm_certificate_validation.langsmith[0].certificate_arn :
    aws_acm_certificate.langsmith[0].arn
  )
}
