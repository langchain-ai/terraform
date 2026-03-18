output "zone_id" {
  description = "Route 53 hosted zone ID"
  value       = local.zone_id
}

output "name_servers" {
  description = "Route 53 name servers (only populated when create_zone = true)"
  value       = var.create_zone ? aws_route53_zone.langsmith[0].name_servers : []
}

output "certificate_arn" {
  description = "ARN of the ACM certificate (empty string if create_certificate = false)"
  value       = var.create_certificate ? aws_acm_certificate.langsmith[0].arn : ""
}
