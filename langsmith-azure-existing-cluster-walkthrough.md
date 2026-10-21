# LangSmith on Azure: deploying onto a cluster the customer already runs

Walkthrough and findings for the `create_cluster = false` path, covering PRs #94 through
#99 stacked together. Everything below was run against a real Azure subscription on
2026-07-31.

## What the attach path is

Two separate Terraform stacks with two separate states:

```
the customer's platform team          the LangSmith module
─────────────────────────────         ─────────────────────────────
AKS cluster, VNet, subnets     ──►    create_cluster = false
(already exists, we never             create_vnet    = false
 create or modify it)                 reads the cluster, creates
                                      Key Vault, Storage, Postgres,
                                      Redis, identities, federated
                                      credentials
```

To test this without a customer, `modules/azure/test/existing-aks-cluster` builds the
left-hand side: a resource group, a VNet on `10.42.0.0/16`, three subnets, and an AKS
1.35 cluster. It is test scaffolding and never ships as part of the product.

## Prerequisites on the customer's cluster

Bring these to the call. Each one is enforced by the module, and three of them are
currently only enforced at apply time (see finding 2).

| Requirement | Why |
|---|---|
| OIDC issuer enabled | Federated credentials for the LangSmith service accounts are built on it |
| Workload identity enabled | Separate AKS flag. Issuer on with workload identity off applies cleanly and leaves pods with no token |
| Local accounts **not** disabled | The kubernetes and helm providers authenticate with the cluster's `kube_config`, which Azure returns empty for an AAD-only cluster. There is no kubelogin path |
| A network policy engine | `k8s-bootstrap` creates `NetworkPolicy` objects that a cluster with no engine accepts and never enforces |
| API server reachable from the apply host | `k8s-bootstrap` installs cert-manager and KEDA |
| Node subnet sized for Azure CNI | Nodes and pods both draw from it. The module needs `(max_count + 1) x (max_pods + 1)` addresses, which is 764 at the defaults, so a /22 or larger |
| Storage and KeyVault service endpoints on the node subnet | The blob firewall is default-deny and allowlists that subnet by ID. Azure rejects a subnet rule with no matching endpoint |
| Postgres subnet delegated to `Microsoft.DBforPostgreSQL/flexibleServers` | Flexible Server is subnet-injected |
| Redis subnet undelegated, with `private_endpoint_network_policies = "Disabled"` | Azure Managed Redis arrives as a private endpoint. A delegated subnet accepts only its delegated service |

Enable the first two with:

```bash
az aks update --name <cluster> --resource-group <rg> \
  --enable-oidc-issuer --enable-workload-identity
```

## Access the deploying identity needs

**Owner, or Contributor plus User Access Administrator, at subscription scope.**
Contributor alone fails. The module creates three role assignments unconditionally
(`modules/azure/infra/modules/keyvault/main.tf:75` and `:87`,
`modules/azure/infra/modules/storage/main.tf:58`), and Contributor's `notActions`
include `Microsoft.Authorization/*/Write`. Pointing AKS at a supplied subnet also grants
the cluster identity Network Contributor on it, which needs the same permission.

Check it:

```bash
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --include-inherited --include-groups --query "[].roleDefinitionName" -o tsv
```

The 11 providers listed in `modules/azure/infra/scripts/preflight.sh` must already be
registered. No Entra ID or Graph write permission is needed: the module contains no
`azuread_*` resources.

## Check the region before you commit to it

Azure Managed Redis does not allocate in every region, and when it fails it tells you
nothing useful: an `OperationFailed` inside an HTTP 200, roughly 15 minutes into the
apply. Confirm it somewhere the module has already built one, or expect to move Redis.

```bash
# Where AMR is already running, and whether yours is one of them
az redisenterprise list --query "[].{name:name,loc:location,sku:sku.name,state:provisioningState}" -o table

# Spare Dsv3 quota for the node pools
az vm list-usage --location <region> \
  --query "[?contains(name.value,'standardDSv3Family')]" -o table
```

Confirmed on 2026-07-31: AMR builds in **East US** and fails in **East US 2** at both
`Balanced_B0` and `Balanced_B1`. That is regional capacity, not a module problem, and it
is not visible until apply.

## Step by step

### Get the branch

Everything below needs `preview/azure-stack-94-99`. None of it works on `main`:
`create_cluster` and the `existing_cluster_*` variables arrive with PR #95, and the wizard
support, the Postgres fix, and the fixture are newer than that.

```bash
git clone git@github.com:langchain-ai/terraform.git
cd terraform
git checkout preview/azure-stack-94-99
```

On a checkout you already have:

```bash
git fetch origin
git checkout preview/azure-stack-94-99
```

The branch stacks PRs #94 through #99 and carries three commits that are in none of them,
so anyone tracking the individual PRs will not see these yet:

| Commit | What | Where it is headed |
|---|---|---|
| `87e7ca2` | Postgres `connection_throttle.enable` | its own PR off `main`, independent of the stack |
| `5af042f` | wizard existing-cluster questions | a follow-up PR, after #95, #96, #98, and #99 all land |
| `f79f799` | the stand-in cluster fixture | PR #95 |

The wizard commit cannot go on #95 by itself. It builds on `_load_tfvars` and
`_parse_tfvar` from #98, `_ask_subnet` from #99, and `NAME_PREFIX` from #96, and #95 does
not touch `quickstart.sh` at all.

Then run everything from `modules/azure`, and confirm the target first, every time:

