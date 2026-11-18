# LangSmith BYOC - Azure Access

Gives the LangSmith control plane access to deploy BYOC data planes in **your Azure subscription**. Each data plane gets one resource group, and LangSmith access stops at that resource group.

| Resource | Count | Purpose |
|----------|-------|---------|
| Service principal of the LangSmith multi-tenant Entra app | One per tenant | The consent step. No Microsoft Graph permissions. With `create_service_principal = false`, the module only reads it. |
| Resource group `langsmith-byoc-<key>` | One per data plane | LangSmith deploys the data plane into this resource group. |
| Key Vault `ls-<key>-<suffix>` | One per data plane | Holds the secret that LangSmith writes. |
| Custom role `langsmith-byoc-<key>-<suffix>` | One per data plane | The actions that LangSmith needs in that resource group. Assignable only there. |
| Role assignments: the custom role, and `User Access Administrator` with full access only | One or two per data plane | On that resource group only. |
| VNet flow log `langsmith-byoc-<key>` (optional) | One per data plane with `flow_logs` | Records the network traffic of the data plane in your storage account. |

> **WARNING:** LangSmith can change and delete all resources in the resource group. Do not put other resources in it. The resource group must contain exactly one Key Vault, the one from this module.

## Prerequisites

1. An Azure subscription.
2. `Owner`, or `Contributor` and `User Access Administrator`, on the subscription. Use subscription scope, because the module creates the resource groups. `Role Based Access Control Administrator` is not sufficient, because it cannot create custom roles. If your `User Access Administrator` grant blocks privileged roles, set `byo_iam = true` and create the identities yourself. See [Bring your own identities](#bring-your-own-identities-optional).
3. An Entra ID role that can create service principals, for example `Cloud Application Administrator`, once per tenant. If the person in step 2 does not have it, an Entra admin runs this first:

   ```bash
   az ad sp create --id 5b0a74cb-9f37-4797-b557-c15d7be80d3b
   ```

   Then set `create_service_principal = false` before the first `terraform apply`. The module only reads the service principal and needs no Entra ID permission.
4. Terraform `>= 1.11.0`, AzureRM `>= 4.42.0, < 5.0.0`, and AzureAD `~> 3.0`.
5. The external ID from **Settings > Data Planes** in LangSmith. LangSmith compares it with the description of each role assignment to verify that you own the subscription.

## Usage

```hcl
provider "azurerm" {
  subscription_id = "<subscription-id>"
  features {}

  # LangSmith cannot register resource providers. Its roles stop at the
  # resource group.
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
| `langsmith-host-backend-identity`, only with `dedicated_deployments` | dedicated deployments role, Log Analytics Reader, Monitoring Data Reader | resource group |

The blob role is `langsmith-byoc-<key>-blob-<suffix>`. Its conditions keep each identity to its own containers.

The `Log Analytics Reader`, `Monitoring Data Reader`, and `Monitoring Metrics Publisher` rows are for [deployment observability](#turn-on-deployment-observability-optional). Their scope is the resource group, because the workspaces and the rule do not exist yet. `Log Analytics Reader` includes `*/read` on the resource group.

With `byo_iam`, LangSmith does not need these permissions:

| Permission | Why |
|---|---|
| `User Access Administrator` | You create the role assignments. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/write` | You create the identities. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/delete` | You delete the identities. |

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

#### Combine with `byo_iam`

You can set `reduced_access = true` on a data plane with `byo_iam = true`:

```hcl
data_planes = {
  prod = { location = "eastus", byo_iam = true, reduced_access = true }
}
```

`byo_iam` removes `User Access Administrator` and the identity actions. `reduced_access` also removes the federated identity credential, PostgreSQL administrator, Redis access policy, and storage key actions.

Set `reduced_access = false` again, and run `terraform apply`, before:

- you delete or recreate the data plane.
- LangSmith turns CLI builds, deployment observability, or dedicated deployments on or off.
- an upgrade that adds an identity, a role assignment, a federated identity credential, a PostgreSQL administrator, or a Redis access policy. LangChain tells you when.

You can set it to `true` again afterwards. [`roles.tf`](roles.tf) has the full lists.

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

The workload identity gets `Cognitive Services User` on that resource, so Engine can call models without an API key. Remove the ID before you delete the data plane.

### Turn on deployment observability (optional)

Deployment observability shows metrics and runtime and build logs for each LangGraph deployment. The data stays in the data plane resource group. Set `deployment_observability = true` and run `terraform apply` before LangSmith turns it on:

```hcl
data_planes = {
  prod = { location = "eastus", deployment_observability = true }
}
```

Register the four observability resource providers first (see [Usage](#usage)). LangSmith then creates, in the data plane resource group:

- **Logs:** a Log Analytics workspace, and Container Insights with a data collection rule that keeps only the LangGraph deployment and build container logs, without environment variables. Retention is 30 days by default, up to 730. Log Analytics bills ingestion and retention past 31 days.
- **Metrics:** an Azure Monitor workspace, a data collection endpoint and rule, and a collector in the cluster with an identity that can publish only through that rule. Azure Monitor bills per sample. Azure also creates the managed resource group `MA_<workspace>_<region>_managed`.
- **Reads:** the workload identity gets `Log Analytics Reader` and `Monitoring Data Reader` on the two workspaces only.

The setting adds these actions to the LangSmith custom role of that data plane:

| Access | Added actions |
|---|---|
| Full and reduced | `Microsoft.OperationalInsights/workspaces/write`, `Microsoft.OperationalInsights/workspaces/sharedKeys/action`, `Microsoft.OperationsManagement/solutions/write`, `Microsoft.Monitor/accounts/write`, `Microsoft.Insights/dataCollectionEndpoints/write`, `Microsoft.Insights/dataCollectionRules/write`, `Microsoft.Insights/dataCollectionRuleAssociations/write` |
| Full only | `Microsoft.Insights/dataCollectionEndpoints/delete`, `Microsoft.Insights/dataCollectionRules/delete`, `Microsoft.Insights/dataCollectionRuleAssociations/delete` |

Azure checks `workspaces/sharedKeys/action` when a rule sends logs to the workspace and when AKS turns on Container Insights. The shared keys can write to the workspace but not query it.

With `byo_iam`, you create the collector identity and its role assignments (see [Bring your own identities](#bring-your-own-identities-optional)).

When observability is turned off, LangSmith deletes the rules, the endpoint, the collector, and the identity and role assignments that it created. It keeps both workspaces with their data. Before you set `deployment_observability` back to `false`, have LangSmith turn observability off or delete the data plane. The role needs its delete actions for that.

### Turn on dedicated deployments (optional)

Each dedicated LangGraph deployment gets its own private PostgreSQL flexible server in the data plane resource group. LangSmith creates the network and the identity that manages the servers.

With `byo_iam`, set `dedicated_deployments = true` and run `terraform apply` before LangSmith turns them on:

```hcl
data_planes = {
  prod = { location = "eastus", byo_iam = true, dedicated_deployments = true }
}
```

The module then creates `langsmith-host-backend-identity` and its roles on the resource group. The PostgreSQL role also reaches the LangSmith application database, so only host-backend and the listener can use this identity.

Before you set `dedicated_deployments` back to `false`, delete the dedicated deployments and have LangSmith turn the feature off. Otherwise their servers stay and you pay for them.

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
3. LangSmith keeps the resource group, the Key Vault, the trace and SmithDB storage accounts, and, if used, the container registry, the CLI build source storage account, and the observability workspaces. A new data plane with the same name uses them again.
4. When you do not need the data, delete the storage accounts, the registry and the workspaces. Deleting the Azure Monitor workspace also deletes its managed resource group.
5. Remove the entry from `data_planes`. Run `terraform apply`.

> **NOTE:** The AzureRM provider does not delete a resource group that contains resources that Terraform does not manage. Do step 4 before step 5.

## Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `langsmith_app_client_id` | `string` | yes | - | Client ID of the LangSmith multi-tenant Entra app. |
| `external_id` | `string` | yes | - | External ID from **Settings > Data Planes**. Must not be empty. |
| `create_service_principal` | `bool` | no | `true` | `true`: create or update the service principal (needs Entra ID permission). `false`: only read it. Do not change from `true` to `false` later, or Terraform deletes it. |
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
| `dedicated_deployments` | `bool` | no | `false` | With `byo_iam`, create `langsmith-host-backend-identity` and grant it the roles that dedicated deployments need. See [Turn on dedicated deployments](#turn-on-dedicated-deployments-optional). |
| `flow_logs` | `object` | no | `null` | VNet flow logs: `storage_account_id`, `retention_days` (30), and an optional `network_watcher_name` and `network_watcher_resource_group_name`. See [Turn on flow logs](#turn-on-flow-logs-optional). |

A `data_planes` key must have 1 to 63 characters: lowercase letters, digits, and hyphens. Start with a letter, end with a letter or a digit, and do not use two hyphens in sequence.

## Outputs

| Output | Description |
|--------|-------------|
| `azure_entra_tenant_id` | Entra tenant ID of the subscription. |
| `data_planes` | Map of data plane key to `resource_group_id`, `region`, and `key_vault_name`. |

## Security model

- **Service principal:** no Microsoft Graph permissions and no role on the subscription.
- **Role assignments:** on each data plane resource group only, with the `external_id` as description. The custom role ([`roles.tf`](roles.tf)), and with full access `User Access Administrator`. LangSmith uses it to assign roles to its workload identities, one blob role, and, with CLI builds, two custom roles and `AcrDelete`.
- **Key Vault:** Azure RBAC, no public network access, a deny-all network ACL, soft delete for 90 days, and purge protection. Terraform writes nothing into the vault.

## Operational notes

- Run `terraform apply` with credentials in the **target** tenant and subscription.
- A destroy deletes all role assignments, and the service principal if `create_service_principal` is `true`. LangSmith then loses access to all data planes. Speak with LangChain before you destroy.
- A tenant has one LangSmith service principal. With more than one root module in a tenant, set `create_service_principal = true` in one only.

## License

Apache 2.0 - see the repository [LICENSE](../../../../LICENSE).
