# Actions of the LangSmith custom role. reduced_access picks one of the two
# lists. The role applies only within one data plane resource group. Role
# assignments and the custom blob role of the data plane are
# Microsoft.Authorization actions; they come from the User Access
# Administrator assignment in data_planes.tf, which exists only with full
# access.
#
# Azure checks the join, assign, and approval actions on the linked resource
# when LangSmith creates a resource that uses it. The activity log does not
# show these checks, but a create fails without them.
locals {
  # Full access (reduced_access = false): create, update, and delete a data
  # plane. Teardown keeps the resource group, so the role cannot delete it.
  langsmith_byoc_actions = concat(local.langsmith_byoc_update_actions, [
    "Microsoft.ContainerService/managedClusters/delete",

    "Microsoft.Network/virtualNetworks/delete",
    "Microsoft.Network/virtualNetworks/subnets/delete",
    "Microsoft.Network/networkSecurityGroups/delete",
    "Microsoft.Network/applicationSecurityGroups/delete",
    "Microsoft.Network/natGateways/delete",
    "Microsoft.Network/publicIPAddresses/delete",
    "Microsoft.Network/privateEndpoints/delete",
    "Microsoft.Network/dnsZones/delete",
    "Microsoft.Network/privateDnsZones/delete",

    "Microsoft.DBforPostgreSQL/flexibleServers/delete",
    "Microsoft.DBforPostgreSQL/flexibleServers/databases/delete",
    "Microsoft.DBforPostgreSQL/flexibleServers/administrators/delete",

    "Microsoft.Cache/redisEnterprise/delete",
    "Microsoft.Cache/redisEnterprise/databases/delete",

    "Microsoft.Storage/storageAccounts/delete",
    # Shared key access is off on the data plane accounts, but the Crossplane
    # storage provider lists the keys while it creates them. A running data
    # plane does not need this action.
    "Microsoft.Storage/storageAccounts/listKeys/action",
    "Microsoft.Storage/storageAccounts/blobServices/containers/delete",
    "Microsoft.Storage/storageAccounts/managementPolicies/delete",

    "Microsoft.ManagedIdentity/userAssignedIdentities/delete",
  ])

  # Reduced access (reduced_access = true): keep a running data plane up to
  # date. It cannot delete a data plane, its data stores, or its network, and
  # it cannot create or delete role assignments or federated credentials.
  langsmith_byoc_reduced_actions = [
    for action in local.langsmith_byoc_update_actions : action
    if !contains(local.langsmith_byoc_reduced_removed_actions, action)
  ]

  # A new federated credential gives a new token issuer access to an identity.
  # Upgrades that add a workload service account need full access.
  langsmith_byoc_reduced_removed_actions = [
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/delete",
  ]

  # The actions that create and update a data plane. The order of the action
  # lists is part of the role definition, so a reorder changes every role.
  langsmith_byoc_update_actions = [
    "*/read",

    # AKS
    "Microsoft.ContainerService/managedClusters/write",
    # Crossplane reads the kubeconfig of the cluster on each reconcile.
    "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
    "Microsoft.ContainerService/managedClusters/agentPools/write",
    "Microsoft.ContainerService/managedClusters/agentPools/delete",
    "Microsoft.ContainerService/managedClusters/agentPools/upgradeNodeImageVersion/action",
    "Microsoft.ContainerService/managedClusters/maintenanceConfigurations/write",
    "Microsoft.ContainerService/managedClusters/maintenanceConfigurations/delete",
    # The control plane approves its private endpoint to the AKS API.
    "Microsoft.ContainerService/managedClusters/privateEndpointConnections/write",

    # Network
    "Microsoft.Network/virtualNetworks/write",
    "Microsoft.Network/virtualNetworks/join/action",
    "Microsoft.Network/virtualNetworks/subnets/write",
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.Network/networkSecurityGroups/write",
    "Microsoft.Network/networkSecurityGroups/join/action",
    # The private endpoint subnet uses one application security group per
    # endpoint kind (PostgreSQL, Redis, HTTPS). The network security group
    # rules name the groups, and each private endpoint joins one.
    "Microsoft.Network/applicationSecurityGroups/write",
    "Microsoft.Network/applicationSecurityGroups/joinIpConfiguration/action",
    "Microsoft.Network/applicationSecurityGroups/joinNetworkSecurityRule/action",
    "Microsoft.Network/natGateways/write",
    "Microsoft.Network/natGateways/join/action",
    "Microsoft.Network/publicIPAddresses/write",
    "Microsoft.Network/publicIPAddresses/join/action",
    "Microsoft.Network/privateEndpoints/write",
    "Microsoft.Network/privateEndpoints/privateDnsZoneGroups/write",
    "Microsoft.Network/privateEndpoints/privateDnsZoneGroups/delete",
    "Microsoft.Network/dnsZones/write",
    "Microsoft.Network/dnsZones/A/write",
    "Microsoft.Network/dnsZones/A/delete",
    "Microsoft.Network/dnsZones/SOA/write",
    "Microsoft.Network/privateDnsZones/write",
    "Microsoft.Network/privateDnsZones/join/action",
    "Microsoft.Network/privateDnsZones/A/write",
    "Microsoft.Network/privateDnsZones/A/delete",
    "Microsoft.Network/privateDnsZones/SOA/write",
    "Microsoft.Network/privateDnsZones/virtualNetworkLinks/write",
    "Microsoft.Network/privateDnsZones/virtualNetworkLinks/delete",

    # PostgreSQL
    "Microsoft.DBforPostgreSQL/flexibleServers/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/restart/action",
    "Microsoft.DBforPostgreSQL/flexibleServers/configurations/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/databases/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/administrators/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/privateEndpointConnectionsApproval/action",
    "Microsoft.DBforPostgreSQL/flexibleServers/privateEndpointConnections/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/privateEndpointConnections/delete",

    # Managed Redis
    "Microsoft.Cache/redisEnterprise/write",
    "Microsoft.Cache/redisEnterprise/databases/write",
    # Azure checks redisEnterprise/databases/accessPolicyAssignments/write and
    # /delete, but does not list them, so a role definition cannot name them.
    # These patterns match them and the listed Azure Cache for Redis actions.
    "Microsoft.Cache/*/accessPolicyAssignments/write",
    "Microsoft.Cache/*/accessPolicyAssignments/delete",
    "Microsoft.Cache/redisEnterprise/PrivateEndpointConnectionsApproval/action",
    "Microsoft.Cache/redisEnterprise/privateEndpointConnections/write",
    "Microsoft.Cache/redisEnterprise/privateEndpointConnections/delete",

    # Storage
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Storage/storageAccounts/blobServices/write",
    "Microsoft.Storage/storageAccounts/blobServices/containers/write",
    "Microsoft.Storage/storageAccounts/managementPolicies/write",
    "Microsoft.Storage/storageAccounts/PrivateEndpointConnectionsApproval/action",
    "Microsoft.Storage/storageAccounts/privateEndpointConnections/write",
    "Microsoft.Storage/storageAccounts/privateEndpointConnections/delete",

    # The registry that in-cluster deployment builds push to. LangSmith keeps
    # it when builds are turned off, so the role cannot delete it.
    "Microsoft.ContainerRegistry/registries/write",

    # Managed identities
    "Microsoft.ManagedIdentity/userAssignedIdentities/write",
    "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/delete",

    # Key Vault. The control plane writes the data plane secrets through ARM.
    # The role has no Key Vault data actions, so it cannot read them.
    "Microsoft.KeyVault/vaults/secrets/write",
    "Microsoft.KeyVault/vaults/PrivateEndpointConnectionsApproval/action",
    "Microsoft.KeyVault/vaults/privateEndpointConnections/write",
    "Microsoft.KeyVault/vaults/privateEndpointConnections/delete",
  ]

  # With byo_iam the customer creates and deletes the identities, so the role
  # loses these actions. It keeps assign/action, and with full access the
  # federated credential actions: the AKS OIDC issuer exists only after cluster
  # creation, so LangSmith writes the federated identity credentials.
  langsmith_byoiam_removed_actions = [
    "Microsoft.ManagedIdentity/userAssignedIdentities/write",
    "Microsoft.ManagedIdentity/userAssignedIdentities/delete",
  ]
}
