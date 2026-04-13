output "cert_manager_irsa_role_arn" {
  description = "ARN of the IRSA role for the cert-manager ServiceAccount"
  value       = aws_iam_role.cert_manager.arn
}

output "cert_manager_irsa_role_name" {
  description = "Name of the IRSA role for the cert-manager ServiceAccount"
  value       = aws_iam_role.cert_manager.name
}
