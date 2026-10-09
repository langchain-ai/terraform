# ingress_load_balancer = "internal": the annotations each controller gets, the
# Istio add-on's gateway switch, the grant on a separate load-balancer subnet,
# and every rule that refuses a combination that cannot work. The network is
# the byo_network fixture (a supplied VNet with a supplied AKS subnet), so the
# same-VNet rule on ingress_load_balancer_subnet_id can be checked at plan.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
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

# A /18 holds the default carve prefixes (10.0.0.0/19, 10.0.32.0/20 and
# 10.0.48.0/20) and stops short of 10.0.64.0/20, the create-path ClusterIP
# default, so leaving aks_service_cidr empty trips only the rule requiring it.
# In the default location, so only a run that moves it trips the region rule.
override_data {
  target = data.azurerm_virtual_network.byo_vnet
  values = {
    address_space = ["10.0.0.0/18"]
    location      = "eastus"
  }
}

# A supplied AKS subnet that already carries both service endpoints, sized for
# the default node-subnet pools.
override_data {
  target = data.azurerm_subnet.byo_aks_subnet
  values = {
    address_prefixes  = ["10.0.0.0/19"]
    service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
  }
}

override_data {
  target = data.azapi_resource.byo_postgres_subnet
  values = {
    output = {
      properties = {
        delegations = [{ name = "postgres", properties = { serviceName = "Microsoft.DBforPostgreSQL/flexibleServers" } }]
      }
    }
  }
}

