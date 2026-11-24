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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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

# The instance's ssh host key, made here and given to it at boot, so the first ssh, which carries every
# credential, checks the key it is shown instead of trusting it (accept-new took any key the first
# time: security review, 2026-11-24). Like every credential, it lives in Terraform's state.
resource "tls_private_key" "host" {
  algorithm = "ED25519"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.chosen.id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.this.id]

  # The system: the operating system, k3s, the images and the logs. The data has a volume of its own.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_disk_gi
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${var.name}-system" }
  }

  user_data = "#cloud-config\n${yamlencode({
    ssh_deletekeys  = true
    ssh_genkeytypes = []
    ssh_keys        = { ed25519_private = tls_private_key.host.private_key_openssh, ed25519_public = trimspace(tls_private_key.host.public_key_openssh) }
  })}"

  # Instance metadata only from the instance itself: one hop, so no pod reaches it (and the host key above).
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
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

# Every store's volume, apart from the system. It outlives the instance (a new image, a replaced or
# resized instance reattaches it); make down deletes it, after the install's name is typed. gp3 grows in
# place, and the install grows its filesystem.
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.chosen.availability_zone
  type              = "gp3"
  size              = var.data_disk_gi
  encrypted         = true
  tags              = { Name = "${var.name}-data", "langsmith-lite/data" = var.name }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
  # Stop the instance before detaching, so the stores are not cut off mid-write.
  stop_instance_before_detaching = true
}

# Daily snapshots of the data volume, kept backup_snapshot_days: crash-consistent copies Postgres and
# RustFS recover from, restorable to a new volume.
resource "aws_iam_role" "snapshots" {
  count = var.backup_snapshot_days > 0 ? 1 : 0
  name  = "${var.name}-snapshots"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "dlm.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "snapshots" {
  count      = var.backup_snapshot_days > 0 ? 1 : 0
  role       = aws_iam_role.snapshots[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  count = var.backup_snapshot_days > 0 ? 1 : 0
  # DLM allows letters, digits, spaces, hyphens and underscores only.
  description        = "${var.name} LangSmith Lite data volume daily snapshots"
  execution_role_arn = aws_iam_role.snapshots[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { "langsmith-lite/data" = var.name }

    schedule {
      name      = "daily"
      copy_tags = true
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }
      retain_rule {
        count = var.backup_snapshot_days
      }
    }
  }
}
