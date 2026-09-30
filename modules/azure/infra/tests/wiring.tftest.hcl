# Conditional wiring in the Azure root: every optional module, asserted in both
# directions. mock_provider means no cloud credentials, no state, and no API
# calls, so these run in the PR path.
#
# Each run sets the variable it asserts on rather than relying on the default,
# so a default change shows up as a failing assertion here and not as a test
# that quietly stops covering anything.

# Fixed client_config so the Key Vault run below can compare the deployer's
# object_id by value. The generated mock is a random string.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# The cluster module lists the subscription's AKS clusters to read the one it
# manages; the generated mock has no such shape, so give it an empty list.
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [] }
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
  # Throwaway keypair, generated for this fixture and the private half discarded.
  # create_bastion = true with the empty default fails inside azurerm's own
  # schema validator rather than at a precondition on the root variable.
  bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLvAeJ8tG7HNaDGXt2T05HJmj1X1qaP+jb2MTDRBLNEPOwsvT7UrCsGp/8AB5MZIyMmRLoNOz1GTRWWBQsgQoKJD1jPUJNvSDZ16g4yFV4wX2o6nxooi53U9L6JWH6XrXn2Ozhca7tC0o26Oyd2toFrf8An8H8Gnwsdr3EOIrqvL0ZxXvjgGLZDx9auENfrlrhob8+6QLsZkEzphDWqKhbYpy46WEYtwHvKRpYX1YlDN6jbObN0wifqu98UZNsIr7FoZR3luNj1bA/kjqUC61GW6UziPyCoMhk3Jf9IMQ24OBXn2Xp4JWMZ3jYp+IL1fi9YVgofvsOvlYM2XGtmgzt plan-tests-fixture"
}

# ── Optional modules, off ────────────────────────────────────────────────────

run "optional_modules_absent_when_flags_are_false" {
  command = plan

  variables {
    create_waf         = false
    create_diagnostics = false
    create_bastion     = false
    create_dns_zone    = false
  }

  assert {
    condition     = length(module.waf) == 0
    error_message = "create_waf = false still planned the waf module"
  }
  assert {
    condition     = length(module.diagnostics) == 0
    error_message = "create_diagnostics = false still planned the diagnostics module"
  }
  assert {
    condition     = length(module.bastion) == 0
    error_message = "create_bastion = false still planned the bastion module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "create_dns_zone = false still planned the dns module"
  }
}

# ── Optional modules, on ─────────────────────────────────────────────────────
# One run per flag. A single run with everything on would pass while three of
# the four flags were wired to the same variable.

run "create_waf_adds_only_the_waf" {
  command = plan

  variables {
    create_waf = true
  }

  assert {
    condition     = length(module.waf) == 1
    error_message = "create_waf = true did not plan the waf module"
  }
  assert {
    condition     = length(module.diagnostics) == 0
    error_message = "create_waf = true also planned diagnostics"
  }
}

run "create_diagnostics_adds_only_diagnostics" {
  command = plan

  variables {
    create_diagnostics = true
  }

  assert {
    condition     = length(module.diagnostics) == 1
    error_message = "create_diagnostics = true did not plan the diagnostics module"
  }
  assert {
    condition     = length(module.waf) == 0
    error_message = "create_diagnostics = true also planned the waf"
  }
}

run "create_dns_zone_adds_only_dns" {
  command = plan

  variables {
    create_dns_zone  = true
    langsmith_domain = "langsmith.example.com"
  }

  assert {
    condition     = length(module.dns) == 1
    error_message = "create_dns_zone = true did not plan the dns module"
  }
  assert {
    condition     = length(module.bastion) == 0
    error_message = "create_dns_zone = true also planned the bastion"
  }
}

run "create_bastion_adds_only_bastion" {
  command = plan

  variables {
    create_bastion = true
  }

  assert {
    condition     = length(module.bastion) == 1
    error_message = "create_bastion = true did not plan the bastion module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "create_bastion = true also planned the dns zone"
  }
}

