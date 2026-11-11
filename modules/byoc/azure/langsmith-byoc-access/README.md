# LangSmith BYOC - Azure Access

This module gives the LangSmith control plane access to **your Azure subscription**, so that it can deploy BYOC data planes. Each data plane has its own resource group. LangSmith has access only to that resource group, never to the whole subscription.

| Resource | Count | Purpose |
|----------|-------|---------|
| Service principal of the LangSmith multi-tenant Entra app | One per tenant | The consent step. It has no Microsoft Graph permissions. |
| Resource group `langsmith-byoc-<key>` | One per data plane | LangSmith deploys the data plane here. |
| Key Vault `ls-<key>-<suffix>` | One per data plane | Holds the secret that LangSmith writes. No public network access. |
| Custom role `langsmith-byoc-<key>-<suffix>` | One per data plane | The actions that LangSmith needs in the resource group. `reduced_access` selects full or reduced actions. |
| Role assignments: the custom role, and `User Access Administrator` with full access only | One or two per data plane | Give LangSmith access to the resource group only. |
| VNet flow log `langsmith-byoc-<key>` (optional) | One per data plane with `flow_logs` | Records the data plane network traffic in your storage account. |

> **WARNING:** Use each resource group only for its data plane. Do not put other resources in it. LangSmith can change and delete resources in it. The resource group must have only one Key Vault, the one from this module.

## Prerequisites

1. An Azure subscription for the data planes.
2. Azure credentials with `Owner` on that subscription. The module creates roles and role assignments, and the provider registers resource providers.
3. An Entra ID role that can create a service principal for a multi-tenant app, for example `Cloud Application Administrator`.
4. Terraform `>= 1.11.0`, the AzureRM provider `>= 4.42.0, < 5.0.0`, and the AzureAD provider `~> 3.0`.
5. The client ID of the LangSmith multi-tenant app: `5b0a74cb-9f37-4797-b557-c15d7be80d3b`.
6. The external ID from **Settings > Data Planes** in LangSmith. LangSmith compares it with the description of each role assignment to verify that you own the subscription.

## Usage

