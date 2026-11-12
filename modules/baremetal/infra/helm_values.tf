#------------------------------------------------------------------------------
# Helm values computed by Terraform in modules/values (same idea as
# smithdb_helm_values in modules/gcp/infra/locals.tf). The budget and the values
# read the same tables, so they can't drift. Nothing here is secret: only Secret
# *names* and keys. helm/scripts/init-values.sh writes these outputs to
# helm/values/, and deploy.sh layers them in the order of values_files.
#------------------------------------------------------------------------------

variable "langsmith_domain" {
  type        = string
  default     = ""
  description = "Hostname for LangSmith (e.g. langsmith.lab.example.com). Empty uses the Envoy Gateway IP, as modules/gcp does without a domain."
}

variable "langsmith_admin_email" {
  type        = string
  default     = ""
  description = "Initial LangSmith organization admin email, written to initialOrgAdminEmail in Helm values, as on the cloud modules (#429). Configuration, not a secret; empty falls back to INITIAL_ORG_ADMIN_EMAIL in infra/.secrets.env."
}

variable "langsmith_url_scheme" {
  type        = string
  default     = "http"
  description = "Scheme of the URL users reach LangSmith on. https when TLS terminates at the gateway (gateway_tls_secret) or in front of it (e.g. a Cloudflare Tunnel)."

  validation {
    condition     = contains(["http", "https"], var.langsmith_url_scheme)
    error_message = "langsmith_url_scheme must be http or https."
  }

  validation {
    condition     = var.langsmith_url_scheme == "http" || var.langsmith_domain != ""
    error_message = "langsmith_url_scheme = \"https\" needs langsmith_domain: no certificate covers the bare gateway IP."
  }
}

output "langsmith_helm_values" {
  description = "Environment overrides for the LangSmith chart (hostname, gateway). init-values.sh writes it as YAML. No secrets."
  value       = module.values.langsmith_values
}

output "smithdb_helm_values" {
  description = "SmithDB values for the sizing profile (resources, cache, rollout, object store, metastore keys). init-values.sh writes it as YAML. No secrets."
  value       = module.values.smithdb_values
}

output "langsmith_url" {
  description = "URL to open LangSmith."
  value       = module.values.langsmith_url
}

output "values_files" {
  description = "The values files deploy.sh hands Helm, in order (last wins), by name under helm/values/; the optional langsmith-values-local.yaml goes after them. A tool layering the same files reads this list."
  value       = module.values.values_files
}
