# SmithDB on AWS

This module provides AWS reference infrastructure and Helm values for SmithDB.
SmithDB is optional and runs alongside ClickHouse in the LangSmith v16 release.

## What is provisioned

With `enable_smithdb = true`, the infrastructure pass creates:

- a dedicated PostgreSQL 18 RDS metastore, or wiring for dedicated BYO Postgres;
- a dedicated S3 object-store bucket;
- a SmithDB-specific IRSA role with bucket-scoped access;
- Karpenter and dedicated local-NVMe and compute NodePools;
- the `smithdb-local` Kubernetes Secret containing metastore connection fields.

The existing S3 Gateway VPC endpoint is associated with the VPC route tables,
so same-region SmithDB S3 traffic takes the private AWS network path.

## Blob storage

LangSmith uses at least two buckets on AWS, and they follow different retention rules:

| Bucket | Created by | Lifecycle (TTL) rules |
|---|---|---|
| Platform bucket (trace blobs) | `modules/storage` | Yes. `ttl_s/` expires after 14 days and `ttl_l/` after 400 days. Set with `s3_ttl_enabled`, `s3_ttl_short_days`, and `s3_ttl_long_days`. |
| SmithDB bucket | `modules/smithdb`, when `enable_smithdb = true` | **None. Do not add any.** |

**Do not set a TTL on the SmithDB bucket.** Compaction handles retention
there, and deleting live objects can make data unavailable. The module creates
that bucket with no lifecycle rules, and a plan test
(`infra/tests/smithdb_bucket.tftest.hcl`) fails if one is added to it.

The module has no input that points SmithDB at an existing bucket:
`smithdb_bucket_name` only names the bucket Terraform creates. If you manage a
bucket yourself, outside this module, apply the same rule: no TTL on the
SmithDB bucket. Keep TTL rules on the platform bucket only.

Sandboxes (`enable_sandboxes = true`) do not get their own bucket on AWS. Their
JuiceFS volume stores objects in the platform bucket (`sandbox_juicefs_bucket_url`
in the Terraform outputs), under the `sandbox_juicefs_name` prefix
(`sandbox-juicefs` by default), and its metadata lives in a dedicated
ElastiCache Redis. The platform bucket's TTL rules match only the `ttl_s/` and
`ttl_l/` prefixes, so they do not touch Sandbox data. Keep `sandbox_juicefs_name`
away from those two prefixes. The application deletes Sandbox data, not S3: a
stopped sandbox is deleted by a server-side sweep after `delete_after_stop_seconds`,
typically 14 days by default and at most 30. Snapshots are kept until someone
deletes them. See [Sandbox SDK usage](https://docs.langchain.com/langsmith/sandbox-sdk).
The module sets no size limit on Sandbox storage: the bucket grows with use.

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
- Verify SmithDB workloads schedule on the expected Karpenter pools and can
  reach PostgreSQL and S3 before enabling ingestion.
