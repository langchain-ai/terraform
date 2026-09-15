# SmithDB on Azure

SmithDB support is optional and targets LangSmith chart 0.17.0-rc.29 or newer. Set
`enable_smithdb = true` to provision its Azure dependencies independently of
the LangSmith application database and trace-blob account.

## Infrastructure

The Terraform root creates:

- a dedicated private Azure Database for PostgreSQL Flexible Server 18 and an
  empty `smithdb` database;
- a dedicated Blob Storage account and private container, with Shared Key
  authentication disabled;
- a SmithDB-only user-assigned identity, federated to the chart-owned SmithDB
  Kubernetes ServiceAccount and scoped to `Storage Blob Data Contributor` on
  that account; and
- two autoscaling, tainted AKS node pools: `smithcache` hosts cache-heavy
  workloads backed by per-pod Premium SSD v2 volumes, and `smithcompute` hosts
  compute workloads.

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

## Chart contract

Chart 0.17.0-rc.29 or newer supports Azure as a SmithDB object-store provider
and per-pod cache PVCs. `make init-values` generates the overlay from
`smithdb_storage_account_name` and `smithdb_storage_container_name`, annotates
the SmithDB ServiceAccount with `azure.workload.identity/client-id` from
`smithdb_workload_identity_client_id`, and labels SmithDB pods with
`azure.workload.identity/use: "true"`.

The Azure module remains pinned to chart 0.16 by default. Select chart 0.17
explicitly when enabling SmithDB:

```hcl
enable_smithdb               = true
langsmith_helm_chart_version = ">=0.17.0-rc.29 <0.18.0-0"
```

The chart is intentionally a separate deployment pass: `terraform apply`
provisions the Azure and Kubernetes prerequisites but does not install
LangSmith itself.

The federated identity subject is derived with the same fullname convention as
the chart. For example, release `langsmith` uses `langsmith-smithdb`, while
release `prod` uses `prod-langsmith-smithdb`.

## Network and sizing notes

The Storage Account firewall admits the AKS subnet through its
`Microsoft.Storage` service endpoint. PostgreSQL uses the delegated database
subnet and the VNet's private PostgreSQL DNS zone. SmithDB increases AKS subnet
IP demand; the root module includes both node pools in its capacity check.

`Standard_D16s_v5` is the default cache-workload VM. Terraform creates the
`smithdb-cache-premium-v2` StorageClass with 7,000 IOPS and 1,000 MB/s and the
generated Helm overrides select it for SmithDB's per-pod cache PVCs. Premium
SSD v2 must be available in the cluster's region and zones.

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
- Premium SSD v2 is available in the target region and zones;
- the AKS subnet has room for both pools at maximum scale; and
- the chart PR's Azure provider values and workload-identity annotations match
  the outputs listed above.
