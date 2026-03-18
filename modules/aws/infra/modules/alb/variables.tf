variable "name" {
  type        = string
  description = "Name for the ALB and its security group"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the ALB will be created"
}

variable "subnets" {
  type        = list(string)
  description = "Subnet IDs for the ALB. Use public subnets for internet-facing, private subnets for internal."
}

variable "internal" {
  type        = bool
  description = "If true, provisions an internal ALB on private subnets. If false, provisions an internet-facing ALB on public subnets."
  default     = false
}

variable "tls_certificate_source" {
  type        = string
  description = "TLS mode: 'acm', 'letsencrypt', or 'none'"
  default     = "acm"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN. Required when tls_certificate_source = 'acm'."
  default     = ""
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block. Used to scope security group egress rules to within the VPC."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources"
  default     = {}
}

variable "access_logs_enabled" {
  type        = bool
  description = "Enable ALB access logging to S3. Creates a dedicated S3 bucket with the required ELB delivery policy."
  default     = false
}

variable "access_logs_prefix" {
  type        = string
  description = "S3 key prefix for ALB access log objects"
  default     = "alb"
}
