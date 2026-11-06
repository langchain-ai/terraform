# SmithDB on AWS

This module provides AWS reference infrastructure and Helm values for SmithDB.
SmithDB shares the LangSmith cluster and Helm release. New QuickStart setups
enable SmithDB and ingestion by default; existing settings are preserved.

## What is provisioned

With `enable_smithdb = true`, the infrastructure pass creates:

- a dedicated PostgreSQL 18 RDS metastore, or wiring for dedicated BYO Postgres;
- a dedicated S3 object-store bucket;
- a SmithDB-specific IRSA role with bucket-scoped access;
- a dedicated EKS managed node group and a gp3 cache StorageClass;
- the `smithdb-local` Kubernetes Secret containing metastore connection fields.

The existing S3 Gateway VPC endpoint is associated with the VPC route tables,
so same-region SmithDB S3 traffic takes the private AWS network path.

## Configure infrastructure

Run `make quickstart` or set `enable_smithdb = true` and
`smithdb_ingestion_enabled = true` in
`infra/terraform.tfvars`. Managed PostgreSQL is the default. To use an existing
metastore:

```hcl
smithdb_metastore_source            = "external"
smithdb_external_metastore_host     = "postgres.internal.example"
smithdb_external_metastore_username = "smithdb"
```

Supply `TF_VAR_smithdb_external_metastore_password` outside the tfvars file.
The Postgres database and S3 bucket must be dedicated to SmithDB.

SmithDB services and TaskDB use a separate node group. Defaults:

| `sizing_profile` | Instance type | Minimum nodes | Maximum nodes |
| --- | --- | --- | --- |
| `default`, `dev`, `minimum` | `m6a.4xlarge` | 2 | 5 |
| `production` | `m6a.8xlarge` | 2 | 10 |
| `production-large` | `m6a.16xlarge` | 2 | 10 |

The sizing profile selects the instance type automatically. QuickStart asks for
`smithdb_node_min_count` and `smithdb_node_max_count`. Set
`smithdb_node_instance_type` in `infra/terraform.tfvars` to override the instance
type. Increase the maximum for additional capacity.
LangSmith uses its own group, defaulting to `m6a.2xlarge`.

Nodes keep the 100 GiB boot-disk default. `smithdb.resourceTier` sets service
resources and cache sizes. Caches use gp3
(7,000 IOPS, 1,000 MiB/s), set through `smithdb.cache.storageClassName`.

## Deploy SmithDB services

Apply infrastructure, then generate values:

```sh
make apply
make init-values
```

The deploy script pins the latest 0.17.x Helm chart (`~0.17.0`):

```sh
make deploy
```

For new QuickStart setups, the generated values enable ingestion while leaving
migration and query cutover disabled:

```yaml
smithdb:
  langsmith:
    ingestion:
      enabled: true
    migration:
      enabled: false
    query:
      enabled: false
```

Follow the installation guide provided by LangChain to validate services and
dual ingestion, optionally migrate historical data, and finally switch queries.
For the scripts path, set `smithdb_ingestion_enabled`,
`smithdb_migration_enabled`, and `smithdb_query_enabled` in
`infra/terraform.tfvars`; the app path exposes the same flags. Apply each stage
separately.

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
- Verify SmithDB workloads schedule on the dedicated managed group and can
  reach PostgreSQL and S3.

## Existing Karpenter deployments

Finish and disable any historical migration on the current version before upgrading.

1. Set `smithdb_transition_mode = true` in `infra/terraform.tfvars`, keeping
   `enable_smithdb = true`. Run `make init` and `make apply` to add managed nodes
   while retaining Karpenter.
2. Run `make init-values` and `make deploy`. Deployment clears old service
   resource and cache-volume overrides, uses the selected resource tier,
   and moves workloads to the managed group.
3. Set `smithdb_transition_mode = false` and run `make apply`. Cleanup checks
   workload health and cache storage, waits for old nodes to terminate, then
   removes Karpenter. Failed checks stop cleanup.

Use `make apply` or `make quickdeploy`; direct `terraform apply` bypasses these
checks. The existing S3 bucket and metastore are preserved.
