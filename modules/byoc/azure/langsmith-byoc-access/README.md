# LangSmith BYOC - Azure Access

Gives the LangSmith control plane access to **your Azure subscription**, so that it can deploy BYOC data planes. Each data plane gets one dedicated resource group. The LangSmith access stops at that resource group. The module never gives LangSmith access to the whole subscription.

This module creates these resources:

| Resource | Count | Purpose |
|----------|-------|---------|
| Service principal of the LangSmith multi-tenant Entra app | One per tenant | The consent step. The app gets no Microsoft Graph permissions. |
| Resource group `langsmith-byoc-<key>` | One per data plane | LangSmith deploys the data plane into this resource group. |
| Key Vault `ls-<key>-<suffix>` | One per data plane | Holds the 2 secrets that LangSmith writes. No public network access. |
| `Contributor` and `User Access Administrator` role assignments | Two per data plane | Give the LangSmith service principal access to that resource group only. |

> **WARNING:** LangSmith deletes the whole resource group when you delete the data plane. The resource group must contain only the Key Vault from this module when you create the data plane in LangSmith. Do not put other resources in it.

## Prerequisites

1. An Azure subscription for the LangSmith data planes.
2. Azure credentials with the `Owner` role on that subscription. The module creates role assignments, and the provider registers resource providers for the subscription.
3. An Entra ID role that can create a service principal for a multi-tenant app, for example `Cloud Application Administrator`.
4. Terraform `>= 1.11.0`, the AzureRM provider `>= 4.42.0, < 5.0.0`, and the AzureAD provider `~> 3.0`.
5. The client ID of the LangSmith multi-tenant app. LangChain gives you this value. Use it as `langsmith_app_client_id`.
6. The external ID from **Settings > Data Planes** in the LangSmith UI. Copy this value and use it as `external_id`. Do not make your own value. LangSmith compares it with the description of each role assignment to verify that you own the subscription.

## Usage

### As a root module

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.42.0, < 5.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  subscription_id = "<subscription-id>"
  features {}

  # The LangSmith data plane needs these resource providers. The provider
  # registers each one that is not registered yet, and skips the others.
  resource_providers_to_register = [
    "Microsoft.Cache",
    "Microsoft.Compute",
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
  description = "External ID from Settings > Data Planes in the LangSmith UI."
  type        = string
}

module "langsmith_byoc_access" {
  source = "github.com/langchain-ai/terraform//modules/byoc/azure/langsmith-byoc-access?ref=main"

  langsmith_app_client_id = "<langsmith-app-client-id>"
  external_id             = var.external_id

