#------------------------------------------------------------------------------
# The box: an EC2 instance this module makes, or a machine named by ssh_host.
#------------------------------------------------------------------------------

locals {

  # ip serves HTTPS only; dns also needs 80 for Let's Encrypt's HTTP challenge and the redirect.
  web_ports = { localhost = [], tunnel = [], ip = [443], dns = [80, 443] }[var.access]
}

module "aws" {
  source = "./hosts/aws"
  count  = var.cloud == "aws" ? 1 : 0

  name                 = var.name
  instance_type        = local.aws_instance
  arch                 = can(regex("^[a-z][0-9]+g", local.aws_instance)) ? "arm64" : "amd64"
  root_disk_gi         = local.system_disk_gi
  data_disk_gi         = local.data_disk_gi
  backup_snapshot_days = var.backup_snapshot_days
  subnet_id            = var.aws_subnet_id
  ssh_public_key       = var.ssh_public_key
  admin_cidrs          = var.admin_cidrs
  web_ports            = local.web_ports
  access_cidrs         = var.access_cidrs
}

locals {
  host = var.cloud == "aws" ? module.aws[0].host : var.cloud == "cluster" ? "" : var.ssh_host
}

resource "terraform_data" "host" {
  input = local.host

  lifecycle {
    precondition {
      condition     = var.cloud != "baremetal" || var.ssh_host != ""
      error_message = "cloud = baremetal needs ssh_host: the box's address or ssh alias."
    }
    # A machine larger than the preset needs an instance as large; the preset's type would be refused
    # by the install after the instance was already running.
    precondition {
      condition     = var.cloud != "aws" || var.machine == null || var.aws_instance_type != ""
      error_message = "cloud = aws with machine set needs aws_instance_type: an instance with at least that machine's vCPUs and memory."
    }
    precondition {
      condition     = var.cloud != "aws" || length(var.admin_cidrs) > 0
      error_message = "cloud = aws needs admin_cidrs: without ssh from somewhere nothing can install the box."
    }
    precondition {
      condition     = var.cloud != "aws" || can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) ", var.ssh_public_key))
      error_message = "cloud = aws needs ssh_public_key, an OpenSSH public key (ssh-ed25519 ...)."
    }
  }
}
