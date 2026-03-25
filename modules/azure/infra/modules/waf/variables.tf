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
  description = "WAF enforcement mode: Detection (log only) or Prevention (block)"
  default     = "Prevention"

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
