variable "name" {
  description = "Name prefix for the VPC and its resources."
  type        = string
  default     = "dataplane"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$", var.name))
    error_message = "name must be 2-32 lowercase alphanumeric or hyphen characters and cannot start or end with a hyphen."
  }
}

variable "vpc_cidr_block" {
  description = "RFC1918 IPv4 CIDR block for the VPC. LangSmith supports network-aligned prefixes from /16 through /18."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition = try(
      (
        cidrnetmask(var.vpc_cidr_block) != "" &&
        tonumber(split("/", var.vpc_cidr_block)[1]) >= 16 &&
        tonumber(split("/", var.vpc_cidr_block)[1]) <= 18 &&
        cidrhost(var.vpc_cidr_block, 0) == split("/", var.vpc_cidr_block)[0] &&
        length(regexall(
          "^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)",
          cidrhost(var.vpc_cidr_block, 0),
        )) > 0
      ),
      false,
    )
    error_message = "vpc_cidr_block must be a network-aligned RFC1918 IPv4 CIDR with a prefix from /16 through /18."
  }
}

variable "availability_zones" {
  description = "Explicit AZ names. Leave empty to select up to three standard AZs from the provider region, with a minimum of two."
  type        = list(string)
  default     = []

  validation {
    condition = (
      length(var.availability_zones) == 0 ||
      (
        length(var.availability_zones) >= 2 &&
        length(var.availability_zones) <= 3 &&
        length(var.availability_zones) == length(distinct(var.availability_zones))
      )
      ) && alltrue([
        for az in var.availability_zones : can(regex("^[a-z]{2}(-[a-z0-9]+)*-[0-9][a-z]$", az))
    ])
    error_message = "availability_zones must be empty or contain 2-3 unique standard AWS availability zone names."
  }
}

variable "private_app_subnet_cidrs" {
  description = "Private application subnet CIDRs, one per selected AZ."
  type        = list(string)
  default     = null

  validation {
    condition = var.private_app_subnet_cidrs == null ? true : (
      length(var.private_app_subnet_cidrs) >= 2 &&
      alltrue([for cidr in var.private_app_subnet_cidrs : can(cidrnetmask(cidr))])
    )
    error_message = "private_app_subnet_cidrs must be null or contain at least two valid IPv4 CIDR blocks."
  }
}

variable "private_db_subnet_cidrs" {
  description = "Private isolated database subnet CIDRs, one per selected AZ."
  type        = list(string)
  default     = null

  validation {
    condition = var.private_db_subnet_cidrs == null ? true : (
      length(var.private_db_subnet_cidrs) >= 2 &&
      alltrue([for cidr in var.private_db_subnet_cidrs : can(cidrnetmask(cidr))])
    )
    error_message = "private_db_subnet_cidrs must be null or contain at least two valid IPv4 CIDR blocks."
  }
}

variable "publicly_accessible" {
  description = "Create public subnets and an internet-gateway route for internet-facing load balancers."
  type        = bool
  default     = false
}

variable "public_subnet_cidrs" {
  description = "Optional public subnet CIDRs, one per selected AZ. Used only when creating a data plane with a public ingress endpoint."
  type        = list(string)
  default     = null

  validation {
    condition = var.public_subnet_cidrs == null ? true : alltrue([
      for cidr in var.public_subnet_cidrs : can(cidrnetmask(cidr))
    ])
    error_message = "public_subnet_cidrs must be null or contain only valid IPv4 CIDR blocks."
  }
}

variable "create_internet_gateway" {
  description = "Create an Internet Gateway. Required by the module-managed regional NAT and public subnets."
  type        = bool
  default     = true
}

variable "create_nat_gateway" {
  description = "Create a regional NAT gateway and default routes from private application subnets. Disable if you wish to manage egress separately."
  type        = bool
  default     = true
}

variable "enable_vpc_flow_logs" {
  description = "Create an S3-backed VPC Flow Log that records accepted and rejected traffic with 90-day retention. Enabled by default; set to false to disable."
  type        = bool
  default     = true
}

variable "flow_logs_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for the flow-log bucket. Use a symmetric key in the bucket's region with a key policy permitting VPC flow-log delivery. Null uses S3-managed encryption; ignored when flow logs are disabled."
  type        = string
  default     = null

  validation {
    condition     = var.flow_logs_kms_key_arn == null || can(regex("^arn:[a-z0-9-]+:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.flow_logs_kms_key_arn))
    error_message = "flow_logs_kms_key_arn must be null or a full KMS key ARN."
  }
}

variable "enable_vpc_endpoints" {
  description = "Create an S3 Gateway endpoint and customer-owned Interface endpoints for interface_endpoint_services."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "AWS Interface endpoint services to create when enable_vpc_endpoints is true."
  type        = list(string)
  default = [
    "ec2",
    "sts",
    "eks",
    "eks-auth",
    "logs",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "elasticloadbalancing",
    "secretsmanager",
    "monitoring",
    "elasticache",
    "ecr.api",
    "ecr.dkr",
  ]

  validation {
    condition = length(var.interface_endpoint_services) == length(distinct(var.interface_endpoint_services)) && alltrue([
      for service in var.interface_endpoint_services : contains([
        "ec2",
        "sts",
        "eks",
        "eks-auth",
        "logs",
        "ssm",
        "ssmmessages",
        "ec2messages",
        "elasticloadbalancing",
        "secretsmanager",
        "monitoring",
        "elasticache",
        "ecr.api",
        "ecr.dkr",
      ], service)
    ])
    error_message = "interface_endpoint_services must be unique and selected from the module's supported AWS service allowlist."
  }
}

variable "enable_control_plane_privatelink" {
  description = "Create customer-owned data-plane-to-control-plane PrivateLink endpoint and private DNS resources."
  type        = bool
  default     = false
}

variable "aws_marketplace_product_code" {
  description = "Optional AWS Marketplace product code used for the aws-apn-id Partner Revenue Measurement tag."
  type        = string
  default     = "5iyery30g5gp8777bzkpum6uq"

  validation {
    condition     = var.aws_marketplace_product_code == null || can(regex("^[a-z0-9]+$", var.aws_marketplace_product_code))
    error_message = "aws_marketplace_product_code must be null or lowercase alphanumeric characters."
  }
}

variable "tags" {
  description = "Tags to apply to all module resources. Resource-specific Name tags and the optional aws-apn-id tag take precedence."
  type        = map(string)
  default     = {}
}
