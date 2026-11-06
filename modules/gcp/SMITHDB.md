# SmithDB on GCP

This module provides GCP reference infrastructure and Helm values for SmithDB on
LangSmith chart 0.17. SmithDB is optional and runs alongside ClickHouse, in the
same namespace and Helm release. To upgrade an install that ran SmithDB on chart
0.16, read [Upgrade from chart 0.16](#upgrade-from-chart-016) first.

## What is provisioned

With `enable_smithdb = true`, the infrastructure pass creates:

- a dedicated PostgreSQL 18 Cloud SQL metastore on a private IP, with a tier
  that follows the size, or wiring for dedicated BYO Postgres (including
  AlloyDB);
- a dedicated GCS object-store bucket with uniform bucket-level access and
  public access prevention;
- a GCP service account for SmithDB, bound through Workload Identity, with
  `roles/storage.objectAdmin` on that bucket only;
- one general-purpose GKE SmithDB pool, separate from LangSmith;
- a Hyperdisk Balanced cache StorageClass;
- the `smithdb-metastore` and `smithdb-taskdb` Kubernetes Secrets;
- the output `smithdb_helm_values`, which `make init-values` writes to
  `helm/values/langsmith-values-smithdb-sizing.yaml`.

Object-store traffic uses Private Google Access, not Cloud NAT. SmithDB requires
GKE Standard: `enable_smithdb = true` with `gke_use_autopilot = true` fails at
plan time.

## Configure infrastructure

New GKE Standard setups created by `make quickstart` enable SmithDB and
ingestion (dual write) automatically. Historical migration and SmithDB queries
start disabled. Regenerating an existing file preserves its SmithDB settings.

QuickStart asks for SmithDB's size, cache mode, and minimum/maximum node counts,
independently of LangSmith. The machine type follows the selected SmithDB size
or sizing profile automatically. For example:

```hcl
enable_smithdb            = true
smithdb_ingestion_enabled = true
smithdb_migration_enabled = false
smithdb_query_enabled     = false
smithdb_sizing            = "small"
smithdb_node_min_count    = 2
smithdb_node_max_count    = 5
```

Network-backed cache volumes are the default. Run `make deploy-all` after
changing infrastructure settings. Explicit `smithdb_cache_storage = "local-ssd"`
retains the previous cache and compute pools.

For BYO Postgres:

```hcl
smithdb_metastore_source            = "external"
smithdb_external_metastore_host     = "10.20.0.5"
smithdb_external_metastore_username = "smithdb"
```

Supply `TF_VAR_smithdb_external_metastore_password` outside the tfvars file. The
Postgres database and the GCS bucket must both be dedicated to SmithDB. Do not
use the LangSmith application database or blob-storage bucket.

## Sizing

`smithdb_sizing` selects the chart `resourceTier`, baseline replicas, node
shape, and default metastore tier. An unset value follows `sizing_profile`:
`minimum`, `dev`, and `default` use Small; `production` uses Medium;
`production-large` uses Large. `minimal` remains a compatibility name for Small,
without reduced resource overrides.

| Chart tier | SmithDB machine | Minimum nodes | Maximum nodes |
|---|---|---|---|
| Small | `c3-standard-22` | 2 | 5 |
| Medium | `c3-standard-44` | 2 | 10 |
| Large | `c3-standard-88` | 2 | 10 |

Counts apply across all zones, not per zone. Set `smithdb_node_machine_type`,
`smithdb_node_min_count`, and `smithdb_node_max_count` to override them.
The existing network-mode boot disk default stays 300 GB. `resourceTier`
controls service requests and limits; migration and TaskDB keep chart-default
or customer CPU and memory. Increase the node ceiling when adding migration pods.

For a created metastore, the existing defaults remain `db-custom-4-16384`,
`db-custom-6-32768`, and `db-custom-10-65536` for Small, Medium, and Large.
`minimal` keeps `db-custom-2-8192`. An explicit `smithdb_metastore_tier` wins;
an external metastore does not use it.

## Cache storage

### network-disk

Each cache pod gets its own temporary PVC through
`smithdb.cache.storageClassName`. The class `smithdb-cache` uses
`pd.csi.storage.gke.io`, Hyperdisk Balanced, 7000 provisioned IOPS,
1000 MiB/s throughput, `WaitForFirstConsumer`, and volume expansion. The chart
sets cache capacity from `resourceTier`. C3 and C3D general-purpose nodes
support these volumes; N2 does not. Volumes on one node share its throughput
limit.

Every SmithDB workload, including migration, TaskDB, and the metastore hook,
uses `langsmith-nodepool/smithdb=true` with a matching `NoSchedule` toleration.
Migration keeps its chart-default 8 CPU and 32Gi memory and uses a separate
100Gi Hyperdisk scratch volume at `/tmp`. More parallel migration pods can
require more nodes.

### local-ssd

An explicit `smithdb_cache_storage = "local-ssd"` keeps the existing cache and
compute pools and their `smithdb_instance_store_*` / `smithdb_compute_*`
settings. Cache pods use `emptyDir` on Local SSD with the required explicit
resource requests and limits. These are the only service resource overrides.
Use GKE's `ephemeral_storage_local_ssd_config`, rather than raw-block Local
SSD, so kubelet reports the capacity as node `ephemeral-storage`.

## Move an existing deployment to the new pool

Finish any running historical migration first. Keep the prior cache mode,
size, and legacy pool settings for the first step.

1. Set `smithdb_transition_mode = true`, then run `make apply`. This adds the
   general-purpose pool and retains the old pools and their shapes.
2. Run `make init-values`, then `make deploy`. Network mode replaces old
   selectors, tolerations, local-SSD cache volumes, and service resource
   overrides while preserving unrelated volumes and migration/TaskDB settings.
3. Set `smithdb_cache_storage = "network-disk"` and
   `smithdb_transition_mode = false`, then run `make apply`.

`make apply` checks the exact plan before removing the old pools. It stops
unless SmithDB and TaskDB have completed their rollout onto the new pool,
cache volumes use the generated StorageClass, and no application pod still
uses an old pool. Keep TaskDB and its data until migration finishes. These
checks run through `make apply`; direct Terraform commands bypass them.

## Metastore TLS on GCP

### Why a direct TLS connection fails

SmithDB cannot verify a Cloud SQL server certificate. With direct TLS
(`smithdb_metastore_use_ssl = true`) to an `ENCRYPTED_ONLY` instance, the query,
ingestion, and compaction pods crash in a loop on
`InvalidCertificate(UnknownIssuer)`. Cloud SQL presents a per-instance
self-signed CA, SmithDB has no CA path setting, and the server certificate has
no IP SAN. The metastore migration hook uses libpq with `sslmode=require`, which
does not verify, so the hook succeeds while the services fail.

### Mode 1: Cloud SQL Auth Proxy sidecar (default)

For `smithdb_metastore_source = "create"`, the proxy is the default: an unset
`smithdb_metastore_use_auth_proxy` resolves to `true`, and an unset
`smithdb_metastore_use_ssl` resolves to `false`. Terraform rejects
`smithdb_metastore_use_ssl = true` with the proxy. You can pin the image with
`smithdb_auth_proxy_image`.

The sidecar holds the TLS session to Cloud SQL as the pod's Workload Identity
principal, and SmithDB connects to it on `127.0.0.1`. Terraform grants
`roles/cloudsql.client`. `make init-values` writes the sidecar into
`smithdb.commonInitContainers`, so it is in every SmithDB Deployment and both
Jobs, including the pre-install hook. It uses `--private-ip`, because the
metastore has no public IP, and a `startupProbe`, so SmithDB starts after the
proxy listens. Its argument is the instance connection name, so the proxy
requires a created metastore. For an external instance, see [AlloyDB](#alloydb).

### Mode 2: relaxed instance, no TLS (test and staging only)

```hcl
smithdb_metastore_use_auth_proxy = false
smithdb_metastore_ssl_mode       = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
smithdb_metastore_use_ssl        = false
```

The metastore hop is not encrypted. On a created metastore, Terraform rejects
`smithdb_metastore_use_auth_proxy = false` without the other two values.

### AlloyDB

This module creates Cloud SQL, not AlloyDB. Use the external metastore path and
add the AlloyDB proxy to the Helm values yourself:

```hcl
smithdb_metastore_source            = "external"
smithdb_external_metastore_host     = "127.0.0.1"
smithdb_external_metastore_database = "smithdb"
smithdb_external_metastore_username = "smithdb"
smithdb_metastore_use_ssl           = false
```

Add the sidecar to `smithdb.commonInitContainers` in
`helm/values/langsmith-values-smithdb.yaml`. The chart example
`examples/smithdb_alloydb_auth_proxy.yaml` has the container, the probes, and the
security context. Its positional argument is the full instance path
`projects/PROJECT/locations/REGION/clusters/CLUSTER/instances/INSTANCE`. The
SmithDB service account needs `roles/alloydb.client`, which Terraform does not
grant for an external instance.

## Deploy

`make deploy-all` runs `make apply`, `make init-values`, and `make deploy`.
`deploy.sh` loads the SmithDB values files in this order, and a
later file wins:

1. `langsmith-values-smithdb-sizing.yaml`: generated from
   `terraform output smithdb_helm_values`. Do not edit it.
2. `langsmith-values-smithdb.yaml`: copied once from `helm/values/examples/`.
   Your edits go here. Helm replaces lists, so write a complete `volumes` list.
3. `langsmith-values-smithdb-overrides.yaml`: generated with the bucket,
   Workload Identity, metastore mapping, Auth Proxy, and gates.
4. `langsmith-values-smithdb-migration.yaml`: written by
   `make smithdb-migration-job-start` with the TaskDB source and the migration
   pod count. `deploy.sh` loads it only while `smithdb_migration_enabled = true`.
   `helm/values/examples/langsmith-values-smithdb-migration.yaml` shows the
   layout.

For network mode, `make deploy` then replaces pool selectors and tolerations,
removes legacy service resource and local-cache volume overrides, and keeps
unrelated customer settings. Manual Helm commands must supply equivalent
values themselves.

`deploy.sh` stops before Helm in these cases:

- A SmithDB values file is missing. `deploy.sh` tells you to run
  `init-values.sh`.
- The overlay has the chart 0.16 values `local-ssd-storage` or
  `smithdb.migration.deployment`. `deploy.sh` names each value.
- `smithdb_migration_enabled = true`, and
  `langsmith-values-smithdb-migration.yaml` is missing. `deploy.sh` tells you
  to run `make smithdb-migration-job-start`.
- The migration gate in `langsmith-values-smithdb-overrides.yaml` is not equal
  to `smithdb_migration_enabled`. `deploy.sh` tells you to run
  `make init-values`.
- The backfill Job differs from the render. `deploy.sh` names the Job and the
  differences, and prints the `kubectl delete job` command.

## Staged rollout

Keep ClickHouse enabled in every stage. Set the gates in
`infra/terraform.tfvars`, and run `make deploy-all` after each stage. The
backfill is the one stage with its own make targets. They set
`smithdb_migration_enabled` for you.

| Stage | How | ingestion / migration / query |
|---|---|---|
| Off | The defaults | false / false / false |
| Dual write | Set `smithdb_ingestion_enabled = true` | true / false / false |
| Backfill | `make smithdb-migration-job-start` | true / true / false |
| End of backfill | `make smithdb-migration-job-end` | true / false / false |
| Cutover | Set `smithdb_query_enabled = true` | true / false / true |

`smithdb_ingestion_enabled` defaults to `false`, so a chart upgrade does not
start dual write. `make quickstart` writes `true` for a new install.

1) Dual write. LangSmith writes to ClickHouse and SmithDB, and reads stay on
ClickHouse. The query Deployment serves the mutations path, so it must be
healthy. Confirm that segments arrive in the bucket.

2) Backfill, to copy the ClickHouse history:

