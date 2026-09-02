# SmithDB on Azure

SmithDB support is optional and targets LangSmith chart 0.17 or newer. Set
`enable_smithdb = true` to provision its Azure dependencies independently of
the LangSmith application database and trace-blob account.

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
- two autoscaling, tainted AKS node pools: `smithcache` uses the VM temporary
  disk for SmithDB's local cache and `smithcompute` hosts compute workloads.

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

Azure RBAC does not take effect the moment `terraform apply` returns. A backfill
started in the first minutes after the Reader grant is created can fail with 403
responses that look the same as a missing grant. Confirm the assignment exists
with `az role assignment list`, then retry before you treat the 403 as a defect.

## Chart contract

Chart 0.17 must support Azure as a SmithDB object-store provider. `make
init-values` generates the overlay from
`smithdb_storage_account_name` and `smithdb_storage_container_name`, annotates
the SmithDB ServiceAccount with `azure.workload.identity/client-id` from
`smithdb_workload_identity_client_id`, and labels SmithDB pods with
`azure.workload.identity/use: "true"`.

The Azure module remains pinned to chart 0.16 by default. Select chart 0.17
explicitly when enabling SmithDB:

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
DNS zone. SmithDB increases AKS subnet IP demand; the root module includes both
node pools in its capacity check. Each Private Endpoint takes one further
address in its subnet.

`Standard_L16s_v3` is the default cache VM because it has a large local NVMe
temporary disk. Confirm that the SKU and capacity are available in the target
region. Changing to a VM without a suitable temporary disk defeats the local
cache design even if AKS accepts the node-pool configuration.

For an attached AKS cluster, Terraform creates the SmithDB pools only when
`existing_cluster_node_pools_managed = true`. Otherwise create equivalent pools
outside this root, with the labels and taints shown in `infra/main.tf`, before
enabling SmithDB in Helm.

## Pre-apply review

Run the normal local gate:

```bash
bash agents/check.sh modules/azure/infra
```

Before a real apply, also confirm:

- PostgreSQL 18 and the selected Flexible Server SKU are available in the
  chosen region;
- the cache VM has adequate temporary-disk capacity;
- the AKS subnet has room for both pools at maximum scale; and
- the chart PR's Azure provider values and workload-identity annotations match
  the outputs listed above.
