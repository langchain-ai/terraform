# SmithDB on Azure

SmithDB support on Azure is optional and starts at the LangSmith chart 0.17
line. Set `enable_smithdb = true` to provision its Azure dependencies
independently of the LangSmith application database and trace-blob account.

## Version requirements

Two version numbers apply here, and they are not the same thing.

**LangSmith chart: a stable release on the 0.17 line, selected explicitly.**
The 0.17 line is the first with both the Azure SmithDB values and the per-pod
cache PVC contract. `deploy.sh` accepts `0.17.x` only. It rejects 0.16, because
the Azure values are absent there, and it rejects 0.18, because the module pins
a chart line and never crosses a minor on its own.

Deploy a released 0.17 patch, using a `~0.17.0` constraint to take the newest
one. Helm leaves prereleases out of a constraint like that, so it selects only
stable releases. Naming a prerelease exactly does install it, and that is not a
supported configuration: an RC carries an unreleased application image, so a
problem found on one cannot be told apart from a problem in the module.

No stable 0.17 chart exists yet. `~0.17.0` therefore resolves to nothing today,
and `helm search repo langchain/langsmith --versions` lists 0.17 only under
`--devel`. Treat the constraint above as what to use once 0.17 ships, and
enable SmithDB on Azure after that.

**Module tag: still `v0.16.*`.** The Azure module ships on the 0.16 tag series,
where the default chart pin is `~0.16.0`. So on a `v0.16.*` tag, SmithDB needs
`langsmith_helm_chart_version` set explicitly. `enable_smithdb = true` with no
chart version fails the deploy rather than installing a chart without SmithDB
support. Deployments that leave `enable_smithdb = false` are unaffected and
stay on the 0.16 pin.

This split is temporary. When the module line moves to 0.17, SmithDB becomes an
ordinary feature of the pinned line, the explicit selection is no longer needed,
and this section goes away.

## Infrastructure

The Terraform root creates:

- a dedicated private Azure Database for PostgreSQL Flexible Server 18 and an
  empty `smithdb` database;
- a dedicated Blob Storage account and private container. Shared Key stays
  enabled so the chart's optional static-key path
  (`smithdb.config.objectStore.azure.accessKeySecretKey`) remains available.
  The default runtime path does not use it;
- a SmithDB-only user-assigned identity, federated to the chart-owned SmithDB
  Kubernetes ServiceAccount and scoped to `Storage Blob Data Contributor` on
  that account. Set `smithdb_migration_enabled = true` and the identity also
  receives `Storage Blob Data Reader` on the LangSmith trace-blob account, which
  is the source the historical backfill reads. The grant exists only while that
  flag is on, so a steady-state install leaves the identity able to reach
  nothing but its own account; and
- a Premium SSD v2 StorageClass for per-pod cache volumes. SmithDB workloads
  schedule on ordinary AKS nodes by default. The StorageClass is cluster-scoped,
  so its name carries the deployment suffix unless
  `smithdb_cache_storage_class_name` names one.

By default, the same SmithDB workload identity authenticates to PostgreSQL
through Microsoft Entra ID and is configured as the Flexible Server's Entra
administrator. This avoids a static database password and the separate SQL
bootstrap step that a less-privileged Entra principal would require.

To use password authentication instead, supply the password outside committed
tfvars. Because Terraform creates the server, that password is stored in
Terraform state:

```bash
export TF_VAR_smithdb_metastore_admin_password='<strong-random-password>'
terraform -chdir=infra apply
```

The metastore Secret is created in the LangSmith namespace before Helm runs. In
Entra mode it contains only the host, database, and username; the chart sets
`iamAuthProvider: azure`. Object-store access also uses Azure Workload Identity,
so no Storage Account key or SAS token is written to Kubernetes or Terraform
outputs.

Azure RBAC does not take effect the moment the grant is created. A blob
data-plane role change needs up to 10 minutes, and the backfill runs from a
separate Helm pass that an operator can start straight after `terraform apply`
returns. So the apply that creates the `Storage Blob Data Reader` grant waits
300 seconds before it hands control back, in
`time_sleep.smithdb_trace_blob_reader_propagation`. The pause is deliberate. Let
it finish.

The wait shortens this race and does not remove it. A backfill that reads the
source account before the grant is effective fails with 403 responses that look
the same as a missing grant. Confirm the assignment exists with
`az role assignment list`, wait, and retry before you treat the 403 as a defect.

Setting `smithdb_migration_enabled` back to false removes the grant. A backfill
that has to run again needs the flag on again, and waits again.

## Chart contract