```hcl
provider "azurerm" {
  subscription_id = "<subscription-id>"
  features {}

  # LangSmith cannot register resource providers, because its roles stop at
  # the resource group.
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

The module creates these identities with the names that LangSmith expects:

| Identity | Role | Scope |
|---|---|---|
| `langsmith-aks-identity` | Network Contributor | resource group |
| `langsmith-aks-identity` | Managed Identity Operator | `langsmith-kubelet-identity` |
| `langsmith-kubelet-identity` | AcrPull | resource group |
| `langsmith-deployment-builds-identity` | AcrPush | resource group |
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

The blob role is `langsmith-byoc-<key>-blob-<suffix>`. Each condition limits an identity to its containers.

Some scopes are the resource group, because the resources do not exist yet:

- **Deployment builds:** the AcrPull and AcrPush rows. LangSmith gives the kubelet identity to the AKS cluster only when it creates the cluster. A data plane from before these rows cannot pull deployment builds.
- **[Deployment observability](#turn-on-deployment-observability-optional):** the Log Analytics Reader, Monitoring Data Reader, and Monitoring Metrics Publisher rows. `Log Analytics Reader` includes `*/read` on the resource group.

With `byo_iam`, LangSmith does not get these permissions:

| Permission | Reason |
|---|---|
| `User Access Administrator` | You create the role assignments. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/write` | You create the identities. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/delete` | You delete the identities. |

LangSmith still creates the federated identity credentials, because they need the AKS OIDC issuer.

### Reduce access after deployment

When the data plane is active, set `reduced_access = true`. Then run `terraform apply`:

```hcl
data_planes = {
  prod = { location = "eastus", reduced_access = true }
}
```

The apply takes approximately 10 minutes. LangSmith can still upgrade, scale, and repair the data plane.

With `reduced_access`, LangSmith does not have these permissions:

| Area | Permissions |
|---|---|
| Role assignments | `User Access Administrator` |
| PostgreSQL | `flexibleServers/administrators/write` |
| Redis | `*/accessPolicyAssignments/write` |
| Storage | `storageAccounts/listKeys/action` |
| Managed identities | `userAssignedIdentities/write`, `userAssignedIdentities/delete`, `federatedIdentityCredentials/write`, `federatedIdentityCredentials/delete` |

LangSmith cannot give a principal access to an identity or a data store. It cannot read storage keys.

#### Combine with `byo_iam`

You can use `reduced_access = true` with `byo_iam = true`:

```hcl
data_planes = {
  prod = { location = "eastus", byo_iam = true, reduced_access = true }
}
```

`reduced_access` then also removes the federated identity credential, PostgreSQL administrator, Redis access policy, and storage key actions.

Set `reduced_access = false` before you:

- delete or re-create the data plane.
- apply an upgrade that adds or changes an identity, a role assignment, a federated identity credential, a PostgreSQL administrator, or a Redis access policy. LangChain tells you when an upgrade needs this.
- turn deployment builds or deployment observability on or off.

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

Deployment observability shows charts and log history for each LangGraph deployment in LangSmith. The data stays in the data plane resource group.

1. Register `Microsoft.Insights`, `Microsoft.Monitor`, `Microsoft.OperationalInsights`, and `Microsoft.OperationsManagement` (see [Usage](#usage)).
2. Keep `reduced_access = false`.
3. Set `deployment_observability = true`. Then run `terraform apply`:

   ```hcl
   data_planes = {
     prod = { location = "eastus", deployment_observability = true }
   }
   ```

4. Ask LangSmith to turn on observability for the data plane.

> **CAUTION:** Before you remove the setting, ask LangSmith to turn off observability or delete the data plane. The role needs its delete actions to remove the rules, the endpoint, and the association.

LangSmith creates these resources in the data plane resource group:

- **Logs:** a Log Analytics workspace, and Container Insights on the AKS cluster. Its data collection rule keeps only the LangGraph deployment and build container logs, without environment variables. The default retention is 30 days, with a maximum of 730. Log Analytics bills ingestion and retention after 31 days.
- **Metrics:** an Azure Monitor workspace, a data collection endpoint and rule, and a collector identity that can publish only through that rule. A collector in the cluster sends deployment pod, CPU, memory, and kube-state-metrics data through the rule. Azure Monitor bills each sample. Azure also creates the managed resource group `MA_<workspace>_<region>_managed`.
- **Reads:** the workload identity gets `Log Analytics Reader` on the Log Analytics workspace and `Monitoring Data Reader` on the Azure Monitor workspace only.

The setting adds these actions to the custom role:

| Access | Added actions |
|---|---|
| Full and reduced | `Microsoft.OperationalInsights/workspaces/write`, `Microsoft.OperationalInsights/workspaces/sharedKeys/action`, `Microsoft.OperationsManagement/solutions/write`, `Microsoft.Monitor/accounts/write`, `Microsoft.Insights/dataCollectionEndpoints/write`, `Microsoft.Insights/dataCollectionRules/write`, `Microsoft.Insights/dataCollectionRuleAssociations/write` |
| Full only | `Microsoft.Insights/dataCollectionEndpoints/delete`, `Microsoft.Insights/dataCollectionRules/delete`, `Microsoft.Insights/dataCollectionRuleAssociations/delete` |

Azure checks `workspaces/sharedKeys/action` when a data collection rule sends logs to the workspace. It checks both that action and `solutions/write` when AKS turns on Container Insights. The shared keys can write to the workspace, but cannot query it.

With `byo_iam`, you create the collector identity and its role assignments (see [Bring your own identities](#bring-your-own-identities-optional)).

When LangSmith turns off observability, it deletes the rules, the endpoint, the collector, the collector identity, and the role assignments. With `byo_iam`, it keeps your identity and role assignments. It always keeps both workspaces, their data, and the Container Insights add-on. The add-on collects nothing without its rule.

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

Terraform creates a VNet flow log for the data plane VNet. Azure writes the logs to your storage account. LangSmith has no access to the flow log or the storage account.

- Use a storage account in the data plane region.
- If the storage account has a firewall, allow trusted Microsoft services.
- The default `retention_days` is 30.
- Terraform uses the Network Watcher of the region. To use a different watcher, set `network_watcher_name` and `network_watcher_resource_group_name`.

Remove `flow_logs` before you delete the data plane.

### Remove a data plane

> **CAUTION:** Delete the data plane in LangSmith before you remove its entry. LangSmith needs its role assignments to delete the resources.

1. Set `reduced_access = false` and remove `flow_logs`. Run `terraform apply`. Wait 5 minutes.
2. Delete the data plane in LangSmith.
3. LangSmith keeps the resource group, the Key Vault, the trace and SmithDB storage accounts, the deployment builds registry, and the observability workspaces. A new data plane with the same name uses them again.
4. Delete the storage accounts, the registry, and the workspaces when you do not need the data. The Azure Monitor workspace deletion also deletes its managed resource group.
5. Remove the entry from `data_planes`. Run `terraform apply`.

> **NOTE:** The AzureRM provider does not delete a resource group that has resources that Terraform does not manage. Do step 4 before step 5.

## Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `langsmith_app_client_id` | `string` | yes | - | Client ID of the LangSmith multi-tenant Entra app. |
| `external_id` | `string` | yes | - | External ID from **Settings > Data Planes**. It must not be empty. |
| `data_planes` | `map(object)` | no | `{}` | One entry per data plane. The key is the data plane name. |
| `tags` | `map(string)` | no | `{}` | Tags for all resource groups and Key Vaults. The data plane `tags` override them. |

Fields of each `data_planes` entry:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `location` | `string` | yes | - | Azure region of the data plane. |
| `tags` | `map(string)` | no | `{}` | Tags for this data plane. They override the module `tags`. |
| `reduced_access` | `bool` | no | `false` | Reduce LangSmith access after the data plane is active. See [Reduce access after deployment](#reduce-access-after-deployment). |
| `byo_iam` | `bool` | no | `false` | Create the identities and role assignments yourself. See [Bring your own identities](#bring-your-own-identities-optional). |
| `engine_foundry_resource_id` | `string` | no | `null` | Azure AI Foundry resource ID for Engine. See [Let Engine use Azure AI Foundry](#let-engine-use-azure-ai-foundry-optional). |
| `deployment_observability` | `bool` | no | `false` | Let LangSmith turn on deployment observability. See [Turn on deployment observability](#turn-on-deployment-observability-optional). |
| `flow_logs` | `object` | no | `null` | `storage_account_id`, `retention_days` (30), and optional `network_watcher_name` and `network_watcher_resource_group_name`. See [Turn on flow logs](#turn-on-flow-logs-optional). |

A `data_planes` key has 1 to 63 lowercase letters, digits, and hyphens. It starts with a letter, ends with a letter or a digit, and has no consecutive hyphens.

## Outputs

| Output | Description |
|--------|-------------|
| `azure_entra_tenant_id` | Entra tenant ID of the subscription. |
| `data_planes` | Map of data plane key to `resource_group_id`, `region`, and `key_vault_name`. |

## Security model

- **Service principal:** the consent step. No Microsoft Graph permissions and no role on the subscription.
- **Role assignments:** only on each data plane resource group. The custom role ([`roles.tf`](roles.tf)) and, with full access, `User Access Administrator`. The data plane uses it to create role assignments for its identities and one custom blob role. The description of each assignment is the `external_id`.
- **Key Vault:** Azure RBAC authorization, no public network access, a network ACL that denies all traffic with no bypass, soft delete for 90 days, and purge protection. A random suffix gives a new data plane a new vault name. Terraform writes nothing to the vault.

## Operational notes

- Run `terraform apply` with credentials in the **target** tenant and subscription.
- When you remove this module, Terraform deletes the service principal and all role assignments. LangSmith then loses access to all data planes. Speak with LangChain before you destroy.
- A tenant has only one LangSmith service principal. If more than one root module in a tenant uses this module, a destroy of one root module deletes the service principal for all of them.

## License

Apache 2.0 - see the repository [LICENSE](../../../../LICENSE).