# ── Data plane source switches ───────────────────────────────────────────────
# in-cluster means the chart runs it, so Terraform must plan nothing.

run "external_postgres_is_planned" {
  command = plan

  variables {
    postgres_source = "external"
  }

  assert {
    condition     = length(module.postgres) == 1
    error_message = "postgres_source = external did not plan the flexible server"
  }
}

run "in_cluster_postgres_plans_nothing" {
  command = plan

  variables {
    postgres_source = "in-cluster"
  }

  assert {
    condition     = length(module.postgres) == 0
    error_message = "postgres_source = in-cluster still planned a flexible server"
  }
}

run "external_redis_is_planned" {
  command = plan

  variables {
    redis_source = "external"
  }

  assert {
    condition     = length(module.redis) == 1
    error_message = "redis_source = external did not plan Azure Managed Redis"
  }
}

run "in_cluster_redis_plans_nothing" {
  command = plan

  variables {
    redis_source = "in-cluster"
  }

  assert {
    condition     = length(module.redis) == 0
    error_message = "redis_source = in-cluster still planned Azure Managed Redis"
  }
}

# ── AKS network mode, data plane and tier ────────────────────────────────────
# What reaches the cluster resource from the one operator-facing mode variable.

run "overlay_mode_plans_cilium_and_the_pod_range" {
  command = plan

  variables {
    aks_network_mode = "overlay"
  }

  assert {
    condition     = module.aks.network_profile.network_plugin_mode == "overlay"
    error_message = "aks_network_mode = overlay did not set network_plugin_mode = overlay"
  }
  assert {
    condition     = module.aks.network_profile.pod_cidr == "10.244.0.0/16"
    error_message = "overlay mode did not pass aks_pod_cidr through as pod_cidr"
  }
  assert {
    condition     = module.aks.network_profile.network_data_plane == "cilium"
    error_message = "overlay mode did not default the data plane to cilium"
  }
  assert {
    condition     = module.aks.network_profile.network_policy == "cilium"
    error_message = "the cilium data plane did not select the cilium policy engine"
  }
  assert {
    condition     = module.aks.sku_tier == "Standard"
    error_message = "the default tier is not Standard"
  }
}

run "overlay_mode_can_keep_the_azure_data_plane" {
  command = plan

  variables {
    aks_network_mode      = "overlay"
    aks_network_dataplane = "azure"
  }

  assert {
    condition     = module.aks.network_profile.network_data_plane == "azure"
    error_message = "aks_network_dataplane = azure was overridden"
  }
  assert {
    condition     = module.aks.network_profile.network_policy == "azure"
    error_message = "the azure data plane did not select the azure policy engine"
  }
}

run "node_subnet_mode_plans_the_flat_profile" {
  command = plan

  variables {
    aks_network_mode = "node-subnet"
  }

  assert {
    condition     = module.aks.network_profile.network_plugin_mode == null
    error_message = "node-subnet mode set a network_plugin_mode"
  }
  assert {
    condition     = module.aks.network_profile.network_data_plane == "azure"
    error_message = "node-subnet mode did not keep the azure data plane"
  }
  assert {
    condition     = module.aks.network_profile.network_policy == "azure"
    error_message = "node-subnet mode did not keep the azure policy engine"
  }
}

run "premium_tier_with_long_term_support_is_passed_through" {
  command = plan

  variables {
    aks_sku_tier     = "Premium"
    aks_support_plan = "AKSLongTermSupport"
  }

  assert {
    condition     = module.aks.sku_tier == "Premium" && module.aks.support_plan == "AKSLongTermSupport"
    error_message = "tier and support plan did not reach the cluster"
  }
}

# ── Node OS SKU ──────────────────────────────────────────────────────────────
# The default stays Ubuntu so no existing pool moves. A pool with no os_sku of
# its own follows aks_os_sku; one that sets it keeps its own.