The chart 0.17 line supports Azure as a SmithDB object-store provider and
per-pod cache PVCs. `make init-values` generates the overlay from
`smithdb_storage_account_name` and `smithdb_storage_container_name`, annotates
the SmithDB ServiceAccount with `azure.workload.identity/client-id` from
`smithdb_workload_identity_client_id`, and labels SmithDB pods with
`azure.workload.identity/use: "true"`.

Select the chart line explicitly alongside the flag, as described in
[Version requirements](#version-requirements):

```hcl
enable_smithdb               = true
langsmith_helm_chart_version = "~0.17.0"
```

The chart is intentionally a separate deployment pass: `terraform apply`
provisions the Azure and Kubernetes prerequisites but does not install
LangSmith itself.

The federated identity subject is derived with the same fullname convention as
the chart. For example, release `langsmith` uses `langsmith-smithdb`, while
release `prod` uses `prod-langsmith-smithdb`.

## Network and sizing notes

By default the Storage Account firewall admits the AKS subnet through its
`Microsoft.Storage` service endpoint. The account keeps its public endpoint and
denies all other traffic.

Set `storage_private_endpoint_enabled = true` to replace that with a Private
Endpoint and turn the public endpoint off. The setting covers the LangSmith
trace-blob account as well, so the two accounts never end up with different
postures. SmithDB keeps using the same account hostname, which then resolves to
a VNet address through the `privatelink.blob.core.windows.net` zone. Supply
`storage_private_dns_zone_id` when the VNet already resolves that zone; Azure
links a zone name to a VNet once, so creating a second one fails.

PostgreSQL uses the delegated database subnet and the VNet's private PostgreSQL
DNS zone. Each Private Endpoint takes one further address in its subnet.

SmithDB pods run on the default node pool, so they consume its pod and IP
budget rather than adding a pool of their own. The subnet capacity check counts
`(default_node_pool_max_count + 1) * (default_node_pool_max_pods + 1)`, which is
a per-node reservation and already covers anything scheduled onto those nodes.
What SmithDB does change is how much of that budget is in use, so size the
default pool for the SmithDB pod count the chart adds and raise
`default_node_pool_max_count` before enabling ingestion. The capacity check then
follows the new maximum on its own. Use `additional_node_pools` with chart
scheduling overrides when SmithDB needs isolation from the rest of LangSmith.

Terraform creates the cache StorageClass with 7,000 IOPS and 1,000 MB/s. The
generated Helm overrides select it for SmithDB's per-pod cache PVCs.
`smithdb_cache_disk_iops` and `smithdb_cache_disk_throughput_mbps` tune it,
within two Azure limits: throughput cannot exceed 0.25 MB/s per provisioned IOPS
(the root module rejects that combination at plan time), and IOPS is capped by
volume size, which rises 500 IOPS per GiB above 6 GiB. Cache volume size is a
chart value, so Terraform cannot check the second limit.

Premium SSD v2 is what makes zones a requirement rather than a preference. In
most regions that offer availability zones, a Premium SSD v2 disk attaches only
to a zonal VM, so `enable_smithdb = true` requires `availability_zones` to name
at least one zone. The root module refuses the combination at plan time, because
AKS zones apply at creation and carry `ignore_changes` - recovering from a
nonzonal pool means rebuilding it, not editing a variable. A
[small set of regions](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-deploy-premium-v2#nonzonal-premium-ssd-v2-deployments)
does support nonzonal Premium SSD v2.

On an attached AKS cluster, set `availability_zones` to the zones the existing
nodes already use, and confirm those nodes are zonal before enabling SmithDB.

Adding zones to an already-built cluster does not re-zone it. The module ignores
zone changes on an existing node pool, so the plan comes back clean, the
precondition above is satisfied, and the nodes stay where they were. The
`aks_node_pool_zone_drift` check reports this as a plan warning naming the live
zones against the requested ones. Read that warning: a nonzonal pool with
SmithDB enabled gets a cache StorageClass no pod can bind to. Re-zoning means
rebuilding the pool.

## Pre-apply review

Run the normal local gate:

```bash
bash agents/check.sh modules/azure/infra
```

Before a real apply, also confirm:

- PostgreSQL 18 and the selected Flexible Server SKU are available in the
  chosen region;
- Premium SSD v2 is available in the chosen region, and the AKS nodes are zonal.
  In most regions that offer availability zones a Premium SSD v2 disk attaches
  only to a zonal VM, so `availability_zones` has to name the zones the nodes
  run in. Zones apply at cluster creation, so an existing nonzonal pool needs
  rebuilding rather than a variable change;
- the default node pool is sized for the SmithDB pods the chart adds, and the
  AKS subnet holds every pool at maximum scale; and
- the chart PR's Azure provider values and workload-identity annotations match
  the outputs listed above.
