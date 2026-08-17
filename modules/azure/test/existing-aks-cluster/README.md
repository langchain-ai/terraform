# existing-aks-cluster

Test scaffolding, not part of the product. It stands up a cluster and network of the
shape a customer would already be running, so the LangSmith Azure module's attach
path (`create_cluster = false`, `create_vnet = false`) can be exercised end to end.

The LangSmith module never creates any of this, and nothing else in the repo does
either, which is the reason this exists. Two Terraform stacks, two states:

```
test/existing-aks-cluster/   ← this. plays the customer's platform team
        │  outputs: cluster name, resource group, vnet_id, three subnet IDs
        ▼
infra/                       ← the module under test, run with create_cluster = false
```

What it builds, all in one resource group:

| Resource | Why the LangSmith module needs it this way |
|---|---|
| VNet, `10.42.0.0/16` | Clear of the module's own `10.0.x` default carve prefixes, so a passing run proves it read the supplied IDs |
| `aks-nodes` subnet, `/22` | Azure CNI is flat, so nodes and pods share it. `terraform_data.validate_network` rejects anything under `(max_count + 1) × (max_pods + 1)`, which is 764 at the module's defaults |
| `Microsoft.Storage` + `Microsoft.KeyVault` endpoints on it | The blob firewall is hardcoded default-deny and allowlists the subnet by ID; Azure rejects a subnet rule with no matching endpoint |
| `postgres` subnet, delegated | Flexible Server is subnet-injected. Enforced by `terraform_data.validate_network` |
| `redis` subnet, undelegated, PE policies off | Azure Managed Redis arrives as a private endpoint. Neither condition is validated by the module, so both fail mid-apply |
| AKS cluster, OIDC + workload identity on | Federated credentials for the LangSmith service accounts. Read off the live cluster by postconditions on `data.azurerm_kubernetes_cluster.existing` and `data.azapi_resource.existing_security_profile` |
| Local accounts enabled | The kubernetes and helm providers use `kube_config`, which Azure returns empty for an AAD-only cluster, and there is no kubelogin path |
| Azure CNI, `network_policy = "azure"` | `k8s-bootstrap` creates `NetworkPolicy` objects that a cluster with no policy engine silently ignores |

## Required access

This fixture and the LangSmith module both need **Owner, or Contributor plus User
Access Administrator**, at subscription scope. Contributor alone is not enough:

- The module creates three role assignments unconditionally
  (`keyvault.terraform_kv_admin`, `keyvault.managed_identity_kv_reader`,
  `storage.blob_data_contributor`), and Contributor's `notActions` include
  `Microsoft.Authorization/*/Write`.
- Pointing AKS at a subnet you supply grants the cluster identity Network
  Contributor on it, which is the same permission.

Check with:

```bash
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --include-inherited --include-groups --query "[].roleDefinitionName" -o tsv
```

The 11 providers `preflight.sh` requires must already be registered, plus
`Microsoft.Cdn` if you plan to set `create_waf = true` — `preflight.sh` omits that
one from its list.

The region needs Azure Managed Redis, Postgres Flexible Server, and spare Dsv3
quota:

```bash
az vm list-usage --location <region> \
  --query "[?contains(name.value,'standardDSv3Family')]" -o table
```

## Use

```bash
terraform init
terraform apply -var subscription_id=<guid> -var owner=<you>

# Wire the module under test to what was just built
terraform output -raw langsmith_tfvars >> ../../infra/terraform.tfvars
eval "$(terraform output -raw kubeconfig_command)"
```

Then fill in the LangSmith-side choices in `../../infra/terraform.tfvars`
(`name_prefix`, TLS, sizing) and run the module.

**Do not run `make quickstart` against that tfvars afterwards.** The wizard covers
the network half — it prompts for `create_vnet` and the three subnet IDs, keeps them
in `_STATE_KEYS`, and writes them out. It has no cluster half: `create_cluster`,
`existing_cluster_name`, `existing_cluster_resource_group_name`, and
`existing_cluster_node_pools_managed` appear nowhere in `scripts/quickstart.sh`. Its
writer opens `terraform.tfvars` with `cat >` (line 1146), so a hand-written attach
config is truncated and comes back as `create_cluster = true`, planning a brand-new
cluster.

## Teardown

Everything is in one resource group, so this works even if the state file is lost:

```bash
az group delete --name existing-cluster-test-rg --yes --no-wait
```

Destroy the LangSmith deployment first. Its private DNS zones link to this VNet,
and the VNet will not delete while those links exist.
