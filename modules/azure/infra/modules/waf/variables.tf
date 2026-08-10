variable "name" {
  type        = string
  description = "Name of the WAF policy resource"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the WAF policy"
}

variable "location" {
  type        = string
  description = "Azure region for the WAF policy"
}

variable "waf_mode" {
  type        = string
  description = "WAF enforcement mode: Detection (log only) or Prevention (block). Detection by default because OWASP CRS matches SQL and script fragments that appear legitimately in LangSmith prompts and traces. Review the firewall log for false positives, add exclusions, then switch to Prevention."
  default     = "Detection"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "waf_mode must be Detection or Prevention."
  }
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags"
  default     = {}
}
