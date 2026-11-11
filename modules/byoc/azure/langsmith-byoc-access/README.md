# LangSmith BYOC - Azure Access

Gives the LangSmith control plane access to **your Azure subscription**, so that it can deploy BYOC data planes. Each data plane gets one dedicated resource group. The LangSmith access stops at that resource group. The module never gives LangSmith access to the whole subscription.

| Resource | Count | Purpose |
|----------|-------|---------|
| Service principal of the LangSmith multi-tenant Entra app | One per tenant | The consent step. The app gets no Microsoft Graph permissions. |
| Resource group `langsmith-byoc-<key>` | One per data plane | LangSmith deploys the data plane into this resource group. |
| Key Vault `ls-<key>-<suffix>` | One per data plane | Holds the secret that LangSmith writes. No public network access. |
| Custom role `langsmith-byoc-<key>-<suffix>` | One per data plane | The actions that LangSmith needs in that resource group. `reduced_access` selects full or reduced actions. The role can only be assigned in that resource group. |
| Role assignments: the LangSmith custom role, and `User Access Administrator` with full access only | One or two per data plane | Give the LangSmith service principal access to that resource group only. |
| VNet flow log `langsmith-byoc-<key>` (optional) | One per data plane with `flow_logs` | Records the network traffic of the data plane in your storage account. |

> **WARNING:** Use each resource group only for its data plane. The resource group must contain exactly one Key Vault, the one from this module. LangSmith can change and delete resources in the resource group, so do not put other resources in it.

## Prerequisites

1. An Azure subscription for the LangSmith data planes.
2. Azure credentials with the `Owner` role on that subscription. The module creates custom roles and role assignments, and the provider registers resource providers.
3. An Entra ID role that can create and update a service principal for a multi-tenant app, for example `Cloud Application Administrator`.
4. Terraform `>= 1.11.0`, the AzureRM provider `>= 4.42.0, < 5.0.0`, and the AzureAD provider `~> 3.0`.
5. The client ID of the LangSmith multi-tenant app: `5b0a74cb-9f37-4797-b557-c15d7be80d3b`.
6. The external ID from **Settings > Data Planes** in the LangSmith UI. LangSmith compares it with the description of each role assignment to verify that you own the subscription.

## Usage

```hcl
provider "azurerm" {
  subscription_id = "<subscription-id>"
  features {}

  # The provider registers each resource provider that is not registered yet.
  # LangSmith cannot do this, because its roles stop at the resource group.
  resource_providers_to_register = [
    "Microsoft.Cache",
    "Microsoft.Compute",
    "Microsoft.ContainerRegistry",
    "Microsoft.ContainerService",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.Storage",
    # Only for deployment_observability.
    "Microsoft.Insights",
    "Microsoft.Monitor",
    "Microsoft.OperationalInsights",
    "Microsoft.OperationsManagement",
  ]
}

provider "azuread" {}

variable "external_id" {
  type = string
}

module "langsmith_byoc_access" {
  source = "github.com/langchain-ai/terraform//modules/byoc/azure/langsmith-byoc-access?ref=main"

  langsmith_app_client_id = "5b0a74cb-9f37-4797-b557-c15d7be80d3b"
  external_id             = var.external_id # from Settings > Data Planes

  data_planes = {
    prod = { location = "eastus" }
  }
}

output "langsmith_byoc_access" {
  value = module.langsmith_byoc_access
}
```

Keep the Terraform state in remote storage.

## Manage data planes

Each entry in `data_planes` is one data plane. The key is the data plane name.

### Add a data plane

1. Add an entry to `data_planes`.
2. Run `terraform apply`.
3. Get the IDs for the form:

   ```bash
   terraform output -json langsmith_byoc_access | jq --arg dp prod '{
     tenant_id: .azure_entra_tenant_id,
     resource_group_id: .data_planes[$dp].resource_group_id,
     region: .data_planes[$dp].region
   }'
   ```

4. In LangSmith, go to **Settings > Data Planes**. Click **+ Data Plane**.
5. Enter the name (the `data_planes` key), the region, the tenant ID, and the resource group ID.
6. Enter a VNet CIDR. Use a private range from `/16` to `/18`, for example `10.80.0.0/16`.
7. Click **Create data plane**.

### Bring your own identities (optional)