run "os_sku_defaults_to_ubuntu" {
  command = plan

  variables {
    aks_os_sku = "Ubuntu"
    additional_node_pools = {
      large = { vm_size = "Standard_D16s_v3", min_count = 0, max_count = 2 }
    }
  }

  assert {
    condition     = module.aks.default_node_pool_os_sku == "Ubuntu" && module.aks.node_pool_os_skus["large"] == "Ubuntu"
    error_message = "aks_os_sku = Ubuntu did not reach the default and additional pools"
  }
}

run "os_sku_azure_linux_with_a_pool_override" {
  command = plan

  variables {
    aks_os_sku = "AzureLinux"
    additional_node_pools = {
      large  = { vm_size = "Standard_D16s_v3", min_count = 0, max_count = 2 }
      ubuntu = { vm_size = "Standard_D8s_v3", min_count = 0, max_count = 1, os_sku = "Ubuntu2204" }
    }
  }

  assert {
    condition     = module.aks.default_node_pool_os_sku == "AzureLinux"
    error_message = "aks_os_sku did not reach the default pool"
  }

  assert {
    condition     = module.aks.node_pool_os_skus["large"] == "AzureLinux"
    error_message = "a pool with no os_sku did not follow aks_os_sku"
  }

  assert {
    condition     = module.aks.node_pool_os_skus["ubuntu"] == "Ubuntu2204"
    error_message = "a pool's own os_sku was overridden by aks_os_sku"
  }
}

# ── AGIC with overlay ────────────────────────────────────────────────────────
# Nothing has confirmed Application Gateway reaching overlay pod addresses, so the
# pairing warns (a check, not a precondition) and the plan proceeds.

run "agic_with_overlay_warns" {
  command = plan

  variables {
    ingress_controller = "agic"
    aks_network_mode   = "overlay"
  }

  expect_failures = [check.agic_with_overlay_unverified]
}
# ── Key Vault deployer grant ─────────────────────────────────────────────────
# module.keyvault carries a module-level depends_on, which defers every data
# source inside it while any dependency has changes pending. Read there, the
# deployer's object_id is unknown at plan time and the grant plans as a replace
# whenever module.blob changes. Read in the root, it is known.

run "keyvault_deployer_grant_principal_known_at_plan" {
  command = plan

  variables {
    create_keyvault                            = true
    keyvault_manage_terraform_admin_assignment = true
  }

  assert {
    condition     = module.keyvault.terraform_admin_principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "The Key Vault deployer grant's principal_id is not the client_config object_id at plan time"
  }
}

# ── Blob private DNS zone ────────────────────────────────────────────────────
# Azure links a zone name to a VNet once, so a supplied central zone must stop
# Terraform creating a second one.

run "storage_private_endpoints_create_the_blob_zone" {
  command = plan

  variables {
    storage_private_endpoint_enabled = true
    storage_private_dns_zone_id      = ""
  }

  assert {
    condition     = length(azurerm_private_dns_zone.blob) == 1 && length(azurerm_private_dns_zone_virtual_network_link.blob) == 1
    error_message = "storage_private_endpoint_enabled = true with no zone supplied did not plan the blob zone and its VNet link"
  }
}

run "a_supplied_blob_zone_is_not_created_again" {
  command = plan

  variables {
    storage_private_endpoint_enabled = true
    storage_private_dns_zone_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  }

  assert {
    condition     = length(azurerm_private_dns_zone.blob) == 0 && length(azurerm_private_dns_zone_virtual_network_link.blob) == 0
    error_message = "A supplied storage_private_dns_zone_id still planned a second blob zone"
  }
}

# ── Workload Identity subjects follow the chart's fullname ───────────────────
# The chart prefixes its service accounts with its fullname: the release name
# when it contains "langsmith", otherwise <release>-langsmith. The federated
# credential subjects have to match, or every blob-reading pod loses its identity.

run "wi_subjects_default_release_name" {
  command = plan

  variables {
    langsmith_release_name = "langsmith"
  }

  assert {
    condition     = contains(module.aks.workload_identity_service_accounts, "langsmith-backend") && contains(module.aks.workload_identity_service_accounts, "langsmith-queue")
    error_message = "the default release name did not give langsmith-<component> subjects"
  }
}

