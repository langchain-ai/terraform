variable "name" {
  type        = string
  description = "Name for the WAF Web ACL"
}

variable "alb_arn" {
  type        = string
  description = "ARN of the ALB to associate with the Web ACL"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources"
  default     = {}
}
