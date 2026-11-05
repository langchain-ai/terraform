# LangSmith BYOC - Azure Access

Gives the LangSmith control plane access to **your Azure subscription**, so that it can deploy BYOC data planes. Each data plane gets one dedicated resource group. The LangSmith access stops at that resource group. The module never gives LangSmith access to the whole subscription.

| Resource | Count | Purpose |
|----------|-------|---------|
| Service principal of the LangSmith multi-tenant Entra app | One per tenant | The consent step. The app gets no Microsoft Graph permissions. |
| Resource group `langsmith-byoc-<key>` | One per data plane | LangSmith deploys the data plane into this resource group. |
| Key Vault `ls-<key>-<suffix>` | One per data plane | Holds the secret that LangSmith writes. No public network access. |
| Custom role `langsmith-byoc-<key>-<suffix>` | One per data plane | The actions that LangSmith needs in that resource group. `reduced_access` selects full or reduced actions. The role can only be assigned in that resource group. |
| Role assignments: the LangSmith custom role, and `User Access Administrator` with full access only | One or two per data plane | Give the LangSmith service principal access to that resource group only. |
| VNet flow log `langsmith-byoc-<key>` (optional) | One per data plane with `flow_logs` | Records the network traffic of the data plane VNet in your storage account. |

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

The `data_planes` map holds one entry per data plane. The key is the data plane name.

### Add a data plane

1. Add an entry to `data_planes` and run `terraform apply`.
2. Make the create request body from the outputs, and send it to the LangSmith API. `vpc_cidr` is the VNet that LangSmith creates: a private range from `/16` to `/18`.

```bash
terraform output -json langsmith_byoc_access | jq --arg dp prod '{
  name: $dp,
  region: .data_planes[$dp].region,
  azure_entra_tenant_id: .azure_entra_tenant_id,
  resource_group_id: .data_planes[$dp].resource_group_id,
  vpc_cidr: "10.80.0.0/16"
}'
```

### Reduce access after deployment

When the data plane is active, set `reduced_access = true` and run `terraform apply`:

```hcl
data_planes = {
  prod = { location = "eastus", reduced_access = true }
}
```

Terraform then updates the actions of the LangSmith custom role in place and deletes the `User Access Administrator` assignment. The custom role assignment stays, so LangSmith keeps access. With reduced access, LangSmith keeps the data plane up to date: upgrades, scaling, and repairs. It cannot delete the data plane, its databases, its storage accounts, or its network, and it cannot create or delete role assignments. The apply takes about 10 minutes, because Terraform waits until Azure shows the changed role.

Set `reduced_access = false` again before an upgrade that adds a role assignment. LangChain tells you when an upgrade needs this.

### Turn on flow logs

When the data plane is active, set `flow_logs` and run `terraform apply`:

```hcl
data_planes = {
  prod = {
    location  = "eastus"
    flow_logs = { storage_account_id = "<storage-account-id>" }
  }
}
```

Terraform creates a VNet flow log for the data plane VNet in the default Network Watcher of the region (`NetworkWatcher_<location>` in `NetworkWatcherRG`). The storage account is yours, in the same region. `retention_days` defaults to 30. LangSmith gets no access to the flow log or the storage account.

### Remove a data plane

> **CAUTION:** Do not remove the entry from `data_planes` before you delete the data plane in LangSmith. LangSmith needs its role assignments to delete the data plane resources.

1. If the data plane has `reduced_access = true`, set it to `false`. If it has `flow_logs`, remove them. Run `terraform apply`. Wait 5 minutes for Azure to apply the role change.
2. Delete the data plane in LangSmith. LangSmith deletes the AKS cluster, PostgreSQL, Redis, the sandbox storage, the network, and the private DNS zones. It keeps the resource group, the Key Vault, the Blob storage accounts with trace and SmithDB data, and, if in-cluster deployment builds were on, the container registry with the built images. A new data plane with the same name reuses them.
3. When you no longer need the retained data, delete the Blob storage accounts and the container registry in the resource group.
4. Remove the entry from `data_planes` and run `terraform apply`. Terraform deletes the resource group, the Key Vault, the custom role, and the role assignments. With the default `features {}`, the AzureRM provider refuses to delete a resource group that still contains resources Terraform does not manage, such as the retained storage accounts and registry.

## Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `langsmith_app_client_id` | `string` | yes | - | Client ID of the LangSmith multi-tenant Entra app. |
| `external_id` | `string` | yes | - | External ID from **Settings > Data Planes**. Must not be empty. |
| `data_planes` | `map(object({ location = string, tags = optional(map(string), {}), reduced_access = optional(bool, false), flow_logs = optional(object({ storage_account_id = string, retention_days = optional(number, 30) })) }))` | no | `{}` | One entry per data plane. The key is the data plane name. |
| `tags` | `map(string)` | no | `{}` | Tags for all resource groups and Key Vaults. The `tags` of a data plane override these tags. |

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