run "wi_subjects_release_name_without_langsmith" {
  command = plan

  variables {
    langsmith_release_name = "prod"
  }

  assert {
    condition = alltrue([
      for sa in ["prod-langsmith-backend", "prod-langsmith-platform-backend", "prod-langsmith-queue", "prod-langsmith-ingest-queue"] :
      contains(module.aks.workload_identity_service_accounts, sa)
    ])
    error_message = "release \"prod\" did not give prod-langsmith-<component> subjects: ${join(", ", module.aks.workload_identity_service_accounts)}"
  }

  assert {
    condition     = !contains(module.aks.workload_identity_service_accounts, "prod-backend")
    error_message = "release \"prod\" still produced the bare prod-backend subject"
  }
}

# ── Resource group ───────────────────────────────────────────────────────────
# Attaching reads the group instead of creating it, and every resource placed
# in it takes the attached name.

run "the_resource_group_is_created_by_default" {
  command = plan

  variables {
    create_resource_group = true
    resource_group_name   = "langsmith-rg-wiring"
  }

  assert {
    condition     = length(azurerm_resource_group.resource_group) == 1 && length(data.azurerm_resource_group.existing) == 0
    error_message = "create_resource_group = true did not plan exactly the resource group resource"
  }
  assert {
    condition     = output.resource_group_name == "langsmith-rg-wiring"
    error_message = "the resource_group_name output is not the created group's name"
  }
}

run "an_existing_resource_group_is_read_not_created" {
  command = plan

  variables {
    create_resource_group            = false
    existing_resource_group_name     = "platform-langsmith-rg"
    storage_private_endpoint_enabled = true
    storage_private_dns_zone_id      = ""
  }

  # azapi parses the group's ID as Redis's parent, and the generated mock is a
  # random string.
  override_data {
    target = data.azurerm_resource_group.existing
    values = {
      name = "platform-langsmith-rg"
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-langsmith-rg"
    }
  }

  assert {
    condition     = length(azurerm_resource_group.resource_group) == 0 && length(data.azurerm_resource_group.existing) == 1
    error_message = "create_resource_group = false still planned a resource group, or did not read the existing one"
  }
  assert {
    condition     = output.resource_group_name == "platform-langsmith-rg"
    error_message = "the resource_group_name output is not the attached group's name"
  }
  assert {
    condition     = azurerm_private_dns_zone.blob[0].resource_group_name == "platform-langsmith-rg"
    error_message = "resources are not placed in the attached resource group"
  }
}

# ── Subnet NSGs ──────────────────────────────────────────────────────────────

run "subnet_nsgs_are_absent_by_default" {
  command = plan

  variables {
    enable_subnet_nsgs = false
  }

  assert {
    condition     = alltrue([for rules in values(module.vnet.subnet_nsg_rules) : rules == null])
    error_message = "enable_subnet_nsgs = false still planned a subnet NSG"
  }
}

run "subnet_nsgs_admit_only_the_aks_subnet" {
  command = plan

  variables {
    enable_subnet_nsgs        = true
    aks_subnet_address_prefix = ["10.0.0.0/19"]
  }

  assert {
    condition     = alltrue([for rules in values(module.vnet.subnet_nsg_rules) : rules != null])
    error_message = "enable_subnet_nsgs = true did not plan an NSG on every created subnet"
  }
  assert {
    condition     = one([for r in module.vnet.subnet_nsg_rules.postgres : r.source_address_prefixes if r.name == "allow-aks-postgres"]) == toset(["10.0.0.0/19"])
    error_message = "the Postgres NSG does not admit exactly the AKS subnet"
  }
  assert {
    condition     = one([for r in module.vnet.subnet_nsg_rules.redis : r.source_address_prefixes if r.name == "allow-aks-redis"]) == toset(["10.0.0.0/19"])
    error_message = "the Redis NSG does not admit exactly the AKS subnet"
  }
  assert {
    condition     = one([for r in module.vnet.subnet_nsg_rules.redis : r.access if r.name == "deny-vnet-inbound"]) == "Deny"
    error_message = "the Redis NSG does not deny the rest of the VNet"
  }
  assert {
    condition = alltrue([
      for nsg in ["postgres", "redis"] :
      one([for r in module.vnet.subnet_nsg_rules[nsg] : r.priority if r.source_address_prefix == "AzureLoadBalancer" && r.access == "Allow"]) < one([for r in module.vnet.subnet_nsg_rules[nsg] : r.priority if r.name == "deny-vnet-inbound"])
    ])
    error_message = "a data-tier NSG denies Azure's platform probes ahead of admitting them"
  }
}