```sh
make smithdb-migration-job-start
make deploy-all
```

`make smithdb-migration-job-start` asks about TaskDB and about the size of the
migration:

- TaskDB is a temporary Postgres that holds the task state. A chart-managed
  TaskDB runs on the SmithDB pool and uses the
  `smithdb-taskdb` Secret that Terraform creates. An external TaskDB is a
  Postgres that you supply. The script writes its connection settings to the
  `smithdb-taskdb-external` Secret. Do not use the LangSmith Postgres or the
  SmithDB metastore.
- For the size, the script asks for the number of historical runs and the
  target days. It suggests a migration pod count from the docs formula (runs /
  5,000,000 / days / 8 vCPU per pod), plus 50%, with a maximum of 20.

The script writes `helm/values/langsmith-values-smithdb-migration.yaml`. It
sets `smithdb_migration_enabled = true` in `infra/terraform.tfvars`.
`make apply` then grants the read access in
[Backfill access](#backfill-access-to-the-traces-bucket). `make deploy` starts
the migration Job on the SmithDB pool.

Finish and disable an existing backfill before moving to network-disk cache;
the migration Job pod template changes.

- Time window. An empty `smithdb_migration_start_time` keeps the chart default
  window. On chart 0.17.0-rc.42, the default window is 400 days, and the
  migration Job log shows the window. To copy all history, set
  `smithdb_migration_start_time` in `infra/terraform.tfvars` to a time before
  the oldest trace, before `make deploy-all`.
- Pod count. Each migration pod requests 8 vCPU, 32 GiB, and 100 GiB of scratch
  storage: a cache PVC in network-disk mode or node storage with local SSD.
  If the pool cannot add the nodes, raise `smithdb_node_max_count`. Above about 20 pods, raise the TaskDB resources
  instead of adding pods.
- Resources. Migration and TaskDB use chart-default CPU and memory or your settings.
  The migration values file does not set resources. See
  [OOMKilled migration pods](#oomkilled-migration-pods).
- Duration. On a test cluster, about 10,000 rows took about 2 hours, with more
  than 30 minutes near 95%. That plateau is not a stall. A task whose window
  includes the last hour stays `pending` by design. For in-cluster ClickHouse,
  see [Slow backfill on in-cluster ClickHouse](#slow-backfill-on-in-cluster-clickhouse).
- Progress. With a chart-managed TaskDB, read the TaskDB table
  `migration_jobs`. The backfill is complete when every row has `promoted_at`.
  Do not use the percent or the pod phase.

```sh
kubectl exec -n langsmith langsmith-smithdb-taskdb-postgres-0 -c taskdb-postgres -- \
  psql -U postgres -d smithdb_migration -A -t \
  -c 'SELECT count(*), count(migrated_at), count(validated_at), count(promoted_at) FROM migration_jobs'
```

3) End of backfill. When every `migration_jobs` row has `promoted_at` and the
migration Job is `Complete`:

```sh
make smithdb-migration-job-end
make deploy-all
```

`make smithdb-migration-job-end` checks that the Job is `Complete`. When the Job
is not `Complete`, or is not found, it asks before it continues. The chart
deletes a finished Job after 7 days. The script sets
`smithdb_migration_enabled = false` and deletes the `smithdb-taskdb-external`
Secret. The deploy removes the migration Job and the chart-managed TaskDB, with
its PVC and task state. An external TaskDB Postgres is not deleted. On a test
cluster, an early cutover showed fewer runs than ClickHouse.

4) Cutover. Set `smithdb_query_enabled = true`, then run `make deploy-all`.
Reads move to SmithDB.

5) Rollback. Set `smithdb_query_enabled = false` to move reads back to
ClickHouse, which has all the data. Set `smithdb_ingestion_enabled = false` to
stop the writes to SmithDB. SmithDB then misses the traces written while it is
off, so run a backfill before the next cutover.

