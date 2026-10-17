variable "name" {
  description = "Name prefix for the peering connection and its routes."
  type        = string
  default     = "langsmith-byoc-migration"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$", var.name))
    error_message = "name must be 2-64 lowercase alphanumeric or hyphen characters and cannot start or end with a hyphen."
  }
}

variable "self_hosted_vpc_id" {
  description = "VPC that hosts the self-hosted LangSmith installation. The peering request is created from this VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-([0-9a-f]{8}|[0-9a-f]{17})$", var.self_hosted_vpc_id))
    error_message = "self_hosted_vpc_id must be a valid VPC ID."
  }
}

variable "self_hosted_route_table_ids" {
  description = "Route tables that receive a route to the data plane VPC CIDR through the peering connection. Leave null to route from every route table in the self-hosted VPC."
  type        = set(string)
  default     = null

  validation {
    condition     = var.self_hosted_route_table_ids == null || length(coalesce(var.self_hosted_route_table_ids, [])) > 0
    error_message = "Provide at least one route table ID or leave self_hosted_route_table_ids null."
  }

  validation {
    condition     = alltrue([for id in coalesce(var.self_hosted_route_table_ids, []) : can(regex("^rtb-([0-9a-f]{8}|[0-9a-f]{17})$", id))])
    error_message = "Every self_hosted_route_table_ids entry must be a valid route table ID."
  }
}

variable "self_hosted_role_arn" {
  description = "IAM role the self-hosted LangSmith pods run as. It receives permission to assume the data plane SmithDB role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.self_hosted_role_arn))
    error_message = "self_hosted_role_arn must be an IAM role ARN."
  }
}

variable "data_plane_account_id" {
  description = "AWS account ID that owns the BYOC data plane, provided by LangChain team. Required even when it matches the self-hosted account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.data_plane_account_id))
    error_message = "data_plane_account_id must be a 12-digit AWS account ID."
  }
}

variable "data_plane_region" {
  description = "AWS region of the BYOC data plane VPC, provided by LangChain team. Required even when it matches the self-hosted region."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.data_plane_region))
    error_message = "data_plane_region must be an AWS region name."
  }
}

variable "data_plane_vpc_id" {
  description = "VPC of the BYOC data plane, provided by LangChain team."
  type        = string

  validation {
    condition     = can(regex("^vpc-([0-9a-f]{8}|[0-9a-f]{17})$", var.data_plane_vpc_id))
    error_message = "data_plane_vpc_id must be a valid VPC ID."
  }
}

variable "data_plane_vpc_cidr_block" {
  description = "IPv4 CIDR block of the data plane VPC. It must not overlap the self-hosted VPC."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.data_plane_vpc_cidr_block))
    error_message = "data_plane_vpc_cidr_block must be an IPv4 CIDR block."
  }
}

variable "data_plane_smithdb_role_arn" {
  description = "SmithDB IAM role for the BYOC data plane, provided by LangChain team."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.data_plane_smithdb_role_arn))
    error_message = "data_plane_smithdb_role_arn must be an IAM role ARN."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
