# SmithDB on GCP

This module provides GCP reference infrastructure and Helm values for SmithDB.
SmithDB is optional and runs alongside ClickHouse in the LangSmith v16 release.

## What is provisioned

With `enable_smithdb = true`, the infrastructure pass creates:

- a dedicated PostgreSQL 18 Cloud SQL metastore on a private IP, or wiring for
  dedicated BYO Postgres (including AlloyDB);
- a dedicated GCS object-store bucket with uniform bucket-level access and
  public access prevention;
- a dedicated GCP service account bound to the chart's SmithDB Kubernetes
  service account through Workload Identity, holding `roles/storage.objectAdmin`
  scoped to that one bucket;
- two GKE node pools - a Local SSD-backed pool for the cache-heavy workloads and
  a compute pool for the support workloads - both autoscaling from zero;
- the `smithdb-metastore` and `smithdb-taskdb` Kubernetes Secrets.

Object-store traffic stays on Google's network: the subnet has Private Google
Access enabled, so pods on private nodes reach `storage.googleapis.com` without
egressing through Cloud NAT.

SmithDB requires GKE Standard. Autopilot cannot run the dedicated Local SSD node
pools, and `enable_smithdb = true` with `gke_use_autopilot = true` fails at plan
time.

## Configure infrastructure

Set `enable_smithdb = true` in `infra/terraform.tfvars`. Managed resources are
the default. For BYO Postgres:

```hcl
smithdb_metastore_source            = "external"
smithdb_external_metastore_host     = "10.20.0.5"
smithdb_external_metastore_username = "smithdb"
```

Supply `TF_VAR_smithdb_external_metastore_password` outside the tfvars file. The
Postgres database and the GCS bucket must both be dedicated to SmithDB - do not
point them at the LangSmith application database or blob-storage bucket.

## Deploy SmithDB services

Apply infrastructure, then generate values:

```sh
make init-values
```

SmithDB requires an explicit Helm chart version of 0.16 or newer. Enabling the
infrastructure does not move the repository's chart line on its own, because
upgrading the whole application is a separate decision:

```sh
CHART_VERSION=0.16.0-rc.22 make deploy
```

The 0.16 line has so far published release candidates only, so an exact
prerelease tag is required. Helm's semver ranges never match a prerelease, so
`~0.16.0` resolves to no chart at all; both the script and the `app/` module
reject range syntax up front rather than letting the deploy fail later with an
opaque "chart not found". Check what is published with:

```sh
helm search repo langchain/langsmith --versions --devel
```

For the Terraform app path, set an explicit `chart_version` of 0.16 or newer and
`enable_smithdb = true` in `app/terraform.tfvars`.

## Staged rollout

The generated values deploy the SmithDB services with every LangSmith
integration gate disabled:

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

Set `smithdb_ingestion_enabled`, `smithdb_migration_enabled`, and
`smithdb_query_enabled` in `infra/terraform.tfvars`; the app path exposes the
same flags. Terraform enforces that migration and query each require ingestion.
Apply and validate each stage separately, and keep ClickHouse enabled throughout
LangSmith v16.

1) All gates off. The services come up and the metastore migration Job runs.
Confirm the pods schedule onto the expected pools and can reach both Postgres
and the bucket before going further.

2) `smithdb_ingestion_enabled = true`. LangSmith writes traces to SmithDB as
well as ClickHouse. Reads still come from ClickHouse.

3) `smithdb_migration_enabled = true`, if you need historical data. This renders
the migration Job plus an in-chart taskdb Postgres StatefulSet for migration task
state. The Job requests 8 CPU, 16Gi, and 100Gi of ephemeral storage, so the values
overlay pins it to the Local SSD pool; a core node can satisfy neither the CPU nor
the ephemeral storage. Since the three cache workloads already request 12 of an
n2-standard-16's ~15.9 allocatable CPU, the autoscaler adds a second Local SSD node
for the Job, so keep `smithdb_instance_store_max_nodes` at 2 or more while this gate
is on. The separate `metastore-migration` Helm hook stays unpinned on the core pool
by design - it runs before any SmithDB pod exists, so nothing would trigger a
scale-up from zero.

4) `smithdb_query_enabled = true`. Reads move to SmithDB.

Follow the installation guide provided by LangChain for the validation steps at
each stage.

## Verification

```sh
kubectl get pods -n langsmith -l app.kubernetes.io/instance=langsmith -o wide
kubectl get nodes -L smithdb-local/instance-store,smithdb-local/compute

# The cache mount must be on Local SSD, not the boot disk.
kubectl exec -n langsmith deploy/langsmith-smithdb-query -- df -h /data

# Once ingestion is on, segments should start landing in the bucket.
gcloud storage ls "gs://$(terraform -chdir=infra output -raw smithdb_object_store_bucket)/**"
```

Local SSD only backs the cache because the node pool uses GKE's Local SSD-backed
*ephemeral storage* mode. With raw block Local SSD the `emptyDir` would silently
fall back to the boot disk and cache I/O would be slow, which is why the `df -h`
check matters.

## Sizing

At chart defaults the three cache workloads request 4 CPU each and 200Gi
(query) + 100Gi (ingestion) + 100Gi (compactionWorker) of ephemeral storage, so
one `n2-standard-16` with 3 Local SSDs holds all three with headroom. If you
override the resource requests upward in
`helm/values/langsmith-values-smithdb.yaml`, raise
`smithdb_instance_store_local_ssd_count` to match, or replicas will sit Pending.

## Production notes

- Keep Cloud SQL deletion protection and backups enabled.
- Keep `smithdb_bucket_force_destroy = false`.
- Set `smithdb_bucket_kms_key` to use CMEK. The module grants the Cloud Storage
  service agent `roles/cloudkms.cryptoKeyEncrypterDecrypter` on that key; if the
  key lives in another project, that project's IAM policy must allow the grant.
- Do not place object-store credentials in Helm values. Pods authenticate
  through Workload Identity, and the chart's GCS path has no credential fields.
- The metastore and taskdb passwords are generated by Terraform and only ever
  written into Kubernetes Secrets. They are deliberately not root outputs.
