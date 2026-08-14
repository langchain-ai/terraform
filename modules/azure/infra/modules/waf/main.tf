# ══════════════════════════════════════════════════════════════════════════════
# Module: waf
# Purpose: Azure Web Application Firewall policy for LangSmith ingress.
#
# OWASP 3.2 managed rules + bot protection against common attacks (SQLi, XSS,
# Log4Shell, Spring4Shell) at the edge, before traffic reaches the ingress.
#
# This module only creates the policy. Who attaches it depends on the ingress:
#   ingress_controller = "agic": the root module passes this policy to the
#     Application Gateway and moves it to WAF_v2, the one tier Azure allows a
#     policy association on.
#   any other controller: nothing references the policy. It exists for an Azure
#     Front Door or a gateway you own to point at, and inspects nothing until
#     something does.
#
# Cost: the policy itself is free. A WAF_v2 gateway is ~$250/mo over Standard_v2,
# so create_waf with AGIC changes the gateway's bill.
# ══════════════════════════════════════════════════════════════════════════════

# WAF Policy with OWASP 3.2 + Bot Manager rules.
# Detection mode by default: matches are logged, not blocked. Switch to
# Prevention once the firewall log is clean of false positives.
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

    # LangSmith's primary data path is batched run payloads, which routinely
    # exceed the 128 KB body limit. Left enforcing, Azure blocks an over-size
    # request outright in Prevention mode, so trace ingestion fails. Off, the WAF
    # inspects what fits and passes the request rather than rejecting it for
    # size — rules still apply to headers, cookies, the URI, and the inspected
    # portion of the body. CRS 3.2 is what makes this separable from
    # request_body_check.
    request_body_enforcement = false
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