## Verification

```sh
kubectl get pods,jobs,pvc -n langsmith | grep -E '^NAME|smithdb'
kubectl get nodes -L langsmith-nodepool/smithdb,smithdb-local/instance-store,smithdb-local/compute
kubectl get pvc -n langsmith
kubectl exec -n langsmith deploy/langsmith-smithdb-query -- df -h /data

# After dual write starts, segments arrive at the bucket root.
gcloud storage ls "gs://$(terraform -chdir=infra output -raw smithdb_object_store_bucket)/**"
```

- `local-ssd`: no `*-cache` PVCs, and `df -h /data` shows about the Local SSD
  capacity. Do the check in `ingestion` and `compaction-worker` too. A size near
  the boot disk means raw block Local SSD.
- `network-disk`: one `<pod>-cache` PVC for each cache pod, on
  `smithdb-cache`.

## Backfill access to the traces bucket

The backfill reads the large run payloads that LangSmith keeps in the traces
bucket. The migration Job follows `config.blobStorage.engine`, so a GCS engine renders
`SMITHDB_MIGRATION__BLOB_STORE_DEFAULT__TYPE: gcs` with no credential fields,
and the Job uses Workload Identity. `modules/smithdb` grants the SmithDB service
account `roles/storage.objectViewer` on the traces bucket while
`smithdb_migration_enabled = true`. Do not use a GCS HMAC key: it puts a static
credential into Terraform state and a Kubernetes Secret.