# ── Cluster components, both directions ──────────────────────────────────────
# The two helm_releases are count-gated inside k8s-bootstrap, so the module's
# namespace outputs are the observable: a name when this module installed the
# component, null when the cluster was expected to already run it.

run "cluster_components_installed_when_flags_are_true" {
  command = plan

  variables {
    install_cert_manager = true
    install_keda         = true
  }

  assert {
    condition     = module.k8s_bootstrap.cert_manager_namespace == "cert-manager"
    error_message = "install_cert_manager = true did not plan the cert-manager release"
  }

  assert {
    condition     = module.k8s_bootstrap.keda_namespace == "keda"
    error_message = "install_keda = true did not plan the KEDA release"
  }
}

# Envoy Gateway ships the Gateway API CRDs, and cert-manager serves Gateways
# only with its feature gate on, so the two travel together.
run "envoy_gateway_turns_on_cert_manager_gateway_api" {
  command = plan

  variables {
    ingress_controller   = "envoy-gateway"
    install_cert_manager = true
  }

  assert {
    condition     = module.aks.envoy_gateway_version != ""
    error_message = "ingress_controller = \"envoy-gateway\" did not plan the Envoy Gateway release"
  }

  assert {
    condition     = module.k8s_bootstrap.cert_manager_feature_gates == "ExperimentalGatewayAPISupport=true"
    error_message = "ingress_controller = \"envoy-gateway\" left cert-manager without Gateway API support: \"${module.k8s_bootstrap.cert_manager_feature_gates}\""
  }
}

run "nginx_leaves_cert_manager_gateway_api_off" {
  command = plan

  variables {
    ingress_controller   = "nginx"
    install_cert_manager = true
  }

  assert {
    condition     = module.aks.envoy_gateway_version == ""
    error_message = "ingress_controller = \"nginx\" still planned the Envoy Gateway release"
  }

  assert {
    condition     = module.k8s_bootstrap.cert_manager_feature_gates == ""
    error_message = "ingress_controller = \"nginx\" still set cert-manager featureGates: \"${module.k8s_bootstrap.cert_manager_feature_gates}\""
  }
}

run "omitted_ingress_controller_defaults_to_envoy_gateway" {
  command = plan

  variables {
    install_cert_manager = true
  }

  assert {
    condition     = module.aks.envoy_gateway_version != ""
    error_message = "Omitting ingress_controller did not plan the Envoy Gateway release"
  }

  assert {
    condition     = module.k8s_bootstrap.cert_manager_feature_gates == "ExperimentalGatewayAPISupport=true"
    error_message = "Omitting ingress_controller left cert-manager without Gateway API support: \"${module.k8s_bootstrap.cert_manager_feature_gates}\""
  }
}

run "cluster_components_absent_when_flags_are_false" {
  command = plan

  variables {
    install_cert_manager = false
    install_keda         = false
    # false is only reachable on the attach path, and dns01 is refused with it.
    tls_certificate_source = "letsencrypt"
    letsencrypt_email      = "fixture@example.com"
  }

  assert {
    condition     = module.k8s_bootstrap.cert_manager_namespace == null
    error_message = "install_cert_manager = false still planned the cert-manager release"
  }

  assert {
    condition     = module.k8s_bootstrap.keda_namespace == null
    error_message = "install_keda = false still planned the KEDA release"
  }
}
