variable "name" {
  description = "Front Door profile name (e.g. 'langsmith-fd-prod')"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy the Front Door profile into"
  type        = string
}

variable "sku_name" {
  description = <<-EOT
    Front Door SKU.
    - Standard_AzureFrontDoor: CDN + managed TLS + routing (no WAF). ~$35/mo base.
    - Premium_AzureFrontDoor:  Standard + WAF attachment + private link origins. ~$330/mo base.
    Use Standard unless you need WAF (pass waf_policy_id) or private link.
  EOT
  type        = string
  default     = "Standard_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.sku_name)
    error_message = "sku_name must be 'Standard_AzureFrontDoor' or 'Premium_AzureFrontDoor'."
  }
}

variable "origin_hostname" {
  description = <<-EOT
    Hostname or IP of the AKS ingress controller LoadBalancer.
    For NGINX: the external IP from 'kubectl get svc ingress-nginx-controller -n ingress-nginx'
    For Istio: the external IP from 'kubectl get svc istio-ingressgateway -n istio-system'
    Leave empty on first apply — set after the ingress LB is provisioned.
  EOT
  type        = string
  default     = ""
}

variable "custom_domain" {
  description = <<-EOT
    Customer domain name for LangSmith (e.g. 'langsmith.example.com').
    Front Door issues a managed TLS certificate for this domain.
    After apply: add a CNAME record at your registrar pointing to fd_endpoint_hostname output.
    Leave empty to use only the default Front Door endpoint hostname.
  EOT
  type        = string
  default     = ""
}

variable "waf_policy_id" {
  description = <<-EOT
    Resource ID of an existing WAF policy to attach to Front Door.
    Requires sku_name = 'Premium_AzureFrontDoor'.
    Pass module.waf[0].waf_policy_id from the waf module, or leave empty to skip.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all Front Door resources"
  type        = map(string)
  default     = {}
}
