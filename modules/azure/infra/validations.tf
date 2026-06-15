# ══════════════════════════════════════════════════════════════════════════════
# Input-combination guards.
#
# These catch invalid *combinations* of flags that the azurerm provider does not
# reject on its own. Empty BYO IDs (resource_group_name, vnet_id, subnet IDs) are
# deliberately NOT guarded here — azurerm already errors on an empty name/ID at
# plan time, so a duplicate guard would be dead code that never surfaces.
#
# Implemented as terraform_data preconditions so they work under the module's
# required_version >= 1.5 (cross-variable validation inside `variable` blocks
# requires Terraform >= 1.9). One guard per resource so `terraform test`
# expect_failures can target a specific rule.
# ══════════════════════════════════════════════════════════════════════════════

resource "terraform_data" "validate_udr_requires_byo_vnet" {
  lifecycle {
    precondition {
      condition     = var.aks_outbound_type != "userDefinedRouting" || var.create_vnet == false
      error_message = "aks_outbound_type = userDefinedRouting requires create_vnet = false (the existing subnet must carry a route table with a default route to your firewall/NVA)."
    }
  }
}

resource "terraform_data" "validate_cilium_requires_overlay" {
  lifecycle {
    precondition {
      condition     = var.aks_network_policy != "cilium" || var.aks_network_plugin_mode == "overlay"
      error_message = "aks_network_policy = cilium requires aks_network_plugin_mode = overlay."
    }
  }
}

resource "terraform_data" "validate_private_cluster_no_ip_ranges" {
  lifecycle {
    precondition {
      condition     = var.aks_private_cluster_enabled == false || length(var.aks_authorized_ip_ranges) == 0
      error_message = "aks_authorized_ip_ranges must be empty when aks_private_cluster_enabled = true (mutually exclusive)."
    }
  }
}

resource "terraform_data" "validate_cluster_identity_exclusive" {
  lifecycle {
    precondition {
      condition     = !(var.aks_create_cluster_identity && var.aks_cluster_identity_id != "")
      error_message = "Set only one of aks_create_cluster_identity or aks_cluster_identity_id (mutually exclusive)."
    }
  }
}
