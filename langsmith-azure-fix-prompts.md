# Azure attach-path fixes: one prompt per parallel thread

Eight prompts covering all seventeen findings. Copy a fenced block into a fresh thread. Each
one is self-contained.

Full detail on every finding lives in `langsmith-azure-existing-cluster-walkthrough.md`
(findings 0 through 16) and `langsmith-azure-findings.html`. Point the thread at the
walkthrough when it needs more than the prompt carries.

**File-conflict map.** Prompts 1 and 2 both edit `modules/azure/infra/main.tf` on different
branches that both target `main`. Prompt 4 edits `infra/variables.tf`, which prompts 1 and 2
also touch. Whoever merges second rebases. Nothing else overlaps.

**Start now:** prompts 1 through 6. **Blocked until the stack lands:** prompts 7 and 8.

---

## Prompt 1 — PR #99: four findings in its own code

**Target:** `feat/azure-optional-subnet-ids` (PR #99, open, unreviewed)
**Findings:** 8 (blocker), 10, 11, 13
**Conflicts with:** prompt 2 and prompt 4, all three edit `infra/main.tf` or `variables.tf`

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

Create a git worktree on branch feat/azure-optional-subnet-ids (PR #99). Do not work in the
main checkout. The branch is open and unreviewed, so these fixes belong on it directly
rather than in a follow-up PR: all four are code this PR introduced.

Everything below is in modules/azure/infra. Full write-ups are in
~/Desktop/langsmith-azure-existing-cluster-walkthrough.md as findings 8, 10, 11, and 13.

FINDING 8 — blocker, fix this first.
The subnet capacity check counts node pools that the existing-cluster path never creates. A
customer attaching to a cluster in a /24 hit this: local.aks_required_ips was 764 against
local.aks_usable_ips of 251, and the deployment could not proceed.

main.tf:99-102 computes:
  aks_required_ips = sum(concat(
    [(var.default_node_pool_max_count + 1) * (var.default_node_pool_max_pods + 1)],
    [for pool in var.additional_node_pools : (pool.max_count + 1) * (local.aks_default_pool_max_pods + 1)]
  ))

Both terms are wrong when create_cluster = false:
  - The first term (11 x 61 = 671 at the defaults of 10 and 60) sizes a default node pool
    that lives inside azurerm_kubernetes_cluster.main, which is counted off at
    modules/k8s-cluster/main.tf:173 when create_cluster = false. Confirm this yourself:
    default_node_pool_max_count and default_node_pool_max_pods reach exactly two places,
    this calculation and k8s-cluster/main.tf:203 and :208 inside that counted-off resource.
  - The second term iterates var.additional_node_pools directly instead of the gated
    expression at main.tf:398, so existing_cluster_node_pools_managed = false does not
    reduce the requirement. The flag whose entire purpose is "do not touch my node pools"
    has no effect on the check that blocks the deployment.

Fix: count the default pool only when create_cluster = true, and iterate the gated map that
line 398 already computes. Extract that expression into a local so both places use it.
Creating a cluster must behave exactly as it does today. Attaching with managed pools should
check only the pools Terraform adds. Attaching without them should drop the requirement to
zero.

The wizard emits a comment at scripts/quickstart.sh:1379 stating that the node pool settings
are "still read, to size the AKS subnet check against the pools it actually runs." That
asserts the current behaviour is deliberate. Correct it in the same change.

FINDING 10 — aks_service_cidr is required when attaching and configures nothing.
service_cidr is set in one place, the network_profile block at k8s-cluster/main.tf:251,
inside the resource counted off when attaching. Its only consumers on that path are two
checks: main.tf:349 requires it non-empty, main.tf:358 rejects it if it overlaps the VNet.
Nothing compares it to the cluster's real networkProfile.serviceCidr.

So a plausible guess passes both checks and changes nothing, and a guess that lands inside
the customer's VNet blocks a valid deployment over a value with no effect.

Fix: read it from the cluster instead of requiring it. The value is at
networkProfile.serviceCidr, and networkProfile.dnsServiceIp gives the DNS IP (note the
lowercase p; dnsServiceIP returns null). A real service CIDR can never overlap its own VNet
because Azure will not create a cluster that way, so reading it satisfies both checks by
construction. If reading it inside Terraform reintroduces the deferred-data-source problem
that finding 2 covers, say so and propose requiring it with a postcondition comparing it to
the cluster instead.

FINDING 11 — the capacity error states a total with no arithmetic.
The message at main.tf:342 reports the two numbers and names two variables to lower, without
showing how the total was built. There is no way to tell which knob moves it, by how much, or
what subnet size would be enough, short of reading the module source.

Fix, after finding 8 is done, not before. Carry:
  - the per-pool breakdown that sums to the total
  - Azure's five reserved addresses per subnet
  - the smallest prefix that fits, computable as 32 - ceil(log(required + 5, 2))
  - each knob's sensitivity: lowering max_count by one frees (max_pods + 1) addresses,
    lowering max_pods by one frees (max_count + 1). At the defaults that is 61 and 11.

BEFORE designing this around a formatted table, settle an open question: does Terraform's
diagnostic renderer preserve explicit newlines in error_message? It is known to reflow the
text. Test it with a throwaway config containing a failing precondition and a multi-line
message, and read the actual rendering. If newlines are dropped, write the breakdown as prose
instead. Do not assume either way.

Also: default_node_pool_max_pods is hardcoded to 60 at scripts/quickstart.sh:1388 with no
prompt behind it, so the wizard cannot produce any other value for one of the two knobs the
message tells operators to lower. Give it a prompt.

FINDING 13 — AGIC and bastion are unavailable with a bring-your-own VNet.
Two checks block them, and the messages state the reason:
  main.tf:301  ingress_controller != "agic" || var.create_vnet
  main.tf:296  !var.create_bastion || var.create_vnet
Both say the same thing: the resource needs its own subnet and there is no input to supply
one. This is a plumbing gap, not an Azure limitation. The AGIC subnet is created at
modules/networking/main.tf:124 under count = var.enable_agic inside the VNet Terraform owns,
and local.agic_subnet_id is hardwired to module.vnet.subnet_agic_id at main.tf:68. The
bring-your-own subnet inputs cover aks, postgres, and redis only.

Fix: add agic_subnet_id and bastion_subnet_id variables, select them over the networking
module's outputs when create_vnet = false, and relax both checks to accept either a
Terraform-managed VNet or a supplied subnet ID. Match the validation and shape of the
existing bring-your-own subnet variables, including the regex validation on the ID format.

Do NOT try to make AGIC work on the attach path. It has a second blocker a subnet input
cannot clear: the add-on is a dynamic block inside azurerm_kubernetes_cluster.main at
k8s-cluster/main.tf:282, so enabling it means modifying a cluster Terraform does not own.
Leave the create_cluster = false rejection in place and make its error message say why.

VERIFY
  - terraform fmt -check -recursive modules/azure
  - terraform validate in modules/azure/infra
  - terraform plan against a tfvars with create_cluster = false and
    existing_cluster_node_pools_managed = false, and confirm the capacity check no longer
    fires on a /24-sized subnet
  - terraform plan with create_cluster = true and the defaults, and confirm the required
    address count is unchanged from today

CONSTRAINTS
  - Confirm the Azure subscription before any az or terraform command that touches Azure:
    az account show --query '{name:name,id:id}' -o json
  - Read-only in any subscription that is not ours. No applies without explicit approval.
  - Do not commit or push. Summarize what changed against this list and wait for review.
  - Do not add yourself as a commit co-author.
```

---

## Prompt 2 — PR #95: four findings in its own code

**Target:** `feat/azure-byoc-existing-cluster` (PR #95, open, unreviewed)
**Findings:** 2, 4, 5, and the plan-time half of 3
**Conflicts with:** prompt 1 and prompt 4

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

Create a git worktree on branch feat/azure-byoc-existing-cluster (PR #95). Do not work in
the main checkout. The branch is open and unreviewed, so these fixes belong on it directly:
all four are code this PR introduced.

Everything below is in modules/azure/infra. Full write-ups are in
~/Desktop/langsmith-azure-existing-cluster-walkthrough.md as findings 2, 3, 4, and 5.

FINDING 2 — four existing-cluster guards never run at plan time. Fix this first.
Terraform defers the cluster data source to apply:
  # module.aks.data.azurerm_kubernetes_cluster.existing[0] will be read during apply
  # (depends on a resource or a module with changes pending)

modules/k8s-cluster/main.tf:58 falls back to var.resource_group_name, which main.tf:381
supplies as azurerm_resource_group.resource_group.name, a resource pending creation. The
data source reads that local, so Terraform draws a dependency edge to the pending resource
group. Dependency edges come from static references in the config, built before evaluation,
so the ternary selecting the known branch does not remove the edge.

Deferred as a result: node subnet membership (k8s-cluster/main.tf:117), OIDC issuer (:106),
workload identity (:135, which cascades because the azapi data source reads the deferred
cluster's id), and the existing_cluster_location check (:149).

This is confirmed in both directions. On a fresh plan the read is deferred and the region
check warns "condition could not be evaluated at this time". On a plan run after the
resource group exists in state, the deferral and the warning both disappear and every
postcondition evaluates. So the guards work only once you no longer need them, and go quiet
on exactly the first run where a customer's config is most likely wrong. That contradicts
this PR's own stated purpose.

Fix: resolve the fallback in the root against a local that is already a plain string, and
drop the fallback from k8s-cluster/main.tf:58. What the fallback resolves to must not change.
Verify by planning from empty state and confirming the data source is NOT deferred and all
four checks evaluate.

Consider, and recommend either way: requiring existing_cluster_resource_group_name when
create_cluster = false, alongside the existing existing_cluster_name precondition. The
fallback is meaningless where it triggers, since on a fresh apply it means "assume the
customer's existing cluster lives in the resource group Terraform is about to create." That
is a contract change, so treat the two-line fix as the default and the requirement as a
proposal.

FINDING 4 — node pools default to Terraform-managed on someone else's cluster.
existing_cluster_node_pools_managed at variables.tf:147 defaults to true, so attaching adds
a "large" pool of Standard_D16s_v3 to a cluster the README describes as one Terraform never
modifies. Those two statements disagree and the default is the surprising one.

Fix: flip the default to false. Check every tfvars template and example for the key and
update them. Note in the variable description that Terraform never adopts existing pools; it
only ever adds new ones, so false means the customer's pools run everything.

FINDING 5 — create_cluster = false silently forces create_vnet = false.
variables.tf:120 documents that Terraform still provisions networking "when
create_vnet = true" under an attached cluster. It cannot: a subnet Terraform is about to
carve can never satisfy the node subnet postcondition at k8s-cluster/main.tf:117, which
requires a subnet the cluster already runs nodes in. The combination the comment describes
has no working configuration, and today it fails on an unrelated postcondition instead of
saying so.

Fix: correct the comment, and add a precondition rejecting create_cluster = false with
create_vnet = true, with an error message naming the real reason.

FINDING 3, plan-time half — make aks_subnet_id required when create_cluster = false.
It cannot be carved, so accepting a blank value is accepting a broken configuration. Today a
customer who leaves it blank gets a clean plan and a partial apply, because the postcondition
that would catch it is the one finding 2 defers. Add a precondition rejecting a blank
aks_subnet_id when create_cluster = false.

Leave the wizard side of finding 3 alone. It is handled in a separate follow-up PR that
depends on #96, #98, and #99, none of which this branch has.

VERIFY
  - terraform fmt -check -recursive modules/azure
  - terraform validate in modules/azure/infra
  - Plan from empty state with create_cluster = false and confirm the cluster data source is
    read at plan time, not deferred, and that all four checks in finding 2 evaluate
  - Plan with a blank aks_subnet_id and confirm it is rejected with the new message
  - Plan with create_cluster = false and create_vnet = true and confirm the new precondition
    fires instead of the node subnet postcondition
  - Plan with create_cluster = true and confirm nothing about that path changed

CONSTRAINTS
  - Confirm the Azure subscription before any az or terraform command that touches Azure:
    az account show --query '{name:name,id:id}' -o json
  - Read-only in any subscription that is not ours. No applies without explicit approval.
  - Do not commit or push. Summarize what changed against this list and wait for review.
  - Do not add yourself as a commit co-author.
```

---

## Prompt 3 — the Postgres parameter fix, its own PR off main

**Target:** new branch off `main`
**Finding:** 0 (blocker)
**Conflicts with:** nothing. No open PR touches this file.
**Note:** the fix is already written and verified, committed on `preview/azure-stack-94-99`
as `87e7ca2`. This prompt is mostly "lift it onto a clean branch and open the PR."

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

Create a git worktree on a new branch off origin/main named
fix/azure-postgres-connection-throttle. Do not work in the main checkout.

Land one already-verified fix as its own PR. It is independent of the six open Azure PRs and
should not wait behind them.

THE BUG
modules/azure/infra/modules/postgres/main.tf:145 sets a server parameter named
connection_throttling. No such parameter exists on any supported PostgreSQL version. Azure
rejects it:
  Status:  "ParameterNotExists"
  Message: "Server parameter 'connection_throttling' is invalid or isn't supported in
            PostgreSQL version '14'."

postgres_version defaults to "14" at modules/postgres/variables.tf:32 and the root never
overrides it, so this broke every apply with postgres_source = "external", on every cloud
path, attaching or creating a cluster. It failed late, after the server was already Ready,
leaving a working database and a red apply.

THE FIX
The correct name is connection_throttle.enable, confirmed against a live server with
az postgres flexible-server parameter list. Verified working: the corrected parameter created
in 34 seconds where the old name failed.

The exact change is already committed on branch preview/azure-stack-94-99 as commit 87e7ca2.
Cherry-pick it, or reproduce it:

  resource "azurerm_postgresql_flexible_server_configuration" "connection_throttling" {
    # Azure names this parameter connection_throttle.enable. "connection_throttling"
    # does not exist on any supported version and the API rejects it with
    # ParameterNotExists, after the server itself has already been created.
    name      = "connection_throttle.enable"
    server_id = azurerm_postgresql_flexible_server.db.id
    value     = "on"
  }

WHILE YOU ARE THERE
Check whether AWS and GCP set the same parameter under the wrong name. This is a Postgres
API fact, not an Azure one, so grep the whole repo for connection_throttling before opening
the PR. If the other clouds have the same bug, fix them in this PR and say so in the
description.

VERIFY
  - terraform fmt -check -recursive modules/azure
  - grep the repo to confirm no connection_throttling remains anywhere
  - If a subscription is available, apply a Postgres server with postgres_source = "external"
    and confirm the configuration resource creates. This needs explicit approval first.

CONSTRAINTS
  - Confirm the Azure subscription before any az or terraform command that touches Azure.
  - No applies without explicit approval.
  - Do not commit or push without approval. Summarize and wait.
  - Do not add yourself as a commit co-author.
```

---

## Prompt 4 — the two dead deletion-protection variables

**Target:** new branch off `main`
**Finding:** 6
**Conflicts with:** prompts 1 and 2 both edit `infra/variables.tf`

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

Create a git worktree on a new branch off origin/main. Do not work in the main checkout.

THE BUG
modules/azure/infra/variables.tf:365 and :371 declare aks_deletion_protection and
postgres_deletion_protection. Both are set in every tfvars template and documented as
destroy blockers. Nothing reads either one. A grep across every .tf in the module finds no
other reference, and no lifecycle block uses them. Anyone relying on them for protection has
none.

DECIDE, THEN DO ONE
Option A, wire them up. Terraform's prevent_destroy takes a literal, not a variable, so a
plain lifecycle block cannot read these. Investigate what actually works: the azurerm
provider may expose a resource-level protection setting for AKS and Postgres Flexible
Server, or the honest answer may be that the behaviour these variables promise is not
expressible. Report what you find before writing code.

Option B, delete them. Remove both variables, every reference in tfvars templates and
examples, and any documentation that claims they protect anything.

Recommend one with the reasoning. A flag that silently does nothing is worse than no flag,
so B is acceptable and preferable to a half-fix that still misleads.

CHECK THE OTHER CLOUDS
Grep for deletion_protection across the whole repo. If AWS and GCP have the same dead
variables, cover them here or file the follow-up, and say which you did.

CONFLICT WARNING
Two open PRs, #95 and #99, also edit modules/azure/infra/variables.tf. Keep this change
minimal and confined to the two variables so the rebase is trivial.

VERIFY
  - terraform fmt -check -recursive
  - terraform validate in modules/azure/infra
  - grep to confirm no orphaned references remain in any template or doc

CONSTRAINTS
  - Do not commit or push without approval. Summarize and wait.
  - Do not add yourself as a commit co-author.
```

---

## Prompt 5 — reuse an existing Key Vault

**Target:** new branch off `main`
**Finding:** 14
**Conflicts with:** nothing

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

Create a git worktree on a new branch off origin/main. Do not work in the main checkout.

THE GAP
A customer asked to reuse their existing Key Vault. There is no way to. No key_vault_id
input, no data "azurerm_key_vault" anywhere in the module, and azurerm_key_vault.langsmith
at modules/azure/infra/modules/keyvault/main.tf:34 has no count. The module call at
modules/azure/infra/main.tf:517 is unconditional, so a vault is always created, in the
resource group Terraform makes rather than the customer's.

CONTEXT THAT SHAPES THE DESIGN
The vault is not a runtime dependency. Pods do not mount from it. Terraform writes about ten
secrets in and scripts/setup-env.sh reads them back on later runs, at setup-env.sh:136, so
nobody keeps local .secret files. The comment at modules/keyvault/main.tf:88 is explicit that
pod read access is "currently used by setup-env.sh, and ready for the CSI Secrets Store
driver in Phase 2." So this buys the customer ownership and audit alignment, not the removal
of a coupling. Size the work accordingly.

THE FIX
Same shape as the existing bring-your-own subnet inputs: a key_vault_id variable with regex
validation on the ID format, a data source read when it is set, count on the resource, and a
local selecting between them. The ten secrets and both role assignments hang off the local
rather than the resource.

PREREQUISITES TO ENFORCE OR DOCUMENT
  - RBAC authorization mode must already be on. The module grants Key Vault Secrets Officer
    and Key Vault Secrets User by role assignment, which does nothing on a vault in
    access-policy mode. Add a postcondition on the data source checking
    rbac_authorization_enabled and failing with a clear message.
  - Data plane reachability is the real friction. The comment at
    modules/keyvault/main.tf:56 explains that network_default_action defaults to Allow
    because the first apply writes those ten secrets through the data plane and gets 403'd
    under Deny. A customer's production vault is almost certainly on Deny. Document that
    reusing a vault means allowlisting the deploying IP for the length of the apply, and
    make the error message say so if the writes fail.

DO NOT
Do not suggest terraform import as an alternative path anywhere in the code or docs.
Adopting a customer's vault into this resource address pushes rbac_authorization_enabled =
true from modules/keyvault/main.tf:43 and network_acls from :61 onto a shared resource,
dropping every existing access policy and replacing their ip_rules. Both are silent.

VERIFY
  - terraform fmt -check -recursive modules/azure
  - terraform validate in modules/azure/infra
  - Plan with key_vault_id unset and confirm the plan is byte-identical to today's
  - Plan with key_vault_id set and confirm no azurerm_key_vault resource is created, the
    data source is read, and all ten secrets plus both role assignments target it
  - An apply against a real reused vault needs explicit approval. Ask.

CONSTRAINTS
  - Confirm the Azure subscription before any az or terraform command that touches Azure.
  - Read-only in any subscription that is not ours. No applies without explicit approval.
  - Do not commit or push without approval. Summarize and wait.
  - Do not add yourself as a commit co-author.
```

---

## Prompt 6 — let a platform team opt out of cluster-scoped add-ons

**Target:** new branch off `main`
**Finding:** 15
**Conflicts with:** PR #100, which is already making the `enable_*` flags authoritative.
Read that PR before starting.

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

Create a git worktree on a new branch off origin/main. Do not work in the main checkout.

FIRST: read PR #100 (fix/app-authoritative-component-toggles). It is making the enable_*
flags authoritative, which is the same class of problem. If it already covers this, say so
and stop rather than duplicating it.

THE PROBLEM
A customer wants their platform team to own the cluster while LangSmith is deployed as an
app. The module is most of the way there already: with create_cluster = false it creates 55
resources and zero managed cluster, VNet, subnet, or node pool resources. What is in the way
is that three cluster-scoped components sit on the app side of the boundary, and two cannot
be turned off.

  modules/azure/infra/modules/k8s-bootstrap/main.tf:262  helm_release.cert_manager, no count
  modules/azure/infra/modules/k8s-bootstrap/main.tf:363  helm_release.keda, no count
  modules/azure/infra/modules/k8s-bootstrap/main.tf:323  kubernetes_manifest.cluster_issuer_dns01

cert-manager and keda both install CRDs cluster-wide and install unconditionally. A platform
team that owns a cluster is already running cert-manager, and there is no flag to stop the
module installing a second one. The ingress controller is fine already: nginx is counted at
modules/k8s-cluster/main.tf:381 and ingress_controller = "none" is a valid value.

Namespace-scoped resources in the same file are correct as they are: the namespace, service
account, resource quota, limit range, two network policies, and four secrets.

THE FIX
Add inputs for "the cluster already provides this" and count both helm releases on them.
For cert-manager, accepting an existing installation also means accepting an existing
ClusterIssuer by name rather than creating one, since tls_certificate_source = "dns01" builds
its own at :323. Work out what the chart needs referenced and thread it through.

THEN, THE MORE VALUABLE HALF
Write down the handoff contract as documentation: the facts the app root needs from whoever
owns the cluster. From the audit that is roughly eight items: cluster name and resource group
(or the OIDC issuer URL directly), node subnet ID, VNet ID, service CIDR, region, and which
of cert-manager, an ingress controller, and keda already exist. Publish it as a documented
input set so a customer's existing cluster repo can emit it however it likes, whether from
terraform_remote_state, a tfvars file, or by hand.

Do not split the Terraform roots. The backend in modules/azure/infra/backend.tf is commented
out, so there is no remote state wiring to build on, and the contract above is a prerequisite
for any split anyway. Note that as a follow-up rather than doing it.

SCOPE NOTE
The existing infra/ and app/ boundary is Terraform-versus-Helm, not foundation-versus-app.
Do not restructure it. This change makes the current attach path acceptable to a platform
team, which is the goal.

VERIFY
  - terraform fmt -check -recursive modules/azure
  - terraform validate in modules/azure/infra
  - Plan with the new flags unset and confirm the plan is byte-identical to today's
  - Plan with each flag set and confirm the corresponding helm_release disappears from the
    plan and nothing else changes
  - Confirm nothing else in the module depends on the cert-manager or keda releases by
    reference, which would break when they are counted to zero

CONSTRAINTS
  - Confirm the kubectl context before any kubectl or helm command: kubectl config current-context
  - Read-only in any cluster that is not ours. No applies or helm installs without explicit approval.
  - Do not commit or push without approval. Summarize and wait.
  - Do not add yourself as a commit co-author.
```

---

## Prompt 7 — the wizard follow-up (BLOCKED)

**Target:** new branch, after #95, #96, #98, and #99 have all merged
**Findings:** 1, 9, 12, 16
**Blocked because:** the work builds on `_load_tfvars` from #98, `_ask_subnet` from #99, and
`NAME_PREFIX` from #96, and #95 does not touch `quickstart.sh` at all. It cannot go on any
single one of them.
**Note:** finding 1 is already written and verified, committed on
`preview/azure-stack-94-99` as `5af042f`. Start from that commit.

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

PRECONDITION: confirm PRs #95, #96, #98, and #99 have all merged to main before starting.
If any is still open, stop. This work depends on all four and cannot be split across them.

Create a git worktree on a new branch off origin/main. Do not work in the main checkout.

Everything is in modules/azure/infra/scripts/quickstart.sh. Full write-ups are in
~/Desktop/langsmith-azure-existing-cluster-walkthrough.md as findings 1, 9, 12, and 16.

START HERE
Commit 5af042f on branch preview/azure-stack-94-99 already implements finding 1, tested and
verified against a live deployment. Cherry-pick it, then build the rest on top. It adds the
four cluster keys (create_cluster, existing_cluster_name,
existing_cluster_resource_group_name, existing_cluster_node_pools_managed) to _STATE_KEYS,
the prompts, _load_tfvars, and the writer, with validation at both the prompt and the
file-ingestion point.

That second validation point is not optional. Values read back out of an existing
terraform.tfvars with sed reach the writer having never passed a prompt, and the writer
interpolates them into double-quoted HCL that Terraform then applies with the deploying
identity's credentials. Keep validation on both paths for anything you add.

FINDING 9 — the attach path asks for values Azure already holds.
One az aks show returns every value the wizard prompts for on this path plus every
prerequisite the module checks. Verified:

  az aks show -n <cluster> -g <rg> --query "{
    nodeSubnet: agentPoolProfiles[0].vnetSubnetId,
    serviceCidr: networkProfile.serviceCidr,
    dnsServiceIp: networkProfile.dnsServiceIp,
    oidc: oidcIssuerProfile.enabled,
    workloadIdentity: securityProfile.workloadIdentity.enabled,
    localAccounts: disableLocalAccounts,
    networkPolicy: networkProfile.networkPolicy,
    pools: agentPoolProfiles[].{name:name, vmSize:vmSize, min:minCount, max:maxCount, maxPods:maxPods, mode:mode}
  }" -o json

Of the nine questions sections 3 and 4 ask when attaching, three are genuine (cluster name,
resource group, manage node pools), two cause paste errors for no reason (VNet ID, node
subnet ID), and four configure nothing (service CIDR, node pool vm_size, min, max).

The paste error is real, not hypothetical: a customer pasted the VNet ID into the node subnet
prompt, because that question comes immediately before and the two IDs are prefixes of each
other. The rejection at the equivalent of quickstart.sh:475 only restates the expected format
and offers nothing to pick from.

Fix: after the cluster name and resource group, run one lookup and show a confirmation screen
instead of continuing to ask. Prerequisites and derived values together, where the operator
can still act on them, rather than in preflight after the tfvars are written. Skip the node
pool section entirely when existing_cluster_node_pools_managed is false, and set
additional_node_pools = {} rather than making the operator discover it.

Two details. The field is networkProfile.dnsServiceIp with a lowercase p; dnsServiceIP
silently returns null. And the DNS IP is the service CIDR's tenth host, which is what the
root derives with cidrhost(..., 10), so reading the service CIDR gets the DNS IP for free.

Fall back gracefully when the lookup returns nothing, which happens on a kubenet cluster with
no explicit subnet, without read permission, or with az pointed at another subscription. In
that case print portal deep links built from the IDs already in hand:
  https://portal.azure.com/#resource<cluster id>/nodePools
  https://portal.azure.com/#resource<vnet id>/subnets
The resource ID composition is confirmed against live resources. The blade suffixes are not,
so verify them; bare #resource<id> lands on the overview if a suffix is wrong. The repo has
no portal links anywhere today, so this sets the convention.

FINDING 16 — ask whether they have a subnet before asking for its ID.
Raised by a customer directly: "we should ask if you already have subnets or if we want to
create them for you." The capability exists, since #99 made bring-your-own subnet IDs
optional per subnet, but the question never asks. The prompt reads:

  ${label} subnet resource ID (Enter = let Terraform create it)

The choice is a parenthetical on a prompt whose subject is a resource ID, so an operator sees
a request for an ID they have to go find, and the alternative reads as a hint about
keystrokes. It gets worse across the three prompts, because they do not behave alike: when
attaching, the AKS subnet is required and the parenthetical is dropped entirely, while
Postgres and Redis keep it, with nothing on screen explaining the difference.

Fix: ask the question first, then the ID.
  Do you already have a subnet for PostgreSQL, or should Terraform create one? [have/create]
Where the AKS subnet has no create option on the attach path, say why rather than silently
dropping it: the subnet has to be one the cluster already runs nodes in, and a subnet
Terraform is about to carve never is. Once the cluster lookup from finding 9 lands, the AKS
subnet is not a question at all and only the two subnets with a real choice remain.

FINDING 12 — warn when the customer's pools cannot run LangSmith.
The module validates seven things about an attached cluster and none is capacity. ClickHouse
requests 3.5 vCPU and 15 GiB. On a Standard_D4s_v3 the live nodes report cpu=3860m and
mem=14992436Ki allocatable, which is 14.3 GiB: about 700 MiB short, so ClickHouse cannot
schedule. That cluster passes all seven prerequisite checks.

Fix: compare each pool's allocatable capacity against the request and warn before the tfvars
are written. This belongs in the wizard, not Terraform, because mapping a VM SKU to
allocatable capacity needs an az call. Get the pool inventory from the same az aks show above.
Decide how to obtain allocatable capacity per SKU and say which approach you chose: az vm
list-skus gives raw vCPU and memory, and kube-reserved has to be subtracted, so a live
kubectl read of node allocatable is more accurate when credentials are available. Prefer
accuracy and degrade to an estimate with a clearly labelled caveat.

Make it a warning, not a hard stop. The customer may be about to resize their pools.

VERIFY
  - bash -n on the script
  - Drive the wizard through the attach path without a tty, seeding .quickstart-state and
    piping answers, and confirm it emits all four cluster keys plus the network keys. Back up
    and restore terraform.tfvars with a trap; it is live config for any deployed stack.
  - terraform plan against the generated tfvars and confirm zero precondition or validation
    errors
  - Confirm a re-run reads its own output back correctly, since the writer truncates
    terraform.tfvars with cat > and a resume path that loses keys is the original bug
  - make test-quickstart if it exists

CONSTRAINTS
  - This script handles operator input that reaches HCL. Treat prompt handling and file
    ingestion as a security-relevant surface and validate at both points.
  - Confirm the Azure subscription before any az command: az account show --query '{name:name,id:id}' -o json
  - Confirm the kubectl context before any kubectl command: kubectl config current-context
  - Read-only in any cluster or subscription that is not ours.
  - Do not commit or push without approval. Summarize and wait.
  - Do not add yourself as a commit co-author.
```

---

## Prompt 8 — Azure test scaffolding and a credentialed CI job

**Target:** the fixture goes on `feat/azure-byoc-existing-cluster` (#95); the CI job is its
own PR off `main`
**Finding:** 7
**Note:** the fixture is already written and applied, committed on
`preview/azure-stack-94-99` as `f79f799`.

```
Work in the langchain-ai/terraform repo at /Users/michaelfrederick/Documents/Github/langchain-ai/terraform.

Create a git worktree. Do not work in the main checkout.

THE GAP
Azure has no test scaffolding. No prereq module, no runnable examples, and CI runs only
format, lint, and scan with no plan or apply step. AWS has test-permutations.sh,
test-orchestrator.sh, and test-worker.sh. Azure had test-quickstart-state.sh, a unit test that
creates no Azure resources. Every existing-cluster check needs a real subscription and a real
cluster to exercise, so none of it reproduces offline.

PART 1 — the fixture, onto PR #95
Already written, applied, and verified. Commit f79f799 on branch preview/azure-stack-94-99
adds modules/azure/test/existing-aks-cluster: a Terraform stack creating an AKS cluster,
VNet, and three subnets configured the way the attach path requires. OIDC issuer and workload
identity on, local accounts left enabled, a Postgres subnet delegated to
Microsoft.DBforPostgreSQL/flexibleServers, and an undelegated Redis subnet with private
endpoint network policies disabled. Six resources in one resource group, so teardown is a
single az group delete. Its langsmith_tfvars output emits the attach half of terraform.tfvars
directly.

Cherry-pick it onto feat/azure-byoc-existing-cluster, since it is the test for that PR's
feature and depends on nothing else. Confirm modules/azure/.gitignore still excludes
*.tfstate so a local state file cannot be committed.

PART 2 — the credentialed CI job, its own PR off main
Ten negative tests were written for this exercise, covering checks across PRs #94 through
#99: an undelegated Postgres subnet, a node subnet missing service endpoints, three subnet
IDs pointing at one subnet, a node pool scaled past the subnet's addresses, a service CIDR
overlapping the VNet, an empty service CIDR, istio-addon under create_cluster = false, and
create_bastion and agic under create_vnet = false. Nine of the ten reject a bad config at
plan time. The tenth is the deferred-data-source finding.

Every one needs credentials, so they belong in a job with a subscription rather than the
format-and-lint pass. Build that job, modelled on how AWS structures its test scripts.

One implementation detail that will bite you: Terraform reflows error_message text across
lines, so matching on an expected message fails unless you normalize whitespace first.
Collapse it before comparing:
  flat=$(printf '%s' "$out" | tr -s '[:space:]' ' ')

Also wire up make test-quickstart if it is not already in CI.

VERIFY
  - The fixture plans and validates on the #95 branch
  - Each negative test fails the plan for the reason intended, not an unrelated one. A test
    that passes for the wrong reason is worse than no test.
  - The job is skipped cleanly rather than failing when no subscription is configured, so
    forks and external contributors are not blocked

CONSTRAINTS
  - Confirm the Azure subscription before any az or terraform command: az account show --query '{name:name,id:id}' -o json
  - Applying the fixture creates real billable resources. Get explicit approval first, and
    tear down when done.
  - Do not commit or push without approval. Summarize and wait.
  - Do not add yourself as a commit co-author.
```

---

## Coverage check

| Finding | Prompt |
|---|---|
| 0 Postgres parameter name | 3 |
| 1 Wizard cannot express the deployment | 7 (already written) |
| 2 Guards never run at plan time | 2 |
| 3 Wizard invites a rejected subnet choice | 2 (plan-time) + 7 (wizard) |
| 4 Node pools default to managed | 2 |
| 5 create_vnet silently forced | 2 |
| 6 Dead deletion-protection variables | 4 |
| 7 No test scaffolding | 8 (fixture already written) |
| 8 Capacity check counts phantom pools | 1 |
| 9 Asks for values Azure holds | 7 |
| 10 Service CIDR configures nothing | 1 |
| 11 Capacity error has no arithmetic | 1 |
| 12 No pool capacity check | 7 |
| 13 AGIC and bastion under BYO VNet | 1 |
| 14 No existing Key Vault | 5 |
| 15 Cluster-scoped add-ons unavoidable | 6 |
| 16 Have-or-create question hidden | 7 |
