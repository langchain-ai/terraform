output "alb_arn" {
  description = "ARN of the pre-provisioned ALB"
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "DNS hostname of the ALB (use as config.hostname in Helm values)"
  value       = aws_lb.this.dns_name
}

output "security_group_id" {
  description = "Security group ID attached to the ALB"
  value       = aws_security_group.alb.id
}

output "http_listener_arn" {
  description = "ARN of the HTTP:80 listener"
  value       = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  description = "ARN of the HTTPS:443 listener (null when tls_certificate_source != 'acm')"
  value       = var.tls_certificate_source == "acm" ? aws_lb_listener.https[0].arn : null
}

output "access_logs_bucket_name" {
  description = "Name of the S3 bucket receiving ALB access logs (null when access_logs_enabled = false)"
  value       = var.access_logs_enabled ? aws_s3_bucket.access_logs[0].id : null
}