When this access fails, the Job is `Running`, the pod is `2/2 Running`, and
progress stays at 0%. Check the task state:

```sh
POD=$(kubectl get pod -n langsmith -l job-name=langsmith-smithdb-migration -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n langsmith "$POD" -c migration -- ./smithdb migrate --self-hosted diagnose status
kubectl exec -n langsmith "$POD" -c migration -- ./smithdb migrate --self-hosted diagnose failures
# Failures are non-retryable. After you correct the access, reset them:
kubectl exec -n langsmith "$POD" -c migration -- ./smithdb migrate --self-hosted diagnose retry-failed --all --yes
```

## Upgrade from chart 0.16

Do steps 1 to 4 before `make apply`. With the upgrade path in
`MIGRATION-0.16-to-0.17.md`, do them before its step 3. Its steps 3 to 5 then
run `make apply`, `make init-values`, and `make deploy`.

1) Select the size. An unset `smithdb_sizing` follows `sizing_profile` as
shown in [Sizing](#sizing). Keep the prior tier and pool settings while moving
nodes, using [the transition steps](#move-an-existing-deployment-to-the-new-pool).
To stay on the Small tier and retain the old Local SSD pools instead, set:

```hcl
smithdb_sizing        = "small"
smithdb_cache_storage = "local-ssd"
```

These lines do not keep the metastore tier. See the next paragraph.

An unset `smithdb_metastore_tier` now also follows the size. For `small`,
`medium`, and `large`, `make apply` changes a created metastore from
`db-custom-2-8192` to the tier in the [sizing table](#sizing). The change takes
the instance offline for less than 60 seconds. To keep the old tier, set this
line in `infra/terraform.tfvars`:

```hcl
smithdb_metastore_tier = "db-custom-2-8192"
```

If `terraform.tfvars` already sets `smithdb_metastore_tier`, the tier does not
change. `minimal` and an external metastore do not change.

2) Check the metastore TLS values. The proxy is now the default for a created
metastore. Remove `smithdb_metastore_use_ssl = true`. To keep mode 2, set
`smithdb_metastore_use_auth_proxy = false`.

3) Replace the overlay. `make init-values` copies
`langsmith-values-smithdb.yaml` only when it is missing, and the 0.16 copy has
`local-ssd-storage` and `smithdb.migration.deployment`. Save your edits and
delete the file. The next `make init-values` creates it again. Then put back
only the edits that do not set `nodeSelector`, `tolerations`, `volumes`,
`volumeMounts`, or `resources`.

4) Delete a completed backfill Job. The chart keeps a finished Job for 7 days,
and a chart upgrade changes its pod template. See
[Immutable migration Job](#immutable-migration-job).

5) Run `make apply`, `make init-values`, and `make deploy`. For a release
candidate, use `CHART_VERSION=0.17.0-rc.N make deploy`. Then do the checks in
[Verification](#verification). If `smithdb_migration_enabled = true`, run
`make smithdb-migration-job-start` before `make deploy`. See
[Staged rollout](#staged-rollout), step 2.

### Direct Helm upgrades

A direct `helm upgrade` does not run the cleanup and checks in `make deploy`.
From saved values, remove old SmithDB selectors, tolerations, service resource
overrides, cache volumes and mounts, and `smithdb.migration.deployment`.
Keep migration and TaskDB resources and credentials. Helm merges maps, so
passing new values alone does not remove old keys. Pass the generated output
last to apply the selected [cache and scheduling settings](#cache-storage):

```sh
terraform -chdir=infra output -raw smithdb_helm_values > smithdb-sizing.yaml
helm upgrade langsmith langchain/langsmith -n langsmith --version <0.17 version> -f current-values.yaml -f smithdb-sizing.yaml
```

## Troubleshooting

### taskdb Pending on a zonal PVC

The taskdb PVC is a zonal disk. The taskdb stays `Pending` with `volume node
affinity conflict` when the SmithDB pool cannot add a node in that zone. A PVC
from chart 0.16 can be in any zone of the general pool.

```sh
kubectl get pvc -n langsmith | grep taskdb-postgres
kubectl describe pv <VOLUME> | grep -A4 'Node Affinity'
```

Add that zone to `smithdb_node_locations`, or increase
`smithdb_node_max_count` (or `smithdb_compute_max_nodes` for local SSD), then
run `make apply`.

### Immutable migration Job

`helm upgrade` fails with `field is immutable`. A Job's pod template cannot
change, and a chart version change (the `helm.sh/chart` label), a values change,
or a new proxy image changes it. `deploy.sh` finds the difference first and prints:

```sh
kubectl delete job langsmith-smithdb-migration -n langsmith --cascade=foreground --wait=true
```

The taskdb keeps the task state, so a new Job continues the backfill.

### OOMKilled migration pods

Very large traces can make a migration pod run out of memory. Add the
resources to `helm/values/langsmith-values-smithdb.yaml`, and keep requests
equal to limits:

```yaml
smithdb:
  migration:
    job:
      resources:
        requests: {cpu: "8", memory: "48Gi"}
        limits: {cpu: "8", memory: "48Gi"}
```

Keep TaskDB and its PVC. Delete only the failed migration Job, then run
`make deploy`. The new Job continues from the progress in TaskDB.

### Slow backfill on in-cluster ClickHouse

The migration Job logs `ClickHouse telemetry degraded; reducing migration
concurrency`, with an error about `system.asynchronous_metric_log`. The
in-cluster ClickHouse does not have that table. The Job then runs with
`crawl_limit: 1`, and tasks can stay unclaimed for a long time. On a test
cluster with chart 0.17.0-rc.42, 2 tasks stayed unclaimed for 57 minutes.
No module variable changes this behavior.

```sh
kubectl logs job/langsmith-smithdb-migration -n langsmith | grep 'telemetry degraded'
```

### UnknownIssuer

The rendered values have `useSsl: true` without the Auth Proxy. Terraform
rejects that mode for a created metastore, so run `make apply`,
`make init-values`, and `make deploy`. For a direct Helm upgrade, add
`-f helm/values/langsmith-values-smithdb-overrides.yaml` after the current
values. For an external Cloud SQL instance, use mode 2, or add a proxy as in
[AlloyDB](#alloydb). See [Metastore TLS on GCP](#metastore-tls-on-gcp).

### Shared Cloud SQL instance: cloudsqlsuperuser

Every BUILT_IN user of a Cloud SQL instance is a member of `cloudsqlsuperuser`,
so `REVOKE ... FROM PUBLIC` does not isolate the SmithDB user on a shared
instance. Make the SmithDB user the owner of its database, run
`REVOKE cloudsqlsuperuser FROM smithdb;`, and test access in both directions.

### Cache volumes grow with HPA replicas

In `network-disk` mode, each HPA replica of a cache component gets its own PVC
at the tier cache size. Each PVC adds disk cost, and the replicas on a node
share its throughput limit. `large` starts with 10 cache PVCs, 7200Gi in total.


## Node pools outside this module

For SmithDB on a GKE cluster that something else provisions, create pools with
the labels and taints that the sizing file selects. Without them, the SmithDB
pods stay `Pending`. The `small` cache pool in `local-ssd` mode:

```sh
gcloud container node-pools create smithdb-lssd \
  --cluster CLUSTER --region REGION --project PROJECT \
  --machine-type n2-standard-16 \
  --ephemeral-storage-local-ssd count=2 \
  --enable-autoscaling --num-nodes 0 --min-nodes 0 --max-nodes 3 \
  --workload-metadata=GKE_METADATA \
  --node-labels smithdb-local/instance-store=true \
  --node-taints smithdb-local/instance-store=true:NoSchedule
```

- Use `--ephemeral-storage-local-ssd`, not `--local-nvme-ssd-block`. With raw
  block Local SSD, the cache goes to the boot disk.
- For `network-disk`, use a C3 or C3D type with a 300 GB boot disk and no Local
  SSD. Create the class from [network-disk](#network-disk), and set
  `smithdb.cache.storageClassName`, with the label
  `langsmith-nodepool/smithdb=true` and matching `NoSchedule` taint.
- The compute pool has no Local SSD, a smaller type, and the label and taint
  `smithdb-local/compute`.
- This module requires GKE Standard.

## Production notes

- Network cache volumes are the default; local SSD remains an explicit option.
- Keep Cloud SQL deletion protection and backups enabled.
- Keep `smithdb_bucket_force_destroy = false`.
- Set `smithdb_bucket_kms_key` to use CMEK. The module grants the Cloud Storage
  service agent `roles/cloudkms.cryptoKeyEncrypterDecrypter` on that key.
- Do not put object-store credentials in Helm values. Pods use Workload Identity.
- Terraform writes the metastore and taskdb passwords only into Kubernetes
  Secrets. They are not root outputs.
