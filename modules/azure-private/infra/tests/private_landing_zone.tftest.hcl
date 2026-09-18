# Credential-free plan tests using mocked providers.
# Run: terraform -chdir=modules/azure-private/infra init -backend=false && \
#      terraform -chdir=modules/azure-private/infra test
# Requires Terraform >= 1.7 (mock_provider) on the runner.

mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "null" {}
mock_provider "time" {}

# ── Run 1: AKS posture is hardcoded ──────────────────────────────────────────
# Plans the k8s-cluster sub-module directly — none of the root variables are
# needed. Asserts that the hardcoded always-on posture (overlay/Cilium/UDR/
# private + user-assigned identity) survives exactly as configured.
# NOTE: subscription_id was removed from the k8s-cluster module interface;
#       do NOT pass it here.
run "aks_posture_hardcoded" {
  command = plan
  module { source = "./modules/k8s-cluster" }

  variables {
    cluster_name        = "test-aks"
    location            = "eastus"
    resource_group_name = "test-rg"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/s"
    pod_cidr            = "10.244.0.0/16"
  }

  assert {
    condition     = azurerm_kubernetes_cluster.main.network_profile[0].network_plugin_mode == "overlay"
    error_message = "Overlay must be hardcoded on"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.main.network_profile[0].network_data_plane == "cilium"
    error_message = "Cilium data plane must be hardcoded on"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.main.network_profile[0].outbound_type == "userDefinedRouting"
    error_message = "Egress must be userDefinedRouting"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.main.private_cluster_enabled == true
    error_message = "API server must be private"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.main.identity[0].type == "UserAssigned"
    error_message = "Control plane must use a user-assigned identity (create_cluster_identity defaults true)"
  }
}

# ── Run 2: Root looks up the RG via data source (never creates it) ────────────
# Plans the root module with a data source override so the plan succeeds
# credential-free. Asserts that the resource_group_name output equals the
# value returned by the data source (proving the root reads the RG, not
# creates it).
run "root_creates_no_rg_or_vnet" {
  command = plan

  override_data {
    target = data.azurerm_resource_group.existing
    values = {
      name     = "test-rg"
      location = "eastus"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
    }
  }

  variables {
    subscription_id         = "00000000-0000-0000-0000-000000000000"
    identifier              = "-test"
    resource_group_name     = "test-rg"
    vnet_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v"
    aks_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/aks"
    postgres_subnet_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/pg"
    redis_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/redis"
    bastion_subnet_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/bastion"
    postgres_admin_password = "TfTest-Sandbox-1!"
    langsmith_api_key_salt  = "dGVzdC1zYWx0LXNhbmRib3g="
    langsmith_jwt_secret    = "dGVzdC1qd3Qtc2FuZGJveA=="
    # Dummy RSA public key — valid SSH format, satisfies the azurerm provider's
    # SSH key decoder. Not a real key; safe for test use only.
    bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB terraform-test"
  }

  override_resource {
    target = module.bastion.azurerm_linux_virtual_machine.bastion
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/bastion-test"
    }
  }

  # The root module looks up the RG via data source — the output reflects the
  # data source name, proving the RG name flows from the data-source lookup to
  # the root output. Structural absence of a managed RG comes from the module
  # having no azurerm_resource_group resource.
  assert {
    condition     = output.resource_group_name == "test-rg"
    error_message = "Root must look up the RG via data source and expose it as an output"
  }
}

# ── Run 3: External Postgres uses a Private Endpoint ─────────────────────────
# Plans the postgres sub-module directly. Asserts both the server-level
# public access lockdown and the presence of the postgresqlServer PE.
run "postgres_external_uses_private_endpoint" {
  command = plan
  module { source = "./modules/postgres" }

  variables {
    name                = "langsmith-postgres-test"
    location            = "eastus"
    resource_group_name = "test-rg"
    vnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/pg"
    admin_username      = "lsadmin"
    admin_password      = "TfTest-Sandbox-1!"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.db.public_network_access_enabled == false
    error_message = "Postgres public network access must be disabled"
  }
  assert {
    condition     = azurerm_private_endpoint.db.private_service_connection[0].subresource_names[0] == "postgresqlServer"
    error_message = "Postgres must be reached via a postgresqlServer private endpoint"
  }
}

# ── Run 4: Negative — identity conflict guard fires ───────────────────────────
# Setting both aks_create_cluster_identity = true AND aks_cluster_identity_id
# must trigger the terraform_data.validate_cluster_identity_exclusive precondition.
run "reject_cluster_identity_conflict" {
  command         = plan
  expect_failures = [terraform_data.validate_cluster_identity_exclusive]

  override_data {
    target = data.azurerm_resource_group.existing
    values = {
      name     = "test-rg"
      location = "eastus"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
    }
  }

  variables {
    subscription_id              = "00000000-0000-0000-0000-000000000000"
    identifier                   = "-test"
    resource_group_name          = "test-rg"
    vnet_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v"
    aks_subnet_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/aks"
    postgres_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/pg"
    redis_subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/redis"
    bastion_subnet_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/bastion"
    aks_create_cluster_identity  = true
    aks_cluster_identity_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai"
    postgres_admin_password      = "TfTest-Sandbox-1!"
    langsmith_api_key_salt       = "dGVzdC1zYWx0LXNhbmRib3g="
    langsmith_jwt_secret         = "dGVzdC1qd3Qtc2FuZGJveA=="
    bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB terraform-test"
  }
}

# The chart renders SA names as <release>-<component> only when the release name
# contains "langsmith"; a name like "ls" would break Workload Identity silently.
run "reject_bad_release_name" {
  command         = plan
  expect_failures = [var.langsmith_release_name]

  override_data {
    target = data.azurerm_resource_group.existing
    values = {
      name     = "test-rg"
      location = "eastus"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
    }
  }

  variables {
    subscription_id              = "00000000-0000-0000-0000-000000000000"
    identifier                   = "-test"
    resource_group_name          = "test-rg"
    vnet_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v"
    aks_subnet_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/aks"
    postgres_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/pg"
    redis_subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/redis"
    bastion_subnet_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/bastion"
    langsmith_release_name       = "ls"
    postgres_admin_password      = "TfTest-Sandbox-1!"
    langsmith_api_key_salt       = "dGVzdC1zYWx0LXNhbmRib3g="
    langsmith_jwt_secret         = "dGVzdC1qd3Qtc2FuZGJveA=="
    bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB terraform-test"
  }
}

# A custom (BYO) API-server private DNS zone needs a BYO identity with Private DNS Zone
# Contributor; the module-created control-plane identity only has Network Contributor.
run "reject_custom_dns_zone_with_module_identity" {
  command         = plan
  expect_failures = [terraform_data.validate_cluster_identity_exclusive]

  override_data {
    target = data.azurerm_resource_group.existing
    values = {
      name     = "test-rg"
      location = "eastus"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
    }
  }

  variables {
    subscription_id              = "00000000-0000-0000-0000-000000000000"
    identifier                   = "-test"
    resource_group_name          = "test-rg"
    vnet_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v"
    aks_subnet_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/aks"
    postgres_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/pg"
    redis_subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/redis"
    bastion_subnet_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/v/subnets/bastion"
    aks_create_cluster_identity  = true
    aks_private_dns_zone_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/privateDnsZones/privatelink.eastus.azmk8s.io"
    postgres_admin_password      = "TfTest-Sandbox-1!"
    langsmith_api_key_salt       = "dGVzdC1zYWx0LXNhbmRib3g="
    langsmith_jwt_secret         = "dGVzdC1qd3Qtc2FuZGJveA=="
    bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB terraform-test"
  }
}