```bash
az account show --query '{name:name, id:id, user:user.name}' -o json
```

### 1. Stand up a stand-in cluster, if you are demoing rather than using theirs

Skip to step 2 if you are pointing at the customer's own cluster.

```bash
cd modules/azure/test/existing-aks-cluster
terraform init
terraform apply -var subscription_id=<guid> -var owner=<you>
```

Six resources, about seven minutes, all inside one resource group so teardown is a
single `az group delete`.

### 2. Write terraform.tfvars

Order matters. Run the wizard first and hand-edit second, never the reverse: the wizard
opens `terraform.tfvars` with `cat >` and truncates whatever is there.

```bash
cd modules/azure
make quickstart
```

Answer **no** to `Create a new AKS cluster? (recommended)`, then give the cluster name and
the resource group holding it. The wizard forces `create_vnet = false` from there, since
attaching means using that cluster's VNet, and resets any add-on that needs a
Terraform-owned cluster or VNet.

`postgres_subnet_id` and `redis_subnet_id` can be left blank, and Terraform carves those
inside their VNet. The **AKS node subnet is required** and the wizard will not let you skip
it: the subnet has to be one the cluster already runs nodes in, because the same ID drives
the Blob and Key Vault firewall allowlists.

Note for anyone on an older checkout: before this change the wizard had no cluster
questions at all, and its writer truncates `terraform.tfvars`, so the four keys below had
to be appended by hand after every run.

```hcl
create_cluster                       = false
existing_cluster_name                = "<their cluster>"
existing_cluster_resource_group_name = "<their resource group>"
existing_cluster_node_pools_managed  = false
```

Both `create_cluster` and `existing_cluster_node_pools_managed` default to `true`.
Omitting the first plans a brand-new cluster. Omitting the second attaches a `large`
pool of `Standard_D16s_v3` to a cluster the docs say Terraform never modifies.

If you are demoing off the fixture, skip the wizard entirely. It emits the whole attach
half already:

```bash
cd modules/azure/test/existing-aks-cluster
terraform output -raw langsmith_tfvars > ../../infra/terraform.tfvars
```

Then add the LangSmith-side choices: `name_prefix`, `postgres_source`, `redis_source`,
`clickhouse_source`, `tls_certificate_source`, `sizing_profile`, and the deletion
protection flags.

### 3. Generate the secrets file

```bash
cd modules/azure/infra
./scripts/setup-env.sh
```

It prompts for the license key, admin password, and admin email, then generates the
Postgres password and six encryption keys itself. To run it without a tty, export
`LANGSMITH_LICENSE_KEY`, `LANGSMITH_ADMIN_PASSWORD`, and `LANGSMITH_ADMIN_EMAIL` first
and it skips every prompt.

Both `terraform.tfvars` and `secrets.auto.tfvars` are covered by
`modules/azure/.gitignore`.

### 4. Fetch cluster credentials

```bash
az aks get-credentials --resource-group <rg> --name <cluster> --overwrite-existing
kubectl config current-context
```

### 5. Run preflight

```bash
cd modules/azure
make preflight
```

Checks az login, the 11 providers, the RBAC roles, the two tfvars files, and that
terraform, kubectl, and helm are present.

### 6. Plan, and read it for what is absent

```bash
cd modules/azure/infra
terraform plan -out=attach.tfplan
```

A correct attach plan contains **zero** of these. Grep for them in front of the
customer, because their absence is the whole point:

```bash
terraform show -no-color attach.tfplan > plan.txt
for t in azurerm_kubernetes_cluster azurerm_kubernetes_cluster_node_pool \
         azurerm_virtual_network azurerm_subnet; do
  echo "$t: $(grep -c "resource \"$t\"" plan.txt)"
done
```

Ours planned 57 resources to add, 0 to change, 0 to destroy, with all four counts at
zero.

Expect one warning, and know what it means before they ask:

```
Warning: Check block assertion known after apply
  on modules/k8s-cluster/main.tf line 149, in check "existing_cluster_location"
```

That is finding 2 below, not a problem with their config.

### 7. Apply

```bash
terraform apply attach.tfplan
```

Budget roughly 25 minutes: Postgres Flexible Server takes about 10, Azure Managed Redis
about 15 to 20.

### 8. Tear down, LangSmith first

The LangSmith stack's private DNS zones link to the customer's VNet, and the VNet will
not delete while those links exist.

```bash
az group delete --name langsmith-rg-<name_prefix> --yes --no-wait
az group delete --name existing-cluster-test-rg --yes --no-wait   # fixture only
```

## Findings, worst first

### 0. External Postgres failed on every deployment, on every cloud path

`modules/azure/infra/modules/postgres/main.tf:145` set a server parameter named
`connection_throttling`. No such parameter exists. Azure rejects it:

```
Status: "ParameterNotExists"
Message: "Server parameter 'connection_throttling' is invalid or isn't supported in PostgreSQL version '14'."
```

The name is `connection_throttle.enable`, confirmed against a live server with
`az postgres flexible-server parameter list`. `postgres_version` defaults to `"14"` at
`modules/postgres/variables.tf:35`, so this broke **every** apply with
`postgres_source = "external"`, whether attaching or creating a cluster. It failed late,
after the server was already `Ready`, leaving a working database and a red apply.

Fixed and verified: the corrected parameter created in 34 seconds where the old name had
failed. This one is worth landing on its own, ahead of the attach work, because it is not
attach-specific.

### 1. The quickstart wizard cannot express this deployment

