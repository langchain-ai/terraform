# Actions of the two LangSmith custom roles. Both roles apply only within one
# data plane resource group. Role assignments, the custom blob role of the
# data plane, and delete locks are Microsoft.Authorization actions; they come
# from the User Access Administrator assignment in main.tf.
#
# Azure checks the join, assign, and approval actions on the linked resource
# when LangSmith creates a resource that uses it. The activity log does not
# show these checks, but a create fails without them.
locals {
  # langsmith-byoc: create, update, and delete a data plane.
  langsmith_byoc_actions = concat(local.langsmith_byoc_reduced_actions, [
    # The control plane deletes the resource group when you delete the data
    # plane. Remove this action when teardown keeps the resource group.
    "Microsoft.Resources/subscriptions/resourceGroups/delete",

    "Microsoft.ContainerService/managedClusters/delete",

    "Microsoft.Network/virtualNetworks/delete",
    "Microsoft.Network/virtualNetworks/subnets/delete",
    "Microsoft.Network/networkSecurityGroups/delete",
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

    # The control plane writes the data plane secrets once, at create.
    "Microsoft.KeyVault/vaults/secrets/write",
  ])

  # langsmith-byoc-reduced: keep a running data plane up to date. It cannot
  # delete a data plane, its data stores, or its network, and it cannot write
  # Key Vault secrets.
  langsmith_byoc_reduced_actions = [
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

    # Managed identities
    "Microsoft.ManagedIdentity/userAssignedIdentities/write",
    "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/delete",

    # Key Vault private endpoint
    "Microsoft.KeyVault/vaults/PrivateEndpointConnectionsApproval/action",
    "Microsoft.KeyVault/vaults/privateEndpointConnections/write",
    "Microsoft.KeyVault/vaults/privateEndpointConnections/delete",
  ]
}
