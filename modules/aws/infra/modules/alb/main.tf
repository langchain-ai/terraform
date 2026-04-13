# alb: Pre-provisions an Application Load Balancer so its DNS name is a known
# Terraform output before the Helm chart is deployed.
# https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html
#
# The AWS Load Balancer Controller takes ownership of listener rules and target groups
# via the Ingress annotation: alb.ingress.kubernetes.io/load-balancer-arn
# https://kubernetes-sigs.github.io/aws-load-balancer-controller/

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
  # Envoy proxy: port 80 in the Gateway → container port 10080 (Envoy Gateway adds 10000).
  # Istio ingress gateway: listens directly on port 80 (envoy with NET_BIND_SERVICE).
  # NGINX ingress controller: listens on port 80.
  gateway_target_port = var.enable_envoy_gateway ? 10080 : 80
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

resource "aws_security_group" "alb" {
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
  # If using VPC peering for targets outside this VPC, add those CIDRs here.
  egress {
    description = "Allow all outbound to VPC"
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
  idle_timeout               = 3600
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

  name        = substr("${var.name}-gw", 0, 32)
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

  tags = var.tags
}

# ── Listeners ─────────────────────────────────────────────────────────────────
# Traffic routing by mode:
#   ALB mode (no gateway):  HTTP:80 → fixed-response 404 (ALB Ingress Controller adds rules)
#                           HTTP:80 → redirect HTTPS (when tls=acm)
#                           HTTPS:443 → fixed-response 404 (ALB Ingress Controller adds rules)
#   Gateway mode:           HTTP:80 → forward to gateway TG (Envoy/Istio proxy pods)
#                           HTTP:80 → redirect HTTPS (when tls=acm)
#                           HTTPS:443 → forward to gateway TG (when tls=acm + gateway)

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    # Priority: ACM redirect > gateway forward > ALB-controller (fixed-response placeholder)
    type = (
      var.tls_certificate_source == "acm" ? "redirect" :
      local.gateway_enabled ? "forward" :
      "fixed-response"
    )

    dynamic "redirect" {
      for_each = var.tls_certificate_source == "acm" ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    # gateway_enabled + no ACM: ALB forwards directly to Envoy/Istio proxy pods.
    dynamic "forward" {
      for_each = var.tls_certificate_source != "acm" && local.gateway_enabled ? [aws_lb_target_group.gateway[0].arn] : []
      content {
        target_group {
          arn = forward.value
        }
      }
    }

    # ALB-only mode (no gateway, no ACM): placeholder 404 — the ALB Ingress Controller
    # adds real forwarding rules via Ingress resource annotations.
    dynamic "fixed_response" {
      for_each = var.tls_certificate_source != "acm" && !local.gateway_enabled ? [1] : []
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
    # Gateway mode with ACM: forward HTTPS to the Envoy/Istio proxy.
    # ALB-only mode: placeholder 404 — the ALB Ingress Controller adds real rules.
    type = local.gateway_enabled ? "forward" : "fixed-response"

    dynamic "forward" {
      for_each = local.gateway_enabled ? [aws_lb_target_group.gateway[0].arn] : []
      content {
        target_group {
          arn = forward.value
        }
      }
    }

    dynamic "fixed_response" {
      for_each = !local.gateway_enabled ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Not Found"
        status_code  = "404"
      }
    }
  }
}