`create_cluster`, `existing_cluster_name`, `existing_cluster_resource_group_name`, and
`existing_cluster_node_pools_managed` appear nowhere in
`modules/azure/infra/scripts/quickstart.sh`. Its writer truncates `terraform.tfvars`
(line 1146), so hand-added keys are erased on any later run and the file comes back as
`create_cluster = true`.

The network half is fully built: the wizard prompts for `create_vnet` and the three
subnet IDs, keeps them in `_STATE_KEYS`, reads them back out of an existing tfvars, and
writes them again. Only the cluster half is missing.

Every customer who already owns a cluster hits this. It is the biggest practical
obstacle on the path, ahead of anything else here.

### 2. Three of the existing-cluster guards never run at plan time

Terraform defers the data source they hang off:

```
# module.aks.data.azurerm_kubernetes_cluster.existing[0] will be read during apply
# (depends on a resource or a module with changes pending)
```

`modules/azure/infra/modules/k8s-cluster/main.tf:58` falls back to
`var.resource_group_name`, which `modules/azure/infra/main.tf:381` supplies as
`azurerm_resource_group.resource_group.name`, a resource pending creation. The data
source reads that local, so Terraform draws a dependency edge to the pending resource
group. Edges come from static references in the config, built before evaluation, so the
ternary selecting the known branch does not remove it.

Deferred as a result:

- node subnet membership, `k8s-cluster/main.tf:117`
- OIDC issuer enabled, `k8s-cluster/main.tf:106`
- workload identity enabled, `k8s-cluster/main.tf:135`, which cascades because the
  azapi data source reads the deferred cluster's `id`
- the `existing_cluster_location` region check, which warns instead of asserting

