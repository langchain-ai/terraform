# alb: Pre-provisions an Application Load Balancer so its DNS name is a known
# Terraform output before the Helm chart is deployed.
# The AWS Load Balancer Controller takes ownership of listener rules and target groups
# via the Ingress annotation: alb.ingress.kubernetes.io/load-balancer-arn

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_elb_service_account" "current" {}

# ── Access Logs S3 Bucket ──────────────────────────────────────────────────────
# Created only when access_logs_enabled = true.
# The ELB service requires a specific bucket policy — it cannot write to an
# arbitrary bucket without it.

resource "aws_s3_bucket" "access_logs" {
  count         = var.access_logs_enabled ? 1 : 0
  bucket        = "${var.name}-access-logs"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count  = var.access_logs_enabled ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "access_logs" {
  count  = var.access_logs_enabled ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.current.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs[0].arn}/${var.access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs[0].arn}/${var.access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

# ── Security Group ─────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.name}-sg"
  description = "Allow inbound HTTP/HTTPS to LangSmith ALB"
  vpc_id      = var.vpc_id

  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = var.internal ? [var.vpc_cidr_block] : ["0.0.0.0/0"]
    ipv6_cidr_blocks = var.internal ? [] : ["::/0"]
  }

  dynamic "ingress" {
    for_each = var.tls_certificate_source != "none" ? [1] : []
    content {
      description      = "HTTPS"
      from_port        = 443
      to_port          = 443
      protocol         = "tcp"
      cidr_blocks      = var.internal ? [var.vpc_cidr_block] : ["0.0.0.0/0"]
      ipv6_cidr_blocks = var.internal ? [] : ["::/0"]
    }
  }

  # Egress scoped to VPC CIDR: ALB only needs to reach EKS pod IPs (target-type: ip).
  # If using VPC peering for targets outside this VPC, add those CIDRs here.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr_block]
  }

  tags = var.tags
}

# ── Load Balancer ──────────────────────────────────────────────────────────────

resource "aws_lb" "this" {
  name                       = var.name
  drop_invalid_header_fields = true
  internal                   = var.internal
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.subnets

  dynamic "access_logs" {
    for_each = var.access_logs_enabled ? [1] : []
    content {
      bucket  = aws_s3_bucket.access_logs[0].id
      prefix  = var.access_logs_prefix
      enabled = true
    }
  }

  # AWS validates the bucket policy when enabling access logs — the policy must
  # exist before the ALB attribute is modified, not just the bucket.
  depends_on = [aws_s3_bucket_policy.access_logs]

  tags = var.tags
}

# ── Listeners ─────────────────────────────────────────────────────────────────
# The ALB Ingress Controller manages routing rules on top of these listeners.
# For tls_certificate_source = "acm":   HTTP:80 → redirect HTTPS, HTTPS:443 → forward
# For tls_certificate_source = "none":  HTTP:80 → forward (controller adds rules)

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.tls_certificate_source == "acm" ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = var.tls_certificate_source == "acm" ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = var.tls_certificate_source != "acm" ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Not Found"
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.tls_certificate_source == "acm" ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}