override_data {
  target = data.azapi_resource.byo_agic_subnet_delegations
  values = {
    output = {
      properties = {
        delegations = [{ name = "agw", properties = { serviceName = "Microsoft.Network/applicationGateways" } }]
      }
    }
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"

  create_vnet      = false
  vnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
  aks_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"
  aks_service_cidr = "10.100.0.0/16"
  aks_network_mode = "node-subnet"
  postgres_source  = "external"
  redis_source     = "external"

  # HTTP-01 is refused behind an internal load balancer, so every run that
  # sets "internal" needs a source that works there, and a hostname.
  tls_certificate_source = "none"
  langsmith_domain       = "langsmith.internal.example.com"
}

# ── Annotations and gateways ─────────────────────────────────────────────────

run "public_is_the_default_and_adds_no_internal_annotation" {
  command = plan

  variables {
    ingress_controller = "nginx"
  }

  assert {
    condition     = output.ingress_load_balancer == "public"
    error_message = "ingress_load_balancer no longer defaults to public"
  }
  assert {
    condition     = !contains(keys(module.aks.nginx_service_annotations), "service.beta.kubernetes.io/azure-load-balancer-internal")
    error_message = "The default public load balancer was annotated internal"
  }
  assert {
    condition     = output.ingress_load_balancer_subnet_grant == null
    error_message = "A public load balancer planned a subnet grant"
  }
}

run "internal_nginx_gets_the_subnet_and_ip_annotations" {
  command = plan

  variables {
    ingress_controller              = "nginx"
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = "${var.vnet_id}/subnets/ingress"
    ingress_load_balancer_ip        = "10.0.40.10"
  }

  assert {
    condition     = module.aks.nginx_service_annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    error_message = "ingress_load_balancer = internal did not make the NGINX Service internal"
  }
  assert {
    # The annotation takes the subnet's name, not its resource ID.
    condition     = module.aks.nginx_service_annotations["service.beta.kubernetes.io/azure-load-balancer-internal-subnet"] == "ingress"
    error_message = "The internal-subnet annotation is not the subnet's name"
  }
  assert {
    condition     = module.aks.nginx_service_annotations["service.beta.kubernetes.io/azure-load-balancer-ipv4"] == "10.0.40.10"
    error_message = "ingress_load_balancer_ip did not reach the ipv4 annotation"
  }
  assert {
    # The health-probe annotation the controller always had stays.
    condition     = module.aks.nginx_service_annotations["service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path"] == "/nginx-health"
    error_message = "The internal annotations replaced NGINX's health-probe annotation"
  }
  assert {
    condition     = output.ingress_load_balancer_subnet_grant.made_by == "terraform" && output.ingress_load_balancer_subnet_grant.scope == "${var.vnet_id}/subnets/ingress"
    error_message = "A load-balancer subnet other than the node subnet did not plan the cluster identity's grant there"
  }
}

run "internal_on_the_node_subnet_needs_no_grant" {
  command = plan

  variables {
    ingress_controller              = "nginx"
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = var.aks_subnet_id
  }

  assert {
    condition     = output.ingress_load_balancer_subnet_grant == null
    error_message = "The node subnet was given an extra grant for the internal load balancer"
  }
}

# A carved node subnet has no ID before apply, so the grant decision matches it
# by name. vnet_name sets the carved subnet's name to shared-vnet-subnet-0.
run "internal_on_a_carved_node_subnet_needs_no_grant" {
  command = plan

  variables {
    ingress_controller              = "nginx"
    aks_subnet_id                   = ""
    vnet_name                       = "shared-vnet"
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = "${var.vnet_id}/subnets/shared-vnet-subnet-0"
  }

  assert {
    condition     = output.ingress_load_balancer_subnet_grant == null
    error_message = "The carved node subnet was given an extra grant for the internal load balancer"
  }
}

run "internal_beside_a_carved_node_subnet_gets_the_grant" {
  command = plan

  variables {
    ingress_controller              = "nginx"
    aks_subnet_id                   = ""
    vnet_name                       = "shared-vnet"
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = "${var.vnet_id}/subnets/ingress"
  }

  assert {
    condition     = output.ingress_load_balancer_subnet_grant.made_by == "terraform"
    error_message = "A load-balancer subnet beside a carved node subnet did not plan the grant"
  }
}

run "the_subnet_grant_can_be_left_to_the_network_owner" {
  command = plan

  variables {
    ingress_controller                             = "nginx"
    ingress_load_balancer                          = "internal"
    ingress_load_balancer_subnet_id                = "${var.vnet_id}/subnets/ingress"
    ingress_load_balancer_manage_subnet_assignment = false
  }

  assert {
    condition     = output.ingress_load_balancer_subnet_grant.made_by == "owner"
    error_message = "ingress_load_balancer_manage_subnet_assignment = false did not hand the grant to the owner"
  }
  assert {
    condition     = contains(output.ingress_load_balancer_subnet_grant.actions, "Microsoft.Network/virtualNetworks/subnets/join/action")
    error_message = "The listed grant does not name the join action the load balancer needs"
  }
}

run "internal_with_no_subnet_or_ip_is_only_the_internal_annotation" {
  # deploy.sh writes this output into the EnvoyProxy, so it is what Envoy
  # Gateway's proxy Service gets. It must not carry a subnet or IP nobody
  # asked for.
  command = plan

  variables {
    ingress_controller    = "envoy-gateway"
    ingress_load_balancer = "internal"
  }

  assert {
    condition     = length(output.ingress_internal_annotations) == 1 && output.ingress_internal_annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    error_message = "With no subnet or IP, the internal annotation set is not exactly azure-load-balancer-internal"
  }
}

run "internal_envoy_gateway_gets_the_subnet_and_ip_annotations" {
  command = plan

  variables {
    ingress_controller              = "envoy-gateway"
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = "${var.vnet_id}/subnets/ingress"
    ingress_load_balancer_ip        = "10.0.40.10"
  }

  assert {
    condition     = output.ingress_internal_annotations["service.beta.kubernetes.io/azure-load-balancer-internal-subnet"] == "ingress" && output.ingress_internal_annotations["service.beta.kubernetes.io/azure-load-balancer-ipv4"] == "10.0.40.10"
    error_message = "The annotations deploy.sh gives the EnvoyProxy do not carry the subnet's name and the IP"
  }
}

run "public_envoy_gateway_gets_no_annotations" {
  command = plan

  variables {
    ingress_controller = "envoy-gateway"
  }

  assert {
    condition     = length(output.ingress_internal_annotations) == 0
    error_message = "The default public load balancer has internal annotations for the EnvoyProxy"
  }
}

run "internal_self_managed_istio_annotates_its_gateway" {
  command = plan

  variables {
    ingress_controller              = "istio"
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = "${var.vnet_id}/subnets/ingress"
  }

  assert {
    condition     = yamldecode(module.aks.istio_gateway_values[0]).service.annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    error_message = "ingress_load_balancer = internal did not make the self-managed Istio gateway's Service internal"
  }
  assert {
    condition     = yamldecode(module.aks.istio_gateway_values[0]).service.annotations["service.beta.kubernetes.io/azure-load-balancer-internal-subnet"] == "ingress"
    error_message = "The self-managed Istio gateway's internal-subnet annotation is not the subnet's name"
  }
}

run "public_self_managed_istio_keeps_today_s_gateway" {
  command = plan

  variables {
    ingress_controller = "istio"
  }

  assert {
    condition     = module.aks.istio_gateway_values != null && length(module.aks.istio_gateway_values) == 0
    error_message = "The default changed the self-managed Istio gateway's values"
  }
}

run "istio_addon_internal_turns_the_public_gateway_off" {
  command = plan

  variables {
    create_vnet           = true
    vnet_id               = ""
    aks_subnet_id         = ""
    ingress_controller    = "istio-addon"
    ingress_load_balancer = "internal"
  }

  assert {
    condition     = module.aks.istio_addon_gateways.internal && !module.aks.istio_addon_gateways.external
    error_message = "ingress_load_balancer = internal did not switch the Istio add-on to its internal gateway only"
  }
}

run "istio_addon_public_keeps_today_s_gateways" {
  command = plan

  variables {
    create_vnet        = true
    vnet_id            = ""
    aks_subnet_id      = ""
    ingress_controller = "istio-addon"
  }

  assert {
    condition     = module.aks.istio_addon_gateways.external && !module.aks.istio_addon_gateways.internal
    error_message = "The default changed the Istio add-on's gateways"
  }
}

# ── Combinations that cannot work ────────────────────────────────────────────

run "internal_is_refused_with_agic" {
  command = plan
  variables {
    # AGIC on the supplied fixture network wants its own subnet; a carved VNet
    # keeps the failure to the rule under test.
    create_vnet           = true
    vnet_id               = ""
    aks_subnet_id         = ""
    ingress_controller    = "agic"
    ingress_load_balancer = "internal"
  }
  expect_failures = [var.ingress_load_balancer]
}

run "internal_is_refused_with_no_controller" {
  command = plan
  variables {
    ingress_controller    = "none"
    ingress_load_balancer = "internal"
  }
  expect_failures = [var.ingress_load_balancer]
}

run "internal_is_refused_with_a_dns_label" {
  command = plan
  variables {
    ingress_load_balancer = "internal"
    dns_label             = "langsmith-fixture"
  }
  expect_failures = [var.ingress_load_balancer]
}

run "internal_is_refused_with_http01" {
  command = plan
  variables {
    ingress_load_balancer  = "internal"
    tls_certificate_source = "letsencrypt"
    letsencrypt_email      = "fixture@example.com"
  }
  expect_failures = [var.ingress_load_balancer]
}

run "a_subnet_needs_internal" {
  command = plan
  variables {
    ingress_load_balancer_subnet_id = "${var.vnet_id}/subnets/ingress"
  }
  expect_failures = [var.ingress_load_balancer_subnet_id]
}

run "a_subnet_outside_the_cluster_vnet_is_refused" {
  command = plan
  variables {
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/other-vnet/subnets/ingress"
  }
  expect_failures = [var.ingress_load_balancer_subnet_id]
}

run "a_subnet_must_be_a_resource_id" {
  command = plan
  variables {
    ingress_load_balancer           = "internal"
    ingress_load_balancer_subnet_id = "ingress"
  }
  expect_failures = [var.ingress_load_balancer_subnet_id]
}

run "an_ip_needs_internal" {
  command = plan
  variables {
    ingress_load_balancer_ip = "10.0.40.10"
  }
  expect_failures = [var.ingress_load_balancer_ip]
}

run "an_ip_must_be_ipv4" {
  command = plan
  variables {
    ingress_load_balancer    = "internal"
    ingress_load_balancer_ip = "10.0.40"
  }
  expect_failures = [var.ingress_load_balancer_ip]
}

run "an_ipv6_address_is_refused" {
  command = plan
  variables {
    ingress_load_balancer    = "internal"
    ingress_load_balancer_ip = "fd00::10"
  }
  expect_failures = [var.ingress_load_balancer_ip]
}

run "a_public_dns_zone_warns_with_internal" {
  command = plan
  variables {
    ingress_load_balancer = "internal"
    create_dns_zone       = true
    langsmith_domain      = "langsmith.example.com"
    ingress_ip            = "10.0.40.10"
  }
  expect_failures = [check.dns_zone_with_internal_ingress]
}

run "dns01_with_internal_plans_without_a_warning" {
  # DNS-01 needs the zone for cert-manager's challenge record. With no
  # ingress_ip there is no A record, so nothing private is published.
  command = plan
  variables {
    ingress_load_balancer  = "internal"
    create_dns_zone        = true
    langsmith_domain       = "langsmith.example.com"
    tls_certificate_source = "dns01"
    letsencrypt_email      = "fixture@example.com"
  }

  assert {
    condition     = length(module.dns) == 1
    error_message = "dns01 with an internal load balancer did not plan the DNS zone"
  }
}

run "internal_with_no_hostname_warns" {
  command = plan
  variables {
    ingress_load_balancer = "internal"
    langsmith_domain      = ""
  }
  expect_failures = [check.internal_ingress_hostname]
}

# ── Grant principal with a user-assigned control plane ───────────────────────

# With aks_control_plane_identity = "user" the cluster reports no
# system-assigned principal, so the subnet grant must go to the control-plane
# identity's principal rather than to an empty one.
override_resource {
  target          = module.aks.azurerm_user_assigned_identity.control_plane
  override_during = plan
  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane"
    principal_id = "66666666-6666-6666-6666-666666666666"
  }
}

