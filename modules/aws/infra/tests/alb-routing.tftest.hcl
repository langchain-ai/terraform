# Exercise listener destinations, frontend health checks, and the CIDR boundary
# against the real ALB child module. No cloud credentials or state are used.
mock_provider "aws" {
  mock_resource "aws_lb_target_group" {
    override_during = plan
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/plantest/abcdef1234567890"
    }
  }
}

variables {
  name                = "plantest-alb"
  vpc_id              = "vpc-0123456789abcdef0"
  vpc_cidr_block      = "10.0.0.0/16"
  subnets             = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  allowed_cidr_blocks = ["203.0.113.10/32"]
  acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "direct_frontend_https" {
  command = plan
  module { source = "./modules/alb" }

  assert {
    condition     = length(aws_lb_target_group.gateway) == 0 && aws_lb_target_group.frontend[0].port == 8080 && aws_lb_target_group.frontend[0].target_type == "ip"
    error_message = "No-gateway mode must target frontend pod IPs on port 8080."
  }
  assert {
    condition     = aws_lb_target_group.frontend[0].health_check[0].path == "/health" && aws_lb_target_group.frontend[0].health_check[0].matcher == "200"
    error_message = "langsmith-frontend (NGINX) health checks must use its health endpoint."
  }
  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect" && aws_lb_listener.https[0].default_action[0].type == "forward" && one(one(aws_lb_listener.https[0].default_action[0].forward).target_group).arn == aws_lb_target_group.frontend[0].arn
    error_message = "ACM must redirect HTTP to HTTPS and forward HTTPS to frontend pods."
  }
  assert {
    condition     = alltrue([for rule in aws_security_group.alb[0].ingress : rule.cidr_blocks == tolist(["203.0.113.10/32"])])
    error_message = "Client restrictions must apply to the ALB receiving traffic."
  }
}

run "direct_frontend_http" {
  command = plan
  module { source = "./modules/alb" }
  variables { tls_certificate_source = "none" }

  assert {
    condition     = length(aws_lb_listener.https) == 0 && aws_lb_listener.http.default_action[0].type == "forward" && one(one(aws_lb_listener.http.default_action[0].forward).target_group).arn == aws_lb_target_group.frontend[0].arn
    error_message = "HTTP-only mode must forward to frontend pods rather than return a placeholder 404."
  }
}

run "envoy_https" {
  command = plan
  module { source = "./modules/alb" }
  variables { enable_envoy_gateway = true }

  assert {
    condition     = length(aws_lb_target_group.frontend) == 0 && aws_lb_target_group.gateway[0].port == 10080 && one(one(aws_lb_listener.https[0].default_action[0].forward).target_group).arn == aws_lb_target_group.gateway[0].arn
    error_message = "Envoy must receive ALB traffic on port 10080 without a frontend target group."
  }
}

run "istio_https" {
  command = plan
  module { source = "./modules/alb" }
  variables { enable_istio_gateway = true }

  assert {
    condition     = length(aws_lb_target_group.frontend) == 0 && aws_lb_target_group.gateway[0].port == 80 && one(one(aws_lb_listener.https[0].default_action[0].forward).target_group).arn == aws_lb_target_group.gateway[0].arn
    error_message = "Istio must receive ALB traffic on port 80 without a frontend target group."
  }
}