  data_planes = {
    prod = {
      location = "eastus"
    }
  }

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

output "langsmith_byoc_access" {
  value = module.langsmith_byoc_access
}
```

Before you apply, set the input in the `terraform.tfvars` file of your root module. Replace the placeholder with the value from **Settings > Data Planes**:

```hcl
external_id = "<external-id-copied-from-langsmith>"
```

We recommend that you keep the Terraform state in remote storage, not only on a local workstation.

### Resource providers

The `resource_providers_to_register` list in the `azurerm` provider block registers the resource providers that the data plane needs. LangSmith cannot register them, because its roles stop at the resource group. The provider registers only the resource providers that are not registered yet. On a subscription where all of them are registered, this step changes nothing.

Keep the list also when you set `resource_provider_registrations`. The list adds to that set.

The module does not use the `azurerm_resource_provider_registration` resource. That resource fails on a resource provider that is already registered. It also unregisters the resource provider on destroy.

### Create the data plane in LangSmith

After `terraform apply`, read the outputs:

```bash
terraform output -json langsmith_byoc_access
```

Send this body to the LangSmith API to create the data plane. The example uses the data plane key `prod` as `name`. `vpc_cidr` is the VNet that LangSmith creates: a private range from `/16` to `/18`.

```json
{
  "name": "prod",
  "region": "<data_planes.prod.region>",
  "azure_entra_tenant_id": "<azure_entra_tenant_id>",
  "resource_group_id": "<data_planes.prod.resource_group_id>",
  "vpc_cidr": "10.80.0.0/16"
}
```

This `jq` command makes the body from the outputs:

```bash
terraform output -json langsmith_byoc_access | jq --arg dp prod '{
  name: $dp,
  region: .data_planes[$dp].region,
  azure_entra_tenant_id: .azure_entra_tenant_id,
  resource_group_id: .data_planes[$dp].resource_group_id,
  vpc_cidr: "10.80.0.0/16"
}'
```

### Delete a data plane

> **CAUTION:** Do not remove the key from `data_planes` before you delete the data plane in LangSmith. Terraform then tries to delete a resource group that contains the data plane. With the default `features {}`, the AzureRM provider stops the delete.

1. Delete the data plane in LangSmith. LangSmith deletes the resource group and all its contents.
2. Remove the key from `data_planes`.
3. Run `terraform apply` to remove the rest of that data plane from the Terraform state.

## Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `langsmith_app_client_id` | `string` | yes | - | Client ID of the LangSmith multi-tenant Entra app. LangChain gives you this value. |
| `external_id` | `string` | yes | - | External ID from **Settings > Data Planes** in LangSmith. Must not be empty. The module writes it as the description of each LangSmith role assignment. |
| `data_planes` | `map(object({ location = string, tags = optional(map(string), {}) }))` | no | `{}` | Map of data planes. The key is the data plane name. Each data plane gets the resource group `langsmith-byoc-<key>` with only a Key Vault in it. LangSmith deletes the whole resource group when you delete the data plane. |
| `key_vault_purge_protection_enabled` | `bool` | no | `true` | Enables purge protection on each data plane Key Vault. |
| `tags` | `map(string)` | no | `{}` | Tags for all resource groups and Key Vaults. The `tags` of a data plane override these tags. |

A `data_planes` key must have 1 to 63 characters. Use only lowercase letters, digits, and hyphens. Start the key with a letter. End the key with a letter or a digit. Do not use two hyphens in sequence. These rules keep the resource group name and the Key Vault name valid.

## Outputs

| Output | Description |
|--------|-------------|
| `azure_entra_tenant_id` | Entra tenant ID of the subscription. |
| `data_planes` | Map of data plane key to `resource_group_id`, `region`, and `key_vault_name`. |

## Security model

### Service principal

The module creates the service principal of the LangSmith multi-tenant app in your tenant. This is the consent step. The app gets no Microsoft Graph permissions and no role on the subscription. Its only access is the role assignments on the data plane resource groups.

### Role assignments

The LangSmith service principal gets `Contributor` and `User Access Administrator` on each data plane resource group, and on nothing else. The data plane Crossplane compositions create role assignments, one custom role definition with the resource group as its scope, and management locks. `Contributor` alone cannot do these operations.

The description of each role assignment is the `external_id`. LangSmith reads this description to verify that the owner of the subscription is the LangSmith organization with that external ID.

### Key Vault

The LangSmith control plane writes 2 secrets into the Key Vault through Azure Resource Manager. The data plane reads them through a private endpoint that LangSmith creates. Thus the vault needs no public access:

- Azure RBAC authorization is on. The vault has no access policies.
- Public network access is off. The network ACL denies all traffic and has no trusted service bypass.
- Soft delete keeps a deleted vault for 90 days.
- Purge protection is on by default (`key_vault_purge_protection_enabled`). With purge protection, nobody can purge a deleted vault. The vault name stays reserved for the 90 day retention period. A random suffix in the name lets a new data plane get a new vault name.

Terraform writes nothing into the vault. Do not add other secrets to it.

## Operational notes

- Run `terraform apply` with credentials in the **target** tenant and subscription. The `tenant_id` output and the subscription in each `resource_group_id` come from these credentials.
- `use_existing = true` adopts the LangSmith service principal if it is already in your tenant, for example after an earlier admin consent. `terraform destroy` deletes that service principal in all cases.
- When you remove this module, Terraform deletes the service principal and all role assignments. LangSmith then loses access to all data planes. Speak with LangChain before you destroy.

## License

Apache 2.0 - see the repository [LICENSE](../../../../LICENSE).
