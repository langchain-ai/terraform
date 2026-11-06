# ══════════════════════════════════════════════════════════════════════════════
# Input-combination guards for modules/azure-private.
# The hardened posture (always BYO VNet, overlay+Cilium, UDR, private API server)
# makes the other cross-field guards structurally impossible, so only the
# control-plane identity choice remains a real either/or.
# ══════════════════════════════════════════════════════════════════════════════

resource "terraform_data" "validate_cluster_identity_exclusive" {
  lifecycle {
    precondition {
      condition     = !(var.aks_create_cluster_identity && var.aks_cluster_identity_id != "")
      error_message = "Set only one of aks_create_cluster_identity or aks_cluster_identity_id (mutually exclusive)."
    }

    # A custom (BYO) API-server private DNS zone requires the control-plane identity to
    # hold Private DNS Zone Contributor on that zone. The module-created identity is only
    # granted Network Contributor on the VNet (enough for the default "System" zone), so a
    # custom zone must use a BYO identity (aks_cluster_identity_id) that you've granted the
    # role. Without this guard the combo fails mid-apply with CustomPrivateDNSZoneMissingPermissionError.
    precondition {
      condition     = !(var.aks_create_cluster_identity && !contains(["", "None"], var.aks_private_dns_zone_id))
      error_message = "A custom aks_private_dns_zone_id requires a BYO control-plane identity (aks_cluster_identity_id) with Private DNS Zone Contributor on the zone — not aks_create_cluster_identity = true. Use the System zone (\"\") or supply a pre-authorized identity."
    }

    # AKS rejects a private cluster whose private DNS zone is "None" unless the public FQDN
    # is enabled (there is otherwise no way to resolve the API server).
    precondition {
      condition     = !(var.aks_private_dns_zone_id == "None" && !var.aks_private_cluster_public_fqdn_enabled)
      error_message = "aks_private_dns_zone_id = \"None\" requires aks_private_cluster_public_fqdn_enabled = true (otherwise the API server is unresolvable)."
    }
  }
}