run "a_user_assigned_control_plane_gets_the_subnet_grant" {
  command = plan

  variables {
    ingress_controller                       = "nginx"
    ingress_load_balancer                    = "internal"
    ingress_load_balancer_subnet_id          = "${var.vnet_id}/subnets/ingress"
    aks_control_plane_identity               = "user"
    aks_control_plane_identity_manage_grants = true
  }

  assert {
    condition     = output.ingress_load_balancer_subnet_grant.principal_id == "66666666-6666-6666-6666-666666666666"
    error_message = "With a user-assigned control plane, the subnet grant did not go to the control-plane identity's principal"
  }
  assert {
    condition     = output.ingress_load_balancer_subnet_grant.made_by == "terraform"
    error_message = "The managed subnet grant was not marked as made by Terraform"
  }
}

# An attached cluster with a user-assigned control-plane identity reports no
# principal on identity[0], so the grant reads it from the identity it names.
run "an_attached_user_assigned_control_plane_gets_the_subnet_grant" {
  command = plan

  override_data {
    target = module.aks.data.azurerm_kubernetes_cluster.existing
    values = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-aks-rg/providers/Microsoft.ContainerService/managedClusters/platform-aks"
      location            = "eastus"
      oidc_issuer_enabled = true
      kube_config         = [{ host = "https://platform-aks.example", client_certificate = "", client_key = "", cluster_ca_certificate = "" }]
      agent_pool_profile = [
        { name = "system", vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks" },
      ]
      identity = [{
        type         = "UserAssigned"
        principal_id = ""
        tenant_id    = ""
        identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/platform-aks-control-plane"]
      }]
    }
  }
  override_data {
    target = module.aks.data.azapi_resource.existing_security_profile
    values = {
      output = { properties = { securityProfile = { workloadIdentity = { enabled = true } } } }
    }
  }
  override_data {
    target = module.aks.data.azurerm_user_assigned_identity.existing_control_plane
    values = {
      principal_id = "77777777-7777-7777-7777-777777777777"
    }
  }

  variables {
    create_cluster                       = false
    existing_cluster_name                = "platform-aks"
    existing_cluster_resource_group_name = "platform-aks-rg"
    ingress_controller                   = "nginx"
    ingress_load_balancer                = "internal"
    ingress_load_balancer_subnet_id      = "${var.vnet_id}/subnets/ingress"
  }

  assert {
    condition     = output.ingress_load_balancer_subnet_grant.principal_id == "77777777-7777-7777-7777-777777777777"
    error_message = "On an attached cluster with a user-assigned control plane, the subnet grant did not go to that identity's principal"
  }
}
