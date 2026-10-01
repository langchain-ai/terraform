# LangSmith BYOC - Azure Customer Identity

Creates the managed identity in **your Azure subscription** that the LangSmith control plane signs in as to create and operate a BYOC data plane.

Use a subscription that holds only the LangSmith data plane. The identity gets Contributor on the whole subscription.

## How LangSmith signs in

LangSmith has no application in your tenant, and you give no admin consent. You create the identity, and you decide what it can do.

```
Your subscription
  Managed identity "langsmith-byoc"
    federated credential:
      issuer   = the LangSmith control plane
      subject  = system:serviceaccount:crossplane-system:langsmith-byoc-azure
      audience = api://AzureADTokenExchange/<your external ID>
    roles on the subscription

LangSmith, for your organization  -> token with your audience       -> Entra accepts it
LangSmith, for another organization -> token with another audience  -> Entra refuses it
```

The audience works like the AWS `sts:ExternalId`. LangSmith takes it from the organization that sends the request, never from the request. So no other LangSmith organization can use your identity, even if it knows your tenant ID, subscription ID, and client ID.

## What the module creates

| Resource | Purpose |
|---|---|
| Resource group `langsmith-byoc-identity` | Holds the managed identity. |
| User-assigned managed identity `langsmith-byoc` | The identity that LangSmith signs in as. |
| One federated credential for each control plane issuer | Trusts the LangSmith control plane, only for your organization. |
| Custom role `LangSmith BYOC Blob Objects (<subscription ID>)` | Read a LangSmith container and read, write, or delete its blobs. LangSmith assigns it to the data plane identities. |
| Contributor on the subscription | Create and delete the data plane resources and resource groups. |
| Locks Contributor on the subscription | Add and remove the delete locks on the databases. |
| Azure Kubernetes Service RBAC Cluster Admin on the subscription | Install the LangSmith charts in the data plane AKS cluster. |
| Role Based Access Control Administrator on the subscription, with a condition | Assign only Network Contributor, Key Vault Secrets User, DNS Zone Contributor, Storage Blob Data Reader, and the custom blob role, and only to service principals. |

The condition stops the identity from giving itself or anyone else Owner, User Access Administrator, Role Based Access Control Administrator, or any other role.

## Prerequisites

1. A subscription for the LangSmith data plane only.
2. An account that can create role assignments in that subscription, for example Owner.
3. The external ID from **Settings > Data Planes** in the LangSmith UI. Do not make your own value.
4. The control plane issuer URL from LangChain.
5. These resource providers registered in the subscription: `Microsoft.ContainerService`, `Microsoft.Network`, `Microsoft.DBforPostgreSQL`, `Microsoft.Cache`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.ManagedIdentity`, and `Microsoft.Compute`. The example below registers them through `resource_provider_registrations = "extended"`.

## Usage

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.65.0, < 5.0.0"
    }
  }
}

provider "azurerm" {
  subscription_id                 = "<data plane subscription ID>"
  resource_provider_registrations = "extended"
  features {}
}

variable "langsmith_external_id" {
  description = "External ID copied from Settings > Data Planes in the LangSmith UI."
  type        = string
}

module "langsmith_byoc_identity" {
  source = "github.com/langchain-ai/terraform//modules/byoc/azure/langsmith-byoc-identity?ref=main"

  langsmith_external_id = var.langsmith_external_id
  control_plane_issuers = ["<issuer URL from LangChain>"]
  location              = "westus3"
}

output "langsmith" {
  value = {
    tenant_id                  = module.langsmith_byoc_identity.tenant_id
    subscription_id            = module.langsmith_byoc_identity.subscription_id
    managed_identity_client_id = module.langsmith_byoc_identity.managed_identity_client_id
  }
}
```

Then create the data plane in LangSmith with the three output values.

Azure can take a few minutes to apply a new federated credential or role assignment. If the first create fails with a sign-in or permission error, wait five minutes and retry.

## Change of control plane issuer

LangChain tells you before a new control plane issuer goes into use. Add the new issuer to `control_plane_issuers` and apply. Remove the old issuer after LangChain confirms the move.

## Remove access

1. Delete the data plane in LangSmith, and wait until LangSmith reports that it is deleted.
2. Run `terraform destroy` on this module.

If you delete the role assignments or the identity first, LangSmith loses access at once and cannot delete the data plane resources.

## Inputs

| Name | Description | Default |
|---|---|---|
| `langsmith_external_id` | External ID from the LangSmith UI. | required |
| `control_plane_issuers` | OIDC issuer URLs of the LangSmith control plane, 1 to 20. | required |
| `control_plane_subject` | The control plane service account that requests your tokens. | `system:serviceaccount:crossplane-system:langsmith-byoc-azure` |
| `location` | Region of the identity resource group. | required |
| `resource_group_name` | Name of the identity resource group. | `langsmith-byoc-identity` |
| `identity_name` | Name of the managed identity. | `langsmith-byoc` |
| `tags` | Tags for the resource group and the identity. | `{}` |

## Outputs

| Name | Description |
|---|---|
| `tenant_id` | Microsoft Entra tenant ID. |
| `subscription_id` | Subscription ID of the data plane. |
| `managed_identity_client_id` | Client ID of the managed identity. |
| `managed_identity_principal_id` | Object ID of the managed identity, for audit queries. |
| `blob_objects_role_name` | Name of the custom blob role. |
