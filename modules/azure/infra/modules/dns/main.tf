# ══════════════════════════════════════════════════════════════════════════════
# Module: dns
# Purpose: Azure DNS zone + A record for the LangSmith public domain.
#
# Creates a public DNS zone, points it at the NGINX ingress LB IP, and
# grants cert-manager the DNS Zone Contributor role so it can create TXT
# records for ACME DNS-01 challenges (more reliable than HTTP-01 for wildcard
# certs and private clusters).
#
# Usage:
#   1. Apply this module → note the nameservers in outputs
#   2. Delegate the zone at your registrar (add NS records pointing to Azure)
#   3. cert-manager DNS-01 challenges will auto-complete once NS delegation propagates
#
# Equivalent to AWS: Route 53 hosted zone + ACM cert + alias record.
# ══════════════════════════════════════════════════════════════════════════════

# Public DNS zone for the LangSmith domain.
resource "azurerm_dns_zone" "main" {
  name                = var.domain
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "dns" })
}

# A record pointing the root domain (and www) at the NGINX ingress LB IP.
resource "azurerm_dns_a_record" "langsmith" {
  name                = "@"
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [var.ingress_ip]
  tags                = merge(var.tags, { module = "dns" })
}

# cert-manager needs DNS Zone Contributor to create/delete TXT records
# for ACME DNS-01 challenge verification.
# Scoped to this specific zone — cert-manager cannot modify other zones.
resource "azurerm_role_assignment" "cert_manager_dns" {
  count                = var.cert_manager_principal_id != "" ? 1 : 0
  scope                = azurerm_dns_zone.main.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = var.cert_manager_principal_id
}
