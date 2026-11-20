# SmithDB on AWS

This module provides AWS reference infrastructure and Helm values for SmithDB.
SmithDB is optional and runs alongside ClickHouse in the LangSmith v16 release.

## What is provisioned

With `enable_smithdb = true`, the infrastructure pass creates:

- a dedicated PostgreSQL 18 RDS metastore, or wiring for dedicated BYO Postgres;
- a dedicated S3 object-store bucket;
- a SmithDB-specific IRSA role with bucket-scoped access;
- a dedicated EKS managed node group for SmithDB (see [Nodes](#nodes));
- the `smithdb-local` Kubernetes Secret containing metastore connection fields.

The existing S3 Gateway VPC endpoint is associated with the VPC route tables,
so same-region SmithDB S3 traffic takes the private AWS network path.

## Nodes

SmithDB runs on its own managed node group, `node-group-smithdb`, apart from
the LangSmith app nodes. A default install has three node groups: the
LangSmith app, SmithDB, and Sandboxes when `enable_sandboxes = true`.

- **Size.** `smithdb_node_instance_type` defaults to `m5.4xlarge`, the type of
  the default app node group, which fits the SmithDB small tier. The medium tier
  needs an 8xlarge and the large tier a 16xlarge. `smithdb_node_min_count`
  (default 2) and `smithdb_node_max_count` (default 5) bound Cluster
  Autoscaler.
- **Disks.** The nodes have network disks only. SmithDB's caches are volume
  claims on the cluster's default StorageClass, so no local NVMe is needed.
- **Placement.** The group carries the label and the `NoSchedule` taint
  `langsmith-nodepool/smithdb=true`. `make init-values` writes the matching node
  selector and tolerations for every SmithDB workload into
  `langsmith-values-smithdb-overrides.yaml`, so SmithDB pods run only there and
  nothing else does.

### Running on one node group

The module always creates the SmithDB node group when SmithDB is on. A
customer who deploys the chart from their own pipeline can still run SmithDB on
the app nodes: remove the `nodeSelector` and `tolerations` keys under each
SmithDB workload in the values they deploy. The app nodes then need the
headroom of the SmithDB tier they run. With `make deploy`, `make init-values`
writes those keys again on every run.

### Upgrading from 0.17

A 0.17 install ran SmithDB on two Karpenter NodePools with local NVMe. Moving it
to the managed node group replaces the SmithDB caches, which SmithDB rebuilds
from S3; no data is lost, and queries are slower until the caches warm up.

1. Set `smithdb_keep_karpenter_pools = true` and run `make apply`. Terraform adds
   `node-group-smithdb` and keeps Karpenter and its pools.
2. Run `make init-values`. It replaces a 0.17 `langsmith-values-smithdb.yaml`,
   which selected the Karpenter pools, and keeps the old copy as
   `langsmith-values-smithdb.yaml.0.17.bak`. Carry over any edits of your own.
3. Run `make deploy`. The SmithDB pods move to the new node group, and
   Karpenter removes its nodes once they are empty.
4. Wait until `kubectl get nodeclaims` lists nothing, then set
   `smithdb_keep_karpenter_pools = false` and run `make apply` to remove
   Karpenter.

Do not skip step 4's wait. Karpenter must outlive its NodePools: if both are
removed in one apply while Karpenter still owns nodes, those EC2 instances are
left running with nothing to remove them.

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

To run the historical migration, run `make smithdb-migration-job-start`, then `make apply`, `make init-values`, and `make deploy`.
It asks whether TaskDB is chart-managed or an external Postgres, how many runs to migrate in how many days, and how many migration pods to run (suggesting a count from the LangSmith formula plus 50% headroom), then stores the TaskDB settings in SSM, writes `helm/values/langsmith-values-smithdb-migration.yaml`, and sets `smithdb_migration_enabled = true`.
Existing chart-managed migrations keep using `smithdb-migration-taskdb/postgres_password` when that Secret exists, so the helper does not change the Job's immutable secret reference.
With the flag on, Terraform grants the SmithDB role read access to the traces bucket, and the deploy starts the migration Job.
Once the Job is Complete, run `make smithdb-migration-job-end`, then the same three commands, to remove the grant, TaskDB, and its settings.
An external TaskDB Postgres is not deleted.
If migration pods are OOMKilled, raise their memory in `langsmith-values-smithdb-migration.yaml` (keep requests equal to limits).
Preserve TaskDB and its PVC, delete only the failed migration Job, then rerun `make deploy`. Kubernetes cannot update an existing Job's pod template; the recreated Job resumes from progress saved in TaskDB.

## Production notes

- Keep RDS deletion protection, backups, and final snapshots enabled.
- Keep S3 `force_destroy` disabled.
- Set `s3_kms_key_arn` to use SSE-KMS. The SmithDB role receives key-scoped
  `kms:GenerateDataKey` and `kms:Decrypt`; the key policy must also permit it.
- Do not place object-store credentials in Helm values. Pods use IRSA.
- Verify SmithDB workloads schedule on `node-group-smithdb` and can reach
  PostgreSQL and S3 before enabling ingestion.
