# ══════════════════════════════════════════════════════════════════════════════
# Module: waf
# Purpose: Azure Web Application Firewall policy for LangSmith ingress.
#
# Attaches OWASP 3.2 managed rules + bot protection to block common attacks
# (SQLi, XSS, Log4Shell, Spring4Shell) before they reach the NGINX ingress.
#
# Deployment options:
#   Option A (default): WAF policy only — attach to an existing Application
#                       Gateway or Azure Front Door manually.
#   Option B: Set create_application_gateway = true to provision an
#             Application Gateway v2 WAF SKU (replaces NGINX as ingress).
#             Requires a dedicated /24 subnet (pass app_gateway_subnet_id).
#
# Cost estimate (Option A — policy only): ~$0/mo (policy is free until attached)
# Cost estimate (Option B — App Gateway):  ~$250/mo (WAF_v2 fixed fee)
# ══════════════════════════════════════════════════════════════════════════════

# WAF Policy with OWASP 3.2 + Bot Manager rules.
# Prevention mode: blocks matching requests (use Detection for initial rollout).
resource "azurerm_web_application_firewall_policy" "waf" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "waf" })

  policy_settings {
    enabled                     = true
    mode                        = var.waf_mode
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  # OWASP Core Rule Set 3.2 — covers SQLi, XSS, path traversal, RFI/LFI,
  # Log4Shell, Spring4Shell, and other OWASP Top 10 attack patterns.
  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }

    # Microsoft Bot Manager — blocks known malicious bots, scrapers,
    # vulnerability scanners, and Tor exit nodes.
    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
    }
  }
}
