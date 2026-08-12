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

## Metastore TLS on GCP

SmithDB 0.16 cannot verify a Cloud SQL certificate, so TLS has to come off the
metastore hop:

```hcl
smithdb_metastore_ssl_mode = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
smithdb_metastore_use_ssl  = false
```

Without this, the query, ingestion, and compaction pods crashloop on
`InvalidCertificate(UnknownIssuer)`. Cloud SQL presents a per-instance self-signed
CA and the services verify the chain against the public trust store, so validation
cannot succeed. The service config exposes a single `use_ssl` boolean with no CA
path and no encrypt-without-verify mode, and injecting the CA would not help
because the server certificate carries no IP SAN while SmithDB connects to the
private IP - verification would fail on the hostname instead.

The metastore migration hook is the one component unaffected, because it connects
through libpq with `sslmode=require`, which encrypts without verifying. Expect the
hook to succeed while every service fails against the same database; that
asymmetry is diagnostic, not a clue that the database is misconfigured.

Traffic stays on a private IP inside the VPC. That is acceptable for test and
staging, not for production. For production, run a Cloud SQL Auth Proxy sidecar
and keep `ssl_mode = "ENCRYPTED_ONLY"` on the instance: the proxy authenticates
with IAM, terminates TLS itself, and exposes plaintext on the pod loopback, so the
metastore host becomes `127.0.0.1` and `smithdb_metastore_use_ssl` stays `false`.
The chart accepts sidecars at `smithdb.<service>.deployment.sidecars`, and the
SmithDB GSA needs `roles/cloudsql.client`. Revisit once SmithDB accepts a CA
bundle or a non-verifying SSL mode, at which point TLS can go back on directly.

## Deploy SmithDB services

Apply infrastructure, then generate values:

```sh
make init-values
```

Then deploy:

```sh
make deploy
```

SmithDB needs chart 0.16 or newer. `deploy.sh` already pins the 0.16 line and
refuses anything off it, so there is nothing SmithDB-specific to set. To name an
exact patch rather than the latest on the line, pass `CHART_VERSION=0.16.3`.
Check what is published with:

```sh
helm search repo langchain/langsmith --versions
```

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
`smithdb_query_enabled` in `infra/terraform.tfvars`. Terraform enforces that
migration and query each require ingestion.
Apply and validate each stage separately, and keep ClickHouse enabled throughout
LangSmith v16.

1) All gates off. The services come up and the metastore migration Job runs.
Confirm the pods schedule onto the expected pools and can reach both Postgres
and the bucket before going further.

2) `smithdb_ingestion_enabled = true`. LangSmith writes traces to SmithDB as
well as ClickHouse. Reads still come from ClickHouse.

3) `smithdb_migration_enabled = true`, if you need historical data. This renders
the migration Job plus an in-chart taskdb Postgres StatefulSet for migration task
state, and is the most node-hungry gate of the three.

The Job requests 8 CPU, 16Gi, and 100Gi of ephemeral storage, so the values overlay
pins it to the Local SSD pool; a core node can satisfy neither the CPU nor the
ephemeral storage. Since the three cache workloads already request 12 of an
n2-standard-16's ~15.9 allocatable CPU, the autoscaler adds a second Local SSD node
for the Job, so keep `smithdb_instance_store_max_nodes` at 2 or more while this gate
is on.

The taskdb StatefulSet requests 2 CPU and 4Gi as of chart 0.16.0-rc.26 (earlier
release candidates left it unconstrained) and is not pinned, so it lands on the core
pool and may push that pool to scale up too. Check `gke_max_nodes` has room before
enabling this gate.

The separate `metastore-migration` Helm hook stays unpinned on the core pool by
design - it runs before any SmithDB pod exists, so nothing would trigger a scale-up
from zero.

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