All four fire only after the resource group, Key Vault, and storage account have started
creating. That contradicts commit `9122fc7` (PR #95), whose stated purpose is catching
these at plan time. The fallback is also meaningless where it triggers: on a fresh apply
it means "assume the customer's existing cluster lives in the resource group Terraform is
about to create."

Confirmed from both directions. On a fresh plan the data source is deferred and the region
check warns "condition could not be evaluated at this time". On a plan run after the
resource group exists in state, both the deferral and the warning disappear and every
postcondition evaluates normally. So the guards work only once you no longer need them,
and go quiet on exactly the first run where a customer's config is most likely wrong.

Reproduced on a customer's own cluster, which is what the warning looks like in front of
them:

```
Warning: Check block assertion known after apply

  on modules/k8s-cluster/main.tf line 149, in check "existing_cluster_location":
 149:       condition = lower(replace(local.cluster_location, " ", "")) == lower(replace(var.location, " ", ""))

    local.cluster_location is a string
    var.location is "eastus"

The condition could not be evaluated at this time, a result will be known when
this plan is applied.
```

Note what Terraform prints for the left side: `is a string`, the type rather than a value,
because the cluster has not been read yet. The right side has a real value. So the operator
sees their own input echoed back next to a blank, and the region they typed is confirmed
against nothing.

The consequence is concrete. `var.location` has to match the region the cluster actually
runs in, and this is the only check for it. Getting it wrong produces a clean plan and then
an apply that fails partway, after the resource group, Key Vault, and storage account have
started creating. There is no plan-time signal, only a warning that says the check did not
run.

Reading the region off the cluster removes the class entirely, which is change 10.

This compounds finding 3. A customer who leaves `aks_subnet_id` blank gets a clean plan
and a partial apply.

### 3. The wizard invites a subnet choice the attach path rejects

Under bring-your-own VNet the wizard offers to carve each subnet for you. For
`aks_subnet_id` that is invalid when `create_cluster = false`, because
`k8s-cluster/main.tf:117` requires a subnet the cluster already runs nodes in and a
subnet Terraform is about to carve never is. The wizard cannot warn about it, because it
has no concept of `create_cluster`.

### 4. Node pools default to Terraform-managed on someone else's cluster

`existing_cluster_node_pools_managed` defaults to `true`, so the default behaviour on an
attached cluster is to add a `large` node pool of `Standard_D16s_v3`. The README
describes the customer's cluster as something Terraform never modifies or destroys.
Those two statements disagree, and the default is the surprising one.

### 5. create_cluster = false silently forces create_vnet = false

`modules/azure/infra/variables.tf:120` documents that Terraform still provisions
networking "when `create_vnet = true`" under an attached cluster. It cannot: a carved
subnet can never satisfy the node subnet postcondition. The combination the comment
describes has no working configuration.

### 6. Two deletion-protection variables do nothing

`aks_deletion_protection` and `postgres_deletion_protection` are declared at
`modules/azure/infra/variables.tf:365` and `:371`, set in every tfvars template, and
documented as destroy blockers. Nothing reads them. A grep across every `.tf` in the
module finds no other reference, and no `lifecycle` block uses them. Anyone relying on
them for protection has none.

### 7. The repo has no Azure test scaffolding

No prereq module, no runnable examples, and CI runs only format, lint, and scan with no
plan or apply step. AWS has `test-permutations.sh`, `test-orchestrator.sh`, and
`test-worker.sh`. Azure has `test-quickstart-state.sh`, a unit test that creates no Azure
resources. Every check in finding 2 needs a real subscription and a real cluster to
exercise, so none of it reproduces offline. That is why the fixture had to be written
before any of this could be tested.

### 8. The subnet capacity check counts node pools the attach path never creates

This is a hard blocker, hit live against a customer's /24. The check at
`infra/main.tf:341` demanded 764 addresses against their 251:

```
local.aks_required_ips is 764
local.aks_usable_ips is 251
```

Every input to that 764 describes pools Terraform will not create. `aks_required_ips` at
`infra/main.tf:99-102` is:

```hcl
aks_required_ips = sum(concat(
  [(var.default_node_pool_max_count + 1) * (var.default_node_pool_max_pods + 1)],
  [for pool in var.additional_node_pools : (pool.max_count + 1) * (local.aks_default_pool_max_pods + 1)]
))
```

With the defaults of 10 and 60 the first term is `11 x 61 = 671`, for a default node pool
that lives inside `azurerm_kubernetes_cluster.main` and is counted off at
`k8s-cluster/main.tf:173` when `create_cluster = false`. Those two variables reach exactly
two places: this calculation, and `k8s-cluster/main.tf:203` and `:208` inside that
counted-off resource. So the 671 is capacity for a pool that never exists.

The second term reads `var.additional_node_pools` directly, not the gated expression at
`infra/main.tf:398` that the rest of the module uses:

```hcl
additional_node_pools = var.create_cluster || var.existing_cluster_node_pools_managed ? var.additional_node_pools : {}
```

So `existing_cluster_node_pools_managed = false` leaves the `large` pool's 93 addresses in
the requirement. **The flag whose entire purpose is "do not touch my node pools" has no
effect on the check that blocks the deployment.**

Net effect: attaching to any cluster in a /24 fails by default, on capacity for pools
Terraform will not create, and the documented way to say "I own the pools" does not clear
it. The customer's cluster already runs in that /24 at whatever size it actually needs.

The workaround found live, which is worth knowing because it is not discoverable:

```hcl
existing_cluster_node_pools_managed = false
additional_node_pools               = {}
default_node_pool_max_count         = 1
default_node_pool_max_pods          = 30
```

That brings the requirement to `2 x 31 = 62`. The last two lines configure nothing on this
path; they exist only to satisfy the arithmetic.

### 9. The attach path asks for values Azure already holds

One `az aks show` returns every value the wizard prompts for on this path, plus every
prerequisite the module checks separately. Confirmed against the fixture cluster:

```
nodeSubnet:        /subscriptions/.../subnets/aks-nodes
serviceCidr:       172.16.0.0/20
dnsServiceIp:      172.16.0.10
oidc:              true
workloadIdentity:  true
localAccounts:     false
networkPolicy:     azure
pools:             default  Standard_D4s_v3  min 2  max 4  maxPods 60  System
```

Set against what sections 3 and 4 ask when attaching:

| Question | Reality |
|---|---|
| cluster name, resource group | genuinely must ask |
| manage node pools? | genuinely must ask, a policy choice not a fact |
| Postgres subnet, Redis subnet | genuinely must ask, those are new |
| VNet ID | readable, it is the parent of the node subnet |
| AKS node subnet ID | readable |
| service CIDR | readable, and configures nothing (finding 10) |
| node pool vm_size / min / max | configures nothing |
| node pool max_pods | never prompted, hardcoded 60 |
| `aks_deletion_protection` | does nothing (finding 6) |

Three real questions, two that produce paste errors for no reason, five that configure
nothing.

The paste error is not hypothetical. A customer pasted the VNet ID into the AKS node
subnet prompt, because the VNet question comes immediately before it and the two IDs are
prefixes of each other. `quickstart.sh:475` rejects it correctly and then only restates the
expected format, offering nothing to pick from and no way to recover except finding the ID
by hand.

Two details for whoever builds the lookup. The field is `networkProfile.dnsServiceIp` with
a lowercase p; the obvious `dnsServiceIP` silently returns null. And the DNS IP is the
service CIDR's tenth host, which is exactly what `infra/main.tf:90` derives with
`cidrhost(..., 10)`, so reading the service CIDR gets the DNS IP for free.

### 10. `aks_service_cidr` is required when attaching and configures nothing

`service_cidr` is set in one place, the `network_profile` block at
`k8s-cluster/main.tf:251`, inside the cluster resource counted off when
`create_cluster = false`. Its only consumers on the attach path are two checks:
`infra/main.tf:349` requires it to be non-empty, and `infra/main.tf:358` rejects it if it
overlaps the VNet.

Nothing compares it to the cluster's real `networkProfile.serviceCidr`. So a plausible
guess passes both checks and changes nothing, which reads to an operator as though they
configured the cluster's ClusterIP range. It cuts the other way too: a guess that happens
to land inside their VNet trips check 358 and blocks a valid deployment over a value with
no effect.

A cluster's real service CIDR can never overlap its own VNet, because Azure will not create
one that way. So reading it satisfies both checks by construction.

### 11. The capacity error states a total with no arithmetic

The message at `infra/main.tf:342` reports 764 and 251 and names two variables to lower. It
never shows how 764 was built, so there is no way to tell which knob moves the number, by
how much, or what subnet size would be enough. A customer sizing a subnet from this message
has to reverse-engineer the formula from the module source.

What it should carry: the per-pool breakdown that sums to the total, Azure's five reserved
addresses, the smallest prefix that fits (`764 + 5 = 769`, so a /22), and the sensitivity of
each knob. Those last two are the actionable part and are not obvious: each node removed
from `default_node_pool_max_count` frees `max_pods + 1` addresses, 61 at the defaults, and
each pod removed from `default_node_pool_max_pods` frees `max_count + 1`, 11 at the
defaults.

Two things block a clean fix. `default_node_pool_max_pods` is hardcoded to `60` in the
writer at `quickstart.sh:1388` with no prompt behind it, so the wizard cannot produce any
other value for one of the two knobs the message tells you to turn. And Terraform's
diagnostic renderer reflows `error_message` text, which is what broke the negative-test
matcher for this exercise, so a formatted breakdown table may not survive rendering.
**Unverified: whether explicit newlines in `error_message` are preserved.** Worth a
throwaway config to settle before designing the message around a table.

This one is ordered after finding 8 deliberately. Explaining the arithmetic of a check that
counts phantom pools would make a wrong answer more articulate. Fix 8 first, then the
numbers in the message are real and worth explaining.

### 12. Nothing checks whether the customer's existing pools can run LangSmith

The module validates seven things about an attached cluster: OIDC issuer, workload identity,
local accounts, network policy engine, node subnet membership, Postgres subnet delegation,
and Redis subnet policies. It never checks the one property that decides whether LangSmith
runs.

ClickHouse requests 3.5 vCPU and 15 GiB, per the `additional_node_pools` description at
`infra/variables.tf:355`. The fixture cluster's `Standard_D4s_v3` nodes report, read off the
live nodes:

```
cpu=3860m  mem=14992436Ki
```

That is 14.3 GiB allocatable against a 15 GiB request, short by roughly 700 MiB.
**ClickHouse cannot schedule there.** And that cluster passes all seven checks. Seven
prerequisites green, and the deployment does not run.

This is the inversion worth naming: the module interrogates the operator about node pools it
will never create (finding 8) and never asks about the pools it will actually use. Under
`existing_cluster_node_pools_managed = false` the customer's pools run everything, and their
capacity is the only number that predicts success.

The check belongs in the wizard rather than Terraform, because mapping a VM SKU to
allocatable capacity needs an `az` call and Terraform has no way to do it. The answer is a
hard yes or no, so it is worth asking before the tfvars are written rather than discovering
it as a pending pod.

Related, and mostly good news: the module sets no node labels, no taints, no
`nodeSelector`, and no tolerations anywhere in `modules/azure`. So nothing pins LangSmith
workloads to a particular pool, and unmanaged pools work without special configuration. The
same absence means that under `existing_cluster_node_pools_managed = true` the `large` pool
is a capacity guarantee and not a placement one: with `min_count = 0` and nothing targeting
it, where ClickHouse lands depends on which pool the autoscaler picks.

### 13. AGIC and bastion cannot be used with a bring-your-own VNet, and AGIC not at all when attaching

Two checks block them, with the reason stated in the message:

```hcl
# infra/main.tf:301
condition     = var.ingress_controller != "agic" || var.create_vnet
error_message = "... Application Gateway needs its own /24 subnet and there is no agic_subnet_id input."

# infra/main.tf:296
condition     = !var.create_bastion || var.create_vnet
error_message = "... There is no bastion_subnet_id input ..."
```

This is a plumbing gap, not an Azure limitation. AGIC runs fine in a customer VNet. The
module has nowhere to receive the subnet: it is created at `networking/main.tf:124` under
`count = var.enable_agic ? 1 : 0` inside the VNet Terraform owns, and `local.agic_subnet_id`
is hardwired to `module.vnet.subnet_agic_id` at `infra/main.tf:68`. The bring-your-own
subnet inputs cover aks, postgres, and redis only.

AGIC has a second blocker that a subnet input would not clear. It is enabled through the AKS
`ingress_application_gateway` add-on, and that `dynamic` block sits inside
`azurerm_kubernetes_cluster.main` at `k8s-cluster/main.tf:282`, the resource counted off when
attaching. Turning the add-on on means modifying a cluster Terraform does not manage. Since
`create_cluster = false` forces `create_vnet = false` (finding 5), the attach path trips both
at once, so AGIC is unavailable on this path regardless of the subnet gap.

Azure itself supports enabling the add-on on an existing cluster with
`az aks enable-addons --addons ingress-appgw`, so the capability exists outside what the
module can express. The pre-add-on path was the AGIC Helm chart, and Microsoft retired that
repo, noted at `k8s-cluster/main.tf:279`.

Closing the bring-your-own-VNet half for a Terraform-created cluster is small: an
`agic_subnet_id` variable, selected over `module.vnet.subnet_agic_id` when
`create_vnet = false`, and the check relaxed to accept either. Same shape as the existing
bring-your-own subnet inputs. Bastion is the same change.

### 14. An existing Key Vault cannot be reused

There is no `key_vault_id` input, no `data "azurerm_key_vault"` anywhere in the module, and
`azurerm_key_vault.langsmith` at `modules/keyvault/main.tf:34` has no `count`. The module
call at `infra/main.tf:517` is unconditional, so a vault is always created, in the resource
group Terraform makes rather than the customer's.

How much this costs is smaller than it sounds, because the vault is not a runtime
dependency. Pods do not mount from it. Terraform writes about ten secrets in and
`setup-env.sh` reads them back on later runs, at `setup-env.sh:136`, so nobody keeps local
`.secret` files. The comment at `modules/keyvault/main.tf:88` is explicit that pod read
access is "currently used by setup-env.sh, and ready for the CSI Secrets Store driver in
Phase 2." The cluster receives its secrets as Kubernetes secrets.

`terraform import` is not the workaround. Adopting a customer's vault into this address
pushes two settings onto a resource other things depend on: `rbac_authorization_enabled =
true` at `modules/keyvault/main.tf:43`, which drops every existing access policy if their
vault runs in access-policy mode, and `network_acls` at `:61`, which replaces their
`ip_rules` and `virtual_network_subnet_ids` with ours. Both are silent.

Proper support is the same shape as the bring-your-own subnet inputs: a `key_vault_id`
variable, a data source read when set, `count` on the resource, and a local selecting
between them, with the secrets and both role assignments hanging off the local. The
prerequisite that needs a conversation rather than a flag is data plane reachability. The
comment at `modules/keyvault/main.tf:56` explains that `default_action` defaults to `Allow`
because the first apply writes those ten secrets through the data plane and gets 403'd under
`Deny`. A production vault is almost certainly on `Deny`, so this means asking their security
team to allowlist the deploying IP for the length of the apply.

### 15. Cluster-scoped components sit in the app half of the split

The module already implements most of a foundation-versus-app split, and the attach path is
the proof: 55 resources created with zero managed cluster, VNet, subnet, or node pool
resources. What is in the way is that the existing boundary between `infra/` and `app/` is
drawn at Terraform-versus-Helm rather than foundation-versus-app, so three cluster-scoped
components land on the app side and two of them cannot be turned off.

| Component | Scope | Skippable |
|---|---|---|
| namespace, service account, quota, limit range, network policies, secrets | namespace | that is the app |
| ingress controller | cluster | yes, `ingress_controller = "none"` |
| cert-manager and its ClusterIssuer | cluster, installs CRDs | **no.** `k8s-bootstrap/main.tf:262` has no `count` |
| keda | cluster, installs CRDs | **no.** `k8s-bootstrap/main.tf:363` has no `count` |

A platform team that owns a cluster is already running cert-manager. The module installs a
second one with no flag to stop it, plus a cluster-scoped `ClusterIssuer` at
`k8s-bootstrap/main.tf:323`. That is the app half reaching into cluster-scoped territory,
and it is the first thing a customer with this split will refuse.

Two related problems already have their own findings. Cluster-shaped variables live in the
app root and get validated there, which is findings 8, 10, and 11: the split being
incomplete is what broke a customer deployment, not a cosmetic concern. And the cluster is
discovered through a data source that guesses its resource group rather than being told,
which is finding 2 and reads as a dependency bug while actually being a boundary problem.

Worth deciding which cut is meant before designing to it. "An app installed in a namespace"
undersells what this creates: a Postgres Flexible Server, Redis, a storage account, a Key
Vault, two managed identities, eight federated credentials, and private DNS zone links into
the customer's VNet. None of that is namespace-scoped. The clean line is lifecycle rather
than scope: what should be destroyed when LangSmith is uninstalled versus what outlives it.
Postgres holds their traces, so it falls on the app side of a lifecycle cut and the cluster
side of a namespace cut.

### 16. The wizard hides the "create it for me" option inside an ID prompt

Raised by a customer in their own words: "we should ask if you already have subnets or if we
want to create them for you."

The capability exists. PR #99 made bring-your-own subnet IDs optional per subnet, so a blank
answer means "carve this one for me." The problem is that the question never asks. The prompt
at `quickstart.sh:463` is:

```
${label} subnet resource ID (Enter = let Terraform create it)
```

So the choice between bringing a subnet and having one created is a parenthetical on a
prompt whose subject is a resource ID. A customer reading it sees a request for an ID they
have to go find, and the alternative reads as a hint about keystrokes rather than an option.

It gets worse across the three prompts, because they do not behave alike. When attaching,
the AKS subnet is required and line 464 drops the parenthetical entirely, while Postgres and
Redis keep it. Three prompts that look nearly identical, one of which has no create option,
and nothing on screen explains why.

The fix is to ask the question first and only then ask for the ID:

```
Do you already have a subnet for PostgreSQL, or should Terraform create one? [have/create]
```

For the AKS subnet on the attach path there is no choice to offer, so it should say why
rather than silently dropping the option: the subnet has to be one the cluster already runs
nodes in, and a subnet Terraform is about to carve never is. That is finding 3 stated to the
operator at the moment it applies to them.

This composes with change 10. Once the wizard reads the cluster, the AKS subnet is not a
question at all, and the only two subnets left to ask about are the two that genuinely have
a choice.

## Changes to make

Ranked by what removes the most customer pain per unit of work. **Changes 8 and 12 outrank
everything below change 2**; they are numbered later only so existing references to changes
0 through 7 stay stable.

0. **Land the Postgres parameter fix first.** One line, and it unblocks every external
   Postgres deployment on every path. Already written and verified.

1. **Teach the wizard the four cluster keys.** Written and tested. Section 3 becomes
   "Cluster & Networking" and asks about the cluster before the VNet, because the answer
   constrains it. Attaching prompts for the cluster name and its resource group, forces
   `create_vnet = false`, resets `istio-addon` to nginx the way the existing code already
   resets AGIC, and makes the AKS subnet ID required with no carve option. Section 4 asks
   whether Terraform should manage node pools. Section 5 rejects `istio-addon` under
   `create_cluster = false`. The review screen shows the cluster, and all four keys are in
   `_STATE_KEYS` and the writer.

   Both free-text names are validated against Azure's naming rules at the prompt **and**
   in `_load_tfvars`. The second one matters: values read back out of an existing
   `terraform.tfvars` with `sed` reach the writer having never passed a prompt, and the
   writer interpolates them into double-quoted HCL, so an unchecked value could close the
   string and append configuration that applies with the deploying identity's credentials.
   Subnet IDs are now validated the same way at both points. The VNet ID is validated at
   the prompt only, which predates this change.

2. **Break the deferred data source, so the guards run at plan.** Resolve the fallback in
   the root against `local.resource_group_name` at `infra/locals.tf:30`, which is already
   a plain string, and drop the fallback from `k8s-cluster/main.tf:58`. Two lines, and
   what the fallback resolves to does not change. Consider instead requiring
   `existing_cluster_resource_group_name` when `create_cluster = false`, alongside the
   existing `existing_cluster_name` precondition, since the fallback is meaningless on a
   fresh apply. That is a contract change, so the two-line fix is the safer default.

3. **Make `aks_subnet_id` required when `create_cluster = false`.** It cannot be carved,
   so offering to carve it is offering a broken configuration. Rejecting a blank value at
   plan time removes finding 3 outright, and removes the compounding with finding 2.

4. **Flip `existing_cluster_node_pools_managed` to default `false`.** Match the
   documented promise that Terraform never modifies the customer's cluster. Opting in to
   pool management is the choice worth making explicit.

5. **Wire up the two deletion-protection variables, or delete them.** Either add the
   `lifecycle { prevent_destroy }` behaviour they claim, or remove them from the
   variables and every template. A flag that silently does nothing is worse than no flag.

6. **Correct the `create_vnet` comment at `variables.tf:120`,** and add a precondition
   rejecting `create_cluster = false` with `create_vnet = true` rather than letting it
   fail on an unrelated postcondition.

7. **Promote the fixture into the repo and give Azure a plan-level CI job.** The negative
   tests written for this exercise cover ten checks across #94 through #99, and every one
   needs credentials, so they belong in a job with a subscription rather than in the
   format-and-lint pass.

8. **Scope the subnet capacity check to pools Terraform actually creates.** The highest
   priority item in this list, because it blocks any attach onto a /24 by default and the
   documented escape hatch does not clear it. Count the default pool only when
   `create_cluster = true`, and iterate the gated pool map that `infra/main.tf:398` already
   computes rather than `var.additional_node_pools`:

   ```hcl
   aks_required_ips = sum(concat(
     [0],
     var.create_cluster ? [(var.default_node_pool_max_count + 1) * (var.default_node_pool_max_pods + 1)] : [],
     [for pool in local.managed_node_pools : (pool.max_count + 1) * (local.aks_default_pool_max_pods + 1)]
   ))
   ```

   Creating a cluster behaves exactly as it does now. Attaching with managed pools checks
   only the pools being added. Attaching without them drops the requirement to zero. The
   comment the wizard emits above those keys, at `quickstart.sh:1379`, asserts the check is
   deliberate and correct, so it has to change with this.

9. **Explain the arithmetic in the capacity error.** After change 8, not before. Carry the
   per-pool breakdown, Azure's five reserved addresses, the smallest prefix that fits, and
   the per-knob sensitivity, so a customer can size a subnet from the message instead of
   reading the module source. Settle whether Terraform preserves newlines in `error_message`
   first; if it reflows them, the breakdown has to work as prose rather than a table. Give
   `default_node_pool_max_pods` a prompt at the same time, since `quickstart.sh:1388`
   hardcodes it to 60 and the message tells operators to lower it.

10. **Read the cluster instead of asking about it.** One `az aks show` on the attach path
    fills the AKS node subnet, the VNet, the service CIDR, and the DNS IP, and returns every
    prerequisite the module checks. Replace nine prompts with two questions and a
    confirmation screen: cluster name and resource group, then show what came back for the
    operator to approve. This removes both paste-error classes and moves the prerequisite
    check to where the customer can still act on it, rather than in preflight after the
    tfvars are written. Skip the node pool section entirely when they own the pools, and set
    `additional_node_pools = {}` rather than making them discover it.

    As a fallback for when the lookup returns nothing, print portal deep links built from the
    IDs already in hand: `https://portal.azure.com/#resource<cluster id>/nodePools` and
    `https://portal.azure.com/#resource<vnet id>/subnets`. The repo has no portal links
    anywhere today, so this sets the convention. The resource ID composition is confirmed
    against live resources; the blade suffixes are not, and bare `#resource<id>` lands on the
    overview if a suffix misses.

11. **Warn when the customer's pools cannot seat ClickHouse.** The check nobody runs, and the
    only one that predicts whether the deployment works. Compare each pool's allocatable
    capacity against the 3.5 vCPU / 15 GiB request before the tfvars are written. This has to
    live in the wizard, because mapping a VM SKU to allocatable capacity needs an `az` call.
    Worth pairing with change 4: once `existing_cluster_node_pools_managed` defaults to
    `false`, their pools run everything and this becomes the deciding number.

12. **Add `agic_subnet_id` and `bastion_subnet_id`.** Closes finding 13 for customers on a
    Terraform-created cluster with their own VNet, in the same shape as the existing
    bring-your-own subnet inputs. Ranks high because it is small and turns two hard rejections
    into supported configurations. It does not help the attach path, where AGIC is blocked by
    the add-on living inside a resource Terraform does not own.

13. **Add `key_vault_id` for an existing vault.** Same shape again: variable, data source,
    `count`, and a local. Lower priority than it looks, because the vault is not a runtime
    dependency, so this buys ownership and audit alignment rather than removing a coupling.
    Document the `default_action = Deny` prerequisite prominently, since it needs the
    customer's security team rather than a config change.

14. **Ask whether they have a subnet before asking for its ID.** Cheap, and it comes straight
    from a customer. Turn the parenthetical at `quickstart.sh:463` into its own question, and
    when the AKS subnet has no create option on the attach path, say why instead of silently
    dropping it. Composes with change 10: once the cluster is read, only the two subnets that
    genuinely have a choice are left to ask about.

15. **Give the platform team a way to opt out of cluster-scoped add-ons.** Add `count` to
    cert-manager and keda plus inputs for "the cluster already provides these," then write
    down the handoff contract: the roughly eight facts the app root needs from whoever owns
    the cluster. Check against PR #100 first, which is making the `enable_*` flags
    authoritative for the same class of problem. This is what makes the attach path
    acceptable to a customer whose platform team owns the cluster, and it needs no second
    Terraform state to work.

16. **Decide what the attach path does with values that configure nothing.** `aks_service_cidr`,
    the four node pool settings, and `aks_deletion_protection` are all read, validated, and
    written on a path where they change no infrastructure. Either derive them from the cluster
    (change 10), or reject them with a message saying they have no effect here. Silently
    accepting and validating them is what produced findings 8, 10, and 11.

## What was verified, and how

Run on branch `preview/azure-stack-94-99`, a stack of PRs #94 through #99, against
subscription `Langchain`. The run itself was at commit `e1c8585` with the Postgres fix, the
wizard change, and the fixture applied as working-tree edits; those are now committed on
the same branch at `f79f799`, so a fresh checkout reproduces what was tested.

Confirmed by running:

- The fixture applies: six resources in eastus2.
- `make preflight` passes every check, including both RBAC lines.
- `terraform plan` succeeds on the attach path: 57 to add, 0 to change, 0 to destroy,
  with no cluster, VNet, subnet, or node pool resources in it.
- **`terraform apply` completes and the state converges.** A follow-up plan reports "No
  changes. Your infrastructure matches the configuration." The customer's cluster, VNet,
  and subnet appear in state only as `data.` reads, with zero managed
  `azurerm_kubernetes_cluster`, `azurerm_virtual_network`, or `azurerm_subnet` resources.
- cert-manager and nginx install onto the attached cluster through its `kube_config`,
  which is the part no plan can check.
- Both managed identities, all eight federated credentials, Key Vault with its role
  assignments, the storage account with its default-deny firewall allowlisting the
  customer's subnet, and Postgres inside the delegated subnet all created, along with
  both private DNS zone links into the customer's VNet.
- Nine of ten negative tests reject a bad config at plan time: the undelegated Postgres
  subnet, the node subnet missing service endpoints, three subnet IDs pointing at one
  subnet, a node pool scaled past the subnet's addresses, a service CIDR overlapping the
  VNet, an empty service CIDR, `istio-addon` under `create_cluster = false`, and
  `create_bastion` and `agic` under `create_vnet = false`.
- The tenth test is finding 2, confirmed in both directions as described there.
- The wizard change works: driven through the attach path without a tty, it emits all
  four cluster keys plus the network keys, and terraform accepts the result with zero
  precondition or validation errors.
- Finding 0 fixed and re-applied successfully.
- Findings 1, 5, and 6 were each confirmed by grep across the module.

Caveats on the run:

- **Redis ran in-cluster, not as Azure Managed Redis.** AMR could not be allocated in
  eastus2 at either SKU, so `redis_source = "in-cluster"` was used to reach a green apply.
  The managed-Redis path is therefore covered only by the plan-time subnet checks, not by
  an apply. AMR is proven in eastus by an existing deployment of this same module.
- The license key was a placeholder. This terraform installs cert-manager and keda and
  never the LangSmith chart, so nothing validates it. The chart install on top is untested
  here.
- The fix proposed in change 2 is traced and its diagnosis confirmed, but the fix itself is
  not applied or re-planned.
- Findings 4, 5, and 6 are unchanged code. Only finding 0 and the wizard gap were fixed.

Findings 8 through 14 came out of a live walkthrough against a customer's own cluster rather
than the fixture. What was confirmed there and how:

- **Finding 8 was hit as a hard blocker**, not derived from reading. The precondition failed
  with `local.aks_required_ips is 764` against `local.aks_usable_ips is 251` on a /24. The
  764 was then traced to its two terms and both were confirmed to describe pools the attach
  path does not create.
- **Finding 9's lookup was run**, returning the node subnet, service CIDR, DNS IP, OIDC
  issuer, workload identity, local accounts, network policy, and pool inventory in one call.
  The `dnsServiceIP` versus `dnsServiceIp` behaviour was observed, not assumed.
- **Finding 12's numbers were read off live nodes** with `kubectl get nodes -o jsonpath`, not
  estimated from the SKU: `cpu=3860m` and `mem=14992436Ki` on `Standard_D4s_v3`. The same
  cluster passes all seven prerequisite checks.
- Findings 10, 13, and 14 were confirmed by tracing every consumer of the variable or
  resource across the module, in the same way as findings 5 and 6. None of the three was
  reproduced by a failing apply.
- **Unverified, and it shapes change 9:** whether Terraform's diagnostic renderer preserves
  explicit newlines in `error_message`. It is known to reflow the text, which broke the
  negative-test matcher for this exercise, but whether a deliberate multi-line block survives
  was not settled. Test it before designing a breakdown table.
- Nothing in findings 8 through 14 is fixed. All seven are documented only.
