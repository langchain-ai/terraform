# Bastion host for private EKS cluster access.
# Defaults to a private subnet with SSM Session Manager (no public IP needed).
# Set enable_ssh = true + associate_public_ip = true for SSH access from a
# public subnet. Pre-installs kubectl, helm, aws cli, and terraform so
# operators can run Pass 1/2 from the bastion when the EKS API endpoint
# is private-only.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- IAM instance profile for SSM Session Manager ---

resource "aws_iam_role" "bastion" {
  name = "${var.name}-bastion"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "eks_readonly" {
  name = "eks-readonly"
  role = aws_iam_role.bastion.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:ListClusters",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name}-bastion"
  role = aws_iam_role.bastion.name
  tags = var.tags
}

# --- Security group ---

resource "aws_security_group" "bastion" {
  name_prefix = "${var.name}-bastion-"
  description = "Bastion host — SSM + optional SSH ingress"
  vpc_id      = var.vpc_id
  tags        = var.tags

  # Outbound: allow all (needed for SSM agent, yum, kubectl, helm, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "ssh_ingress" {
  count = var.enable_ssh ? 1 : 0

  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.ssh_allowed_cidrs
  description       = "SSH access from allowed CIDRs"
  security_group_id = aws_security_group.bastion.id
}

# --- EC2 instance ---

resource "aws_instance" "bastion" {
  ami                    = var.ami_id != "" ? var.ami_id : data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  key_name               = var.key_name

  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    cluster_name = var.cluster_name
    region       = var.region
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, {
    Name = "${var.name}-bastion"
  })
}
