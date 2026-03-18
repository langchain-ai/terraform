variable "name" {
  type        = string
  description = "Base name for bastion resources (e.g. acme-prod)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the bastion will be placed"
}

variable "subnet_id" {
  type        = string
  description = "Public subnet ID for the bastion host"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used to pre-configure kubeconfig on the bastion"
}

variable "region" {
  type        = string
  description = "AWS region — used for kubeconfig and CLI defaults"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the bastion"
  default     = "t3.micro"
}

variable "ami_id" {
  type        = string
  description = "Override AMI ID. Leave empty to use the latest Amazon Linux 2023."
  default     = ""
}

variable "key_name" {
  type        = string
  description = "EC2 key pair name for SSH access. Leave empty to rely on SSM Session Manager only."
  default     = null
}

variable "enable_ssh" {
  type        = bool
  description = "Whether to open port 22 in the bastion security group. Only needed if using an SSH key pair."
  default     = false
}

variable "ssh_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH into the bastion. Only used when enable_ssh = true."
  default     = []
}

variable "root_volume_size_gb" {
  type        = number
  description = "Root EBS volume size in GB"
  default     = 20
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to bastion resources"
  default     = {}
}
