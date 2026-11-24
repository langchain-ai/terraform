variable "name" {
  type        = string
  description = "Names the key pair, the security group and the instance."
}

variable "instance_type" {
  type        = string
  description = "The EC2 instance type."
}

variable "arch" {
  type        = string
  description = "The image architecture for the instance type: amd64 or arm64."

  validation {
    condition     = contains(["amd64", "arm64"], var.arch)
    error_message = "arch must be amd64 or arm64."
  }
}

variable "disk_gi" {
  type        = number
  description = "The root volume in GiB: the OS, k3s, the images and every store."
}

variable "subnet_id" {
  type        = string
  description = "A public subnet; empty for the default VPC's first default subnet."
}

variable "ssh_public_key" {
  type        = string
  description = "The public key the instance admits (checked by the root, hosts.tf)."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Who may reach ssh (checked by the root, hosts.tf)."
}

variable "web_ports" {
  type        = list(number)
  description = "The ports LangSmith is served on: none for localhost and tunnel, 443 for ip, 80 and 443 for dns."
}

variable "access_cidrs" {
  type        = list(string)
  description = "Who may reach web_ports."
}
