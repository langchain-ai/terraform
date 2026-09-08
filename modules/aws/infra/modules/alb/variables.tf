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

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the ALB on HTTP/HTTPS. Defaults to open (0.0.0.0/0). Restrict to VPN/office CIDRs for internal deployments."
  default     = ["0.0.0.0/0"]
}

# Security-group-scoped ingress, evaluated in addition to allowed_cidr_blocks.
# Preferred over widening allowed_cidr_blocks when the caller is a known workload
# in this VPC: the rule names the source security group, so it stays valid as
# node IPs churn and it grants nothing to unrelated traffic.
#
# Only effective for an internal ALB. Traffic from a private subnet to an
# internet-facing ALB leaves via the NAT gateway and arrives with the NAT
# Elastic IP as its source, so the source security group is no longer visible
# and these rules will not match.
variable "allowed_security_group_ids" {
  type        = list(string)
  description = "Security group IDs allowed to reach the ALB on HTTP/HTTPS, in addition to allowed_cidr_blocks. Only matches for an internal ALB."
  default     = []
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

variable "bucket_suffix" {
  type        = string
  description = "Random suffix appended to S3 bucket names to ensure global uniqueness"
  default     = ""
}

variable "enable_envoy_gateway" {
  type        = bool
  description = "When true, provisions a target group for the Envoy Gateway proxy and sets the ALB listener default action to forward to it. ALB becomes the external entry point; Envoy proxy NLB stays internal."
  default     = false
}

variable "enable_istio_gateway" {
  type        = bool
  description = "When true, provisions a target group for the Istio ingress gateway and sets the ALB listener default action to forward to it. ALB becomes the external entry point; Istio NLB stays internal."
  default     = false
}

variable "enable_nginx_ingress" {
  type        = bool
  description = "When true, provisions a target group for the NGINX ingress controller and sets the ALB listener default action to forward to it. ALB becomes the external entry point; NGINX routes internally via standard Ingress resources."
  default     = false
}