> **CAUTION:** Set `byo_iam` before you create the data plane. Do not change it later.

```hcl
data_planes = {
  prod = { location = "eastus", byo_iam = true }
}
```

In the create form, select **Use existing managed identities**.

The module creates these identities. LangSmith expects these names:

| Identity | Role | Scope |
|---|---|---|
| `langsmith-aks-identity` | Network Contributor | resource group |
| `langsmith-cert-manager-identity` | DNS Zone Contributor | resource group |
| `langsmith-external-secrets-identity` | Key Vault Secrets User | Key Vault |
| `langsmith-workload-identity` | Monitoring Reader | resource group |
| `langsmith-workload-identity` | blob role, container `langsmith` | resource group, with a condition |
| `langsmith-postgres-setup-identity` | none | - |
| `langsmith-smithdb-identity` | blob role: read `langsmith`, read and write `smithdb` | resource group, with a condition |
| `langsmith-sandbox-identity` | blob role, container `sandboxes` | resource group, with a condition |
| `langsmith-workload-identity` | Log Analytics Reader | resource group |
| `langsmith-workload-identity` | Monitoring Data Reader | resource group |
| `langsmith-deployment-metrics-collector-identity` | Monitoring Metrics Publisher | resource group |
| LangSmith application | Azure Kubernetes Service RBAC Cluster Admin | resource group |
| LangSmith application | Managed Identity Operator | `langsmith-aks-identity` |

The blob role is `langsmith-byoc-<key>-blob-<suffix>`. The conditions keep each identity to its own containers.

