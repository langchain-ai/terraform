# alb: Pre-provisions an Application Load Balancer so its DNS name is a known
# Terraform output before the Helm chart is deployed.
# https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
#
# Terraform owns listeners and target groups in every mode. TargetGroupBindings
# let the AWS Load Balancer Controller register pod IPs without creating an ALB.

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

locals {
  gateway_enabled = var.enable_envoy_gateway || var.enable_istio_gateway || var.enable_nginx_ingress
  # Envoy Gateway: pods listen on port 10080 (Gateway listener port 80 + 10000 offset,
  # Envoy runs non-root and can't bind to privileged ports below 1024).
  # Istio ingress gateway: listens directly on port 80 (envoy with NET_BIND_SERVICE).
  # NGINX ingress controller: listens on port 80.
  gateway_target_port = var.enable_envoy_gateway ? 10080 : 80

  byo_security_group = var.existing_security_group_id != null && var.existing_security_group_id != ""
  security_group_id  = local.byo_security_group ? var.existing_security_group_id : aws_security_group.alb[0].id
}

# ── Access Logs S3 Bucket ──────────────────────────────────────────────────────
# Created only when access_logs_enabled = true.
# The ELB service requires a specific bucket policy — it cannot write to an
# arbitrary bucket without it.

resource "aws_s3_bucket" "access_logs" {
  count         = var.access_logs_enabled ? 1 : 0
  bucket        = var.bucket_suffix != "" ? "${var.name}-access-logs-${var.bucket_suffix}" : "${var.name}-access-logs"
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
# Skipped when var.existing_security_group_id is set. Terraform never writes
# rules onto a customer-supplied security group (attach-only BYO).

# Preserves state: without this, existing deployments would see their ALB
# security group destroyed and recreated just from the count above changing
# its address from aws_security_group.alb to aws_security_group.alb[0].
moved {
  from = aws_security_group.alb
  to   = aws_security_group.alb[0]
}

resource "aws_security_group" "alb" {
  count = local.byo_security_group ? 0 : 1

  name        = "${var.name}-sg"
  description = "Allow inbound HTTP/HTTPS to LangSmith ALB"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  dynamic "ingress" {
    for_each = var.tls_certificate_source != "none" ? [1] : []
    content {
      description = "HTTPS"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidr_blocks
    }
  }

  # Egress scoped to VPC CIDR: ALB only needs to reach EKS pod IPs (target-type: ip).
  # Under VPC CNI custom networking the pods live in pod_cidr_blocks instead.
  # If using VPC peering for targets outside this VPC, add those CIDRs here.
  egress {
    description = "Allow all outbound to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = concat([var.vpc_cidr_block], var.pod_cidr_blocks)
  }

  tags = var.tags
}

# ── Load Balancer ──────────────────────────────────────────────────────────────

resource "aws_lb" "this" {
  name                       = var.name
  drop_invalid_header_fields = true
  idle_timeout               = 3600
  internal                   = var.internal
  load_balancer_type         = "application"
  security_groups            = [local.security_group_id]
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

# ── Gateway Target Group ───────────────────────────────────────────────────────
# When Envoy Gateway or Istio is enabled, the ALB forwards to the gateway proxy
# pods directly (target-type: ip via VPC-CNI) instead of relying on a NodePort.
# A TargetGroupBinding in k8s-bootstrap wires this TG to the gateway proxy service
# so the ALB controller registers pod IPs automatically.
#
# Envoy Gateway: pods listen on port 10080 (Gateway listener port 80 + 10000 offset).
# Istio:         pods listen on port 80    (istio-ingressgateway with NET_BIND_SERVICE).
# NGINX:         pods listen on port 80    (ingress-nginx-controller).
# Health check uses "200-404": Envoy/Istio returns 404 on unknown paths, which is
# still a sign the proxy is alive and ready to serve traffic.

resource "aws_lb_target_group" "gateway" {
  count = local.gateway_enabled ? 1 : 0

  name_prefix = substr("${var.name}-gw-", 0, 6)
  port        = local.gateway_target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/"
    port                = tostring(local.gateway_target_port)
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200-404"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# langsmith-frontend (NGINX) already routes the core application's UI and API requests.
# Its binding is installed after the application Helm release creates the
# Service; gateway bindings remain part of infrastructure bootstrap.
resource "aws_lb_target_group" "frontend" {
  count = local.gateway_enabled ? 0 : 1

  name_prefix = substr("${var.name}-fe-", 0, 6)
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path    = "/health"
    port    = "traffic-port"
    matcher = "200"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

locals {
  application_target_group_arn = local.gateway_enabled ? aws_lb_target_group.gateway[0].arn : aws_lb_target_group.frontend[0].arn
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.tls_certificate_source == "acm" ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = var.tls_certificate_source == "acm" ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "forward" {
      for_each = var.tls_certificate_source != "acm" ? [local.application_target_group_arn] : []
      content {
        target_group {
          arn = forward.value
        }
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
    type = "forward"
    forward {
      target_group {
        arn = local.application_target_group_arn
      }
    }
  }
}
