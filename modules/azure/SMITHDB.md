# SmithDB on Azure

SmithDB support is optional and targets LangSmith chart 0.17 or newer. Set
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
- two autoscaling, tainted AKS node pools: `smithcache` uses the VM temporary
  disk for SmithDB's local cache and `smithcompute` hosts compute workloads.

The metastore password is stored in Terraform state because Terraform creates
the server. Supply it outside committed tfvars:

```bash
export TF_VAR_smithdb_metastore_admin_password='<strong-random-password>'
terraform -chdir=infra apply
```

The metastore Secret is created in the LangSmith namespace before Helm runs.
Object-store access uses Azure Workload Identity, so no Storage Account key or
SAS token is written to Kubernetes or Terraform outputs.

## Chart contract

Chart 0.17 must support Azure as a SmithDB object-store provider. `make
init-values` generates the overlay from
`smithdb_storage_account_name` and `smithdb_storage_container_name`, annotates
the SmithDB ServiceAccount with `azure.workload.identity/client-id` from
`smithdb_workload_identity_client_id`, and labels SmithDB pods with
`azure.workload.identity/use: "true"`.

To test an unreleased chart checkout, deploy it after `terraform apply`:

```bash
make init-values
LANGSMITH_CHART_PATH=/absolute/path/to/helm/charts/langsmith make deploy
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