The `Log Analytics Reader`, `Monitoring Data Reader`, and `Monitoring Metrics Publisher` rows are for [deployment observability](#turn-on-deployment-observability-optional). LangSmith uses them only when observability is on. The workspaces and the data collection rule do not exist yet, so the scope is the resource group. `Log Analytics Reader` includes `*/read`, so the workload identity can read the resources in the resource group.

With `byo_iam`, LangSmith does not need these permissions:

| Permission | Why |
|---|---|
| `User Access Administrator` | You create the role assignments. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/write` | You create the identities. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/delete` | You delete the identities. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` | LangSmith can assign only `langsmith-aks-identity`, through `Managed Identity Operator` on that identity. |

LangSmith still creates the federated identity credentials. The AKS OIDC issuer exists only after LangSmith creates the cluster.

### Reduce access after deployment

When the data plane is active, set `reduced_access = true`. Then run `terraform apply`:

```hcl
data_planes = {
  prod = { location = "eastus", reduced_access = true }
}
```

The apply takes about 10 minutes. LangSmith can still upgrade, scale, and repair the data plane.

With `reduced_access`, LangSmith does not have these permissions:

| Area | Permissions |
|---|---|
| Role assignments | `User Access Administrator` |
| PostgreSQL | `flexibleServers/administrators/write` |
| Redis | `*/accessPolicyAssignments/write` |
| Storage | `storageAccounts/listKeys/action` |
| Managed identities | `userAssignedIdentities/write`, `userAssignedIdentities/delete`, `federatedIdentityCredentials/write`, `federatedIdentityCredentials/delete` |

LangSmith cannot give a principal access to an identity or a data store, and it cannot read storage keys.

#### Combine with `byo_iam`

You can set `reduced_access = true` on a data plane with `byo_iam = true`:

```hcl
data_planes = {
  prod = { location = "eastus", byo_iam = true, reduced_access = true }
}
```

`byo_iam` already removes `User Access Administrator` and the identity write and delete actions. `reduced_access` also removes the federated identity credential, PostgreSQL administrator, Redis access policy, and storage key actions. LangSmith then cannot change identities, role assignments, federated identity credentials, PostgreSQL administrators, or Redis access policies.

Set `reduced_access = false` again before you:

- delete or recreate the data plane.
- apply an upgrade that adds or changes an identity, or adds a role assignment, a federated identity credential, a PostgreSQL administrator, or a Redis access policy. LangChain tells you when an upgrade needs this.

[`roles.tf`](roles.tf) has the full lists.

### Let Engine use Azure AI Foundry (optional)

When the data plane is active, add the Foundry resource ID. Then run `terraform apply`:

```hcl
data_planes = {
  prod = {
    location                   = "eastus"
    engine_foundry_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ai-prod/providers/Microsoft.CognitiveServices/accounts/contoso-foundry"
  }
}
```

To get the ID, run `az cognitiveservices account show -g <resource-group> -n <foundry-resource> --query id -o tsv`.

The workload identity gets `Cognitive Services User` on that resource. Engine can then call Claude and GPT without an API key. Remove the ID before you delete the data plane.

### Turn on deployment observability (optional)

Deployment observability shows Monitoring charts and searchable runtime and build log history for each LangGraph deployment in LangSmith. The data stays in the data plane resource group. Set `deployment_observability = true`, keep `reduced_access = false`, and run `terraform apply` before LangSmith turns it on for the data plane:

```hcl
data_planes = {
  prod = { location = "eastus", deployment_observability = true }
}
```

Before you set it back to `false` or remove it, have LangSmith turn observability off or delete the data plane, because the role needs its delete actions to remove the rules, the endpoint and the association.

Register `Microsoft.Insights`, `Microsoft.Monitor`, `Microsoft.OperationalInsights` and `Microsoft.OperationsManagement` first (see [Usage](#usage)). LangSmith then creates, in the data plane resource group:

- **Logs:** a Log Analytics workspace, and Container Insights on the AKS cluster with a data collection rule that keeps only the LangGraph deployment and build container logs. Environment variables are not collected. The workspace keeps logs for 30 days unless LangSmith sets another retention, up to 730; Log Analytics bills ingestion, and retention past 31 days.
- **Metrics:** an Azure Monitor workspace, a data collection endpoint and rule, and a managed identity that may publish only through that rule. A collector in the cluster scrapes the LangGraph deployment pods, CPU and memory, and kube-state-metrics, and writes them through the rule. Azure Monitor bills per sample ingested. Azure creates the workspace's managed resource group, `MA_<workspace>_<region>_managed`, which holds its default rule and endpoint.
- **Reads:** the data plane's workload identity gets `Log Analytics Reader` on the Log Analytics workspace and `Monitoring Data Reader` on the Azure Monitor workspace, and on nothing else.

The setting adds these actions to the LangSmith custom role of that data plane:

| Access | Added actions |
|---|---|
| Full and reduced | `Microsoft.OperationalInsights/workspaces/write`, `Microsoft.OperationalInsights/workspaces/sharedKeys/action`, `Microsoft.OperationsManagement/solutions/write`, `Microsoft.Monitor/accounts/write`, `Microsoft.Insights/dataCollectionEndpoints/write`, `Microsoft.Insights/dataCollectionRules/write`, `Microsoft.Insights/dataCollectionRuleAssociations/write` |
| Full only | `Microsoft.Insights/dataCollectionEndpoints/delete`, `Microsoft.Insights/dataCollectionRules/delete`, `Microsoft.Insights/dataCollectionRuleAssociations/delete` |

Azure checks `workspaces/sharedKeys/action` on the Log Analytics workspace when a data collection rule sends logs to it, and both actions when AKS turns on Container Insights with it. The shared keys can write to the workspace but not query it. The role grants both actions only in the data plane resource group.

The role assignments for the collector and the workload identity come from the `User Access Administrator` assignment, so keep `reduced_access = false` while LangSmith turns observability on or off. You can set it to `true` again afterwards. With `byo_iam`, you create the collector identity and the role assignments (see [Bring your own identities](#bring-your-own-identities-optional)). LangSmith still creates the collector's federated identity credential, so keep `reduced_access = false` while it turns observability on.

When observability is turned off, LangSmith deletes the rules, the endpoint, the collector and its identity, and the role assignments. With `byo_iam`, it keeps your identity and role assignments. It keeps both workspaces with their data, and the Container Insights add-on, which collects nothing without its rule. The role cannot delete either workspace.

### Turn on flow logs (optional)

When the data plane is active, add your storage account. Then run `terraform apply`:

```hcl
data_planes = {
  prod = {
    location  = "eastus"
    flow_logs = { storage_account_id = "<storage-account-id>" }
  }
}
```

Terraform creates a VNet flow log for the data plane VNet. Azure writes the logs to your storage account. LangSmith gets no access to the flow log or the storage account.

- The storage account must be in the region of the data plane.
- If the storage account has a firewall, let trusted Microsoft services through.
- `retention_days` is 30 by default.
- Terraform finds the Network Watcher of the region. To use a different watcher, set `network_watcher_name` and `network_watcher_resource_group_name`.

Remove `flow_logs` before you delete the data plane.

### Remove a data plane

> **CAUTION:** Delete the data plane in LangSmith before you remove its entry. LangSmith needs its role assignments to delete the resources.

1. If `reduced_access = true`, set it to `false`. If `flow_logs` is set, remove it. Run `terraform apply`. Wait 5 minutes.
2. Delete the data plane in LangSmith.
3. LangSmith keeps the resource group, the Key Vault, and the trace and SmithDB storage accounts. With deployment builds, it also keeps the container registry. With deployment observability, it also keeps the Log Analytics and Azure Monitor workspaces. A new data plane with the same name uses them again.
4. When you do not need the data, delete the storage accounts, the registry and the workspaces. Deleting the Azure Monitor workspace also deletes its managed resource group.
5. Remove the entry from `data_planes`. Run `terraform apply`.

> **NOTE:** The AzureRM provider does not delete a resource group that contains resources that Terraform does not manage. Do step 4 before step 5.

## Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `langsmith_app_client_id` | `string` | yes | - | Client ID of the LangSmith multi-tenant Entra app. |
| `external_id` | `string` | yes | - | External ID from **Settings > Data Planes**. Must not be empty. |
| `data_planes` | `map(object)` | no | `{}` | One entry per data plane. The key is the data plane name. See the fields below. |
| `tags` | `map(string)` | no | `{}` | Tags for all resource groups and Key Vaults. The `tags` of a data plane override these tags. |

Fields of each `data_planes` entry:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `location` | `string` | yes | - | Azure region of the data plane. |
| `tags` | `map(string)` | no | `{}` | Tags for this data plane. They override the module `tags`. |
| `reduced_access` | `bool` | no | `false` | Reduced LangSmith access after the data plane is active. See [Reduce access after deployment](#reduce-access-after-deployment). |
| `byo_iam` | `bool` | no | `false` | Create the data plane identities and their role assignments yourself. See [Bring your own identities](#bring-your-own-identities-optional). |
| `engine_foundry_resource_id` | `string` | no | `null` | Azure AI Foundry resource ID that Engine can call. See [Let Engine use Azure AI Foundry](#let-engine-use-azure-ai-foundry-optional). |
| `deployment_observability` | `bool` | no | `false` | Let LangSmith turn on deployment observability for this data plane. Adds actions to its custom role. See [Turn on deployment observability](#turn-on-deployment-observability-optional). |
| `flow_logs` | `object` | no | `null` | VNet flow logs: `storage_account_id`, `retention_days` (30), and an optional `network_watcher_name` and `network_watcher_resource_group_name`. See [Turn on flow logs](#turn-on-flow-logs-optional). |

A `data_planes` key must have 1 to 63 characters: lowercase letters, digits, and hyphens. Start with a letter, end with a letter or a digit, and do not use two hyphens in sequence.

## Outputs

| Output | Description |
|--------|-------------|
| `azure_entra_tenant_id` | Entra tenant ID of the subscription. |
| `data_planes` | Map of data plane key to `resource_group_id`, `region`, and `key_vault_name`. |

## Security model

- **Service principal:** the consent step. No Microsoft Graph permissions and no role on the subscription.
- **Role assignments:** on each data plane resource group, and nothing else. The LangSmith custom role ([`roles.tf`](roles.tf) lists the full and the reduced actions). With full access, also `User Access Administrator`, because the data plane creates role assignments for its workload identities and one custom blob role. The description of each assignment is the `external_id`.
- **Key Vault:** Azure RBAC authorization, no public network access, a network ACL that denies all traffic with no bypass, soft delete for 90 days, and purge protection. A random suffix in the name lets a new data plane get a new vault name. Terraform writes nothing into the vault.

## Operational notes

- Run `terraform apply` with credentials in the **target** tenant and subscription.
- When you remove this module, Terraform deletes the service principal and all role assignments. LangSmith then loses access to all data planes. Speak with LangChain before you destroy.
- The tenant has only one LangSmith service principal. If you use this module in more than one root module of the same tenant, a destroy of one root module deletes the service principal for all of them.

## License

Apache 2.0 - see the repository [LICENSE](../../../../LICENSE).
