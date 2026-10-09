# SmithDB on AWS

This module provides AWS reference infrastructure and Helm values for SmithDB.
SmithDB is optional and runs alongside ClickHouse in the LangSmith v16 release.

## What is provisioned

With `enable_smithdb = true`, the infrastructure pass creates:

- a dedicated PostgreSQL 18 RDS metastore, or wiring for dedicated BYO Postgres;
- a dedicated S3 object-store bucket;
- a SmithDB-specific IRSA role with bucket-scoped access;
- Karpenter and dedicated local-NVMe and compute NodePools (default), or no
  Karpenter with `smithdb_node_provisioner = "node_group"` (see below);
- the `smithdb-local` Kubernetes Secret containing metastore connection fields.

The existing S3 Gateway VPC endpoint is associated with the VPC route tables,
so same-region SmithDB S3 traffic takes the private AWS network path.

## Configure infrastructure

Set `enable_smithdb = true` in `infra/terraform.tfvars`. Managed resources are
the default. For BYO Postgres:

```hcl
smithdb_metastore_source            = "external"
smithdb_external_metastore_host     = "postgres.internal.example"
smithdb_external_metastore_username = "smithdb"
```

Supply `TF_VAR_smithdb_external_metastore_password` outside the tfvars file.
The Postgres database and S3 bucket must be dedicated to SmithDB.

## Without Karpenter (managed node groups)

For dev and lab clusters, set `smithdb_node_provisioner = "node_group"`.
Terraform then skips Karpenter, its NodePools and EC2NodeClasses, and the
`karpenter.sh/discovery` tags. SmithDB schedules onto `eks_managed_node_groups`
entries carrying the overlay's labels instead; plan fails if none do. The
nodes need no local NVMe: chart 0.17 backs the query, ingestion, and
compaction-worker caches with per-pod PVCs on the default StorageClass (gp3).

```hcl
smithdb_node_provisioner = "node_group"

eks_managed_node_groups = {
  default = { name = "node-group-default", instance_types = ["m5.2xlarge"], min_size = 3, max_size = 6 }
  smithdb = {
    name           = "node-group-smithdb"
    instance_types = ["m5.2xlarge"]
    min_size       = 1
    max_size       = 2
    # One untainted group can carry both labels. For isolation, use two groups,
    # each with one label and a matching NO_SCHEDULE taint (the overlay already
    # tolerates smithdb-local/instance-store and smithdb-local/compute).
    labels = {
      "smithdb-local/instance-store" = "true"
      "smithdb-local/compute"        = "true"
    }
    # Room for the pods' node-local scratch (see below); the 20 GiB default is too small.
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs         = { volume_size = 100, volume_type = "gp3", encrypted = true, delete_on_termination = true }
      }
    }
  }
}
```

The sizing profiles request 100-200Gi of node `ephemeral-storage` for query,
ingestion, and compaction-worker, sized for RAID0 NVMe. In this mode
`make init-values` caps each at 10Gi (the cache itself is on the PVCs), so give
the group a root volume with room for that, as above. CPU and memory still come
from the sizing profile: `dev` asks for about 18 vCPU across SmithDB, including
an 8-vCPU compaction worker, so either size the group for it or set smaller
`resources` in `helm/values/langsmith-values-smithdb.yaml`. Gp3 defaults (3000
IOPS, 125 MiB/s) are below the chart's recommendation for cache volumes, so
this mode suits evaluation rather than production load.

## SmithDB only (no ClickHouse)

On chart 0.17, a **new** installation can run SmithDB as its only trace store
([Install without ClickHouse](https://docs.langchain.com/langsmith/self-host-smithdb-install#install-without-clickhouse)).
Retiring ClickHouse from an existing installation is a separate procedure;
contact LangChain support first.

```hcl
clickhouse_source         = "none"
enable_smithdb            = true
smithdb_ingestion_enabled = true
smithdb_query_enabled     = true
# smithdb_migration_enabled stays false: there is no ClickHouse history.
```

Plan fails unless all three SmithDB flags are set this way, and the chart
enforces the same rule at render time (at least one ingestion and one query
backend). `make init-values` then writes `clickhouse.enabled: false`, so no
ClickHouse StatefulSet, PVC, or `ch-migrations` Job is deployed, and Insights
needs no ClickHouse connection. SDK clients must use the SmithDB-backed methods
(`langsmith` Python >= 0.10.15, TypeScript >= 0.8.9); the deprecated
ClickHouse-era methods stop working without ClickHouse.

## Deploy SmithDB services

Apply infrastructure, then generate values:

```sh
make init-values
```

SmithDB requires a stable Helm chart version of 0.16 or newer.
The deploy script already pins the latest 0.17.x chart (`~0.17.0`):

```sh
make deploy
```

The generated values deploy SmithDB services with all LangSmith integration
gates disabled:

```yaml
smithdb:
  langsmith:
    ingestion:
      enabled: false
    migration:
      enabled: false
    query:
      enabled: false
```

Follow the installation guide provided by LangChain to validate services,
enable dual ingestion, optionally migrate historical data, and finally switch
queries.
For the scripts path, set `smithdb_ingestion_enabled`,
`smithdb_migration_enabled`, and `smithdb_query_enabled` in
`infra/terraform.tfvars`; the app path exposes the same flags. Apply each stage
separately and keep ClickHouse enabled throughout LangSmith v16.

## Production notes

- Keep RDS deletion protection, backups, and final snapshots enabled.
- Keep S3 `force_destroy` disabled.
- Set `s3_kms_key_arn` to use SSE-KMS. The SmithDB role receives key-scoped
  `kms:GenerateDataKey` and `kms:Decrypt`; the key policy must also permit it.
- Do not place object-store credentials in Helm values. Pods use IRSA.
- Verify SmithDB workloads schedule on the expected Karpenter pools (or
  labeled node groups) and can reach PostgreSQL and S3 before enabling ingestion.
