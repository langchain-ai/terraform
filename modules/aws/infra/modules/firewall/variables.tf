variable "name" {
  type        = string
  description = "Base name for all firewall resources (e.g. acme-prod)"
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC where the firewall is deployed"
}

variable "nat_gateway_id" {
  type        = string
  description = "ID of the NAT gateway. Firewall subnet routes 0.0.0.0/0 here after inspection."
}

variable "nat_gateway_az" {
  type        = string
  description = "Availability zone of the NAT gateway. The firewall subnet is placed in the same AZ."
}

variable "firewall_subnet_cidr" {
  type        = string
  description = "CIDR block for the firewall subnet. Must be within the VPC CIDR and not overlap with existing subnets."
  default     = "10.0.64.0/21"
}

variable "private_route_table_ids" {
  type        = list(string)
  description = "IDs of the private route tables to update. Each table's 0.0.0.0/0 route is pointed at the firewall endpoint."
}

variable "allowed_fqdns" {
  type        = list(string)
  description = "Fully-qualified domain names allowed for outbound internet access. All other destinations are dropped."
  default     = ["beacon.langchain.com"]
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all firewall resources."
  default     = {}
}
