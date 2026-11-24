#------------------------------------------------------------------------------
# One EC2 instance for Lite: Ubuntu 24.04 LTS, one encrypted gp3 volume, a
# fixed public address, and a security group that admits ssh from the
# operator and HTTPS only when LangSmith is served on the address. k3s and
# everything on it are installed over ssh by scripts/install.sh, the same way
# as on any other box, so this module makes a machine and nothing more.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.33.0, < 7.0.0"
    }
  }
}

# Canonical's account; the newest Ubuntu 24.04 image at the first apply. ignore_changes below keeps a
# newer image from replacing the instance, and its data, on a later apply.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.arch}-server-*"]
  }
}

data "aws_vpc" "default" {
  count   = var.subnet_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "chosen" {
  id = var.subnet_id != "" ? var.subnet_id : sort(data.aws_subnets.default[0].ids)[0]
}

resource "aws_key_pair" "this" {
  key_name   = var.name
  public_key = var.ssh_public_key
}

resource "aws_security_group" "this" {
  name        = var.name
  description = "LangSmith Lite: ssh from the operator; HTTPS on the address when LangSmith is served on it"
  vpc_id      = data.aws_subnet.chosen.vpc_id
  tags        = { Name = var.name }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.this.id
  description       = "ssh"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = { for pair in setproduct(var.web_ports, var.access_cidrs) : "${pair[0]}-${pair[1]}" => pair }

  security_group_id = aws_security_group.this.id
  description       = "LangSmith over ${each.value[0] == 443 ? "HTTPS" : "HTTP (redirected to HTTPS, and Let's Encrypt's challenge)"}"
  cidr_ipv4         = each.value[1]
  ip_protocol       = "tcp"
  from_port         = each.value[0]
  to_port           = each.value[0]
}

# k3s's installer, the charts and the images come from the internet.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "everything out"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.chosen.id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.this.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.disk_gi
    encrypted   = true
    # The volume holds every store; a terminated instance takes it, as make down intends.
    delete_on_termination = true
    tags                  = { Name = var.name }
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = var.name }

  lifecycle {
    ignore_changes = [ami]
  }
}

# A fixed address: a DNS record and the operator's ssh config outlive a stop and start.
resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"
  tags     = { Name = var.name }
}
