output "ingress_namespace" {
  description = "Kubernetes namespace where the NGINX ingress controller is deployed"
  value       = "ingress-nginx"
}

output "note" {
  description = "How to retrieve the internal ingress IP after apply"
  value       = "Run: kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' — the IP is private and only reachable from within the hub-spoke network (e.g. from the jumpbox)."
}
