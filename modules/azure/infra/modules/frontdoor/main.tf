# ══════════════════════════════════════════════════════════════════════════════
# Module: frontdoor
# Purpose: Azure Front Door Standard/Premium as the edge layer for LangSmith.
#
# Front Door handles:
#   - Managed TLS certificates (CNAME validation — no cert-manager needed)
#   - HTTPS redirect enforcement
#   - Global CDN / PoP acceleration
#   - Optional WAF (Premium SKU required for WAF attachment)
#
# Works with any AKS ingress controller (NGINX, Istio, istio-addon).
# Front Door routes to the ingress controller LB hostname/IP over HTTP.
# TLS is terminated at the Front Door edge — no TLS config needed on the LB.
#
# AWS equivalent: CloudFront + ACM + ALB
#   AWS: CloudFront → ALB → pod
#   Azure: Front Door → AKS ingress LB → pod
#
# Deployment flow:
#   1. terraform apply (first pass)  → note the fd_endpoint_hostname output
#   2. At your registrar: add CNAME  langsmith.<domain>  →  fd_endpoint_hostname
#   3. Wait for DNS propagation      → Front Door validates domain automatically
#   4. Set create_frontdoor = true, frontdoor_origin_hostname = <ingress LB IP>
#   5. terraform apply again         → managed cert is issued
#
# Note: origin_hostname may be an IP address (NGINX LB) or a hostname
# (Istio gateway). Front Door supports both as origin.
# ══════════════════════════════════════════════════════════════════════════════

# Front Door Standard/Premium profile.
# Standard: CDN + TLS + routing (no WAF).
# Premium:  Standard + WAF attachment + private link origins.
resource "azurerm_cdn_frontdoor_profile" "fd" {
  name                = var.name
  resource_group_name = var.resource_group_name
  sku_name            = var.sku_name
  tags                = merge(var.tags, { module = "frontdoor" })
}

# Front Door endpoint — the public-facing FQDN that CNAME points to.
# Customer adds: CNAME langsmith.example.com → <endpoint_hostname>
resource "azurerm_cdn_frontdoor_endpoint" "endpoint" {
  name                     = var.name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id
  tags                     = merge(var.tags, { module = "frontdoor" })
}

# Origin group — defines health probe settings for the AKS ingress backend.
resource "azurerm_cdn_frontdoor_origin_group" "origin_group" {
  name                     = "${var.name}-origins"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id

  # Front Door probes / at the origin over HTTP on port 80 every 30s.
  # If the ingress controller returns 2xx/3xx the origin is healthy.
  health_probe {
    interval_in_seconds = 30
    path                = "/healthz"
    protocol            = "Http"
    request_type        = "GET"
  }

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }
}

# Origin — the AKS ingress controller LoadBalancer IP or hostname.
# Works with NGINX (IP) and Istio gateway (IP or hostname).
# Front Door forwards traffic over HTTP (port 80) — TLS is at the FD edge.
# Only created after origin_hostname is set (second apply, after ingress LB is provisioned).
resource "azurerm_cdn_frontdoor_origin" "aks_ingress" {
  count                         = var.origin_hostname != "" ? 1 : 0
  name                          = "${var.name}-aks"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.origin_group.id

  # Send traffic to the ingress LB over plain HTTP.
  # The AKS ingress controller does not need to handle TLS.
  enabled                        = true
  certificate_name_check_enabled = false
  host_name                      = var.origin_hostname
  http_port                      = 80
  https_port                     = 443
  # Host header sent to the origin. Must match what the ingress controller routes on:
  # - Custom domain set: use it (VirtualService/Ingress matches custom domain)
  # - No custom domain: use FD endpoint hostname (VirtualService matches FD hostname)
  # Do NOT use origin_hostname (the IP) — Istio VirtualService won't match an IP Host header.
  origin_host_header             = var.custom_domain != "" ? var.custom_domain : azurerm_cdn_frontdoor_endpoint.endpoint.host_name
  priority                       = 1
  weight                         = 1000
}

# Custom domain — ties the customer domain to the Front Door profile.
# Managed certificate is issued automatically after CNAME validation.
resource "azurerm_cdn_frontdoor_custom_domain" "domain" {
  count                    = var.custom_domain != "" ? 1 : 0
  name                     = replace(var.custom_domain, ".", "-")
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id
  host_name                = var.custom_domain

  # Azure manages the TLS certificate automatically.
  # Validation is done via a CNAME/TXT DNS record at the registrar.
  tls {
    certificate_type = "ManagedCertificate"
  }
}

# Route — wires endpoint + custom domain → origin group.
# HTTPS is enforced: HTTP requests are redirected to HTTPS.
# Only created after origin_hostname is set (second apply, after ingress LB is provisioned).
resource "azurerm_cdn_frontdoor_route" "route" {
  count                         = var.origin_hostname != "" ? 1 : 0
  name                          = "${var.name}-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.endpoint.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.origin_group.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.aks_ingress[0].id]

  # Allow HTTP on FD endpoint but redirect to HTTPS immediately.
  https_redirect_enabled = true
  forwarding_protocol    = "HttpOnly"
  link_to_default_domain = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]

  # Associate the custom domain so the managed cert covers it.
  cdn_frontdoor_custom_domain_ids = var.custom_domain != "" ? [
    azurerm_cdn_frontdoor_custom_domain.domain[0].id
  ] : []

  depends_on = [azurerm_cdn_frontdoor_origin.aks_ingress]
}

# Custom domain association — required by Azure in addition to the route association.
# Only created after origin (and therefore route) exists.
resource "azurerm_cdn_frontdoor_custom_domain_association" "domain_assoc" {
  count                          = var.custom_domain != "" && var.origin_hostname != "" ? 1 : 0
  cdn_frontdoor_custom_domain_id = azurerm_cdn_frontdoor_custom_domain.domain[0].id
  cdn_frontdoor_route_ids        = [azurerm_cdn_frontdoor_route.route[0].id]
}

# Security policy — attaches WAF to Front Door (Premium SKU only).
# Pass waf_policy_id from the waf module output to enable WAF.
# Leave waf_policy_id empty to skip — policy is not required for Front Door to work.
resource "azurerm_cdn_frontdoor_security_policy" "waf" {
  count                    = var.waf_policy_id != "" ? 1 : 0
  name                     = "${var.name}-waf-policy"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = var.waf_policy_id

      association {
        patterns_to_match = ["/*"]

        # WAF applies to the custom domain (and default endpoint if no custom domain).
        dynamic "domain" {
          for_each = var.custom_domain != "" ? [1] : []
          content {
            cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_custom_domain.domain[0].id
          }
        }

        dynamic "domain" {
          for_each = var.custom_domain == "" ? [1] : []
          content {
            cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.endpoint.id
          }
        }
      }
    }
  }
}
