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
- two GKE node pools that autoscale from zero, cache and compute (none for
  `minimal`);
- a Hyperdisk Balanced StorageClass in `network-disk` mode (not for `minimal`);
- the `smithdb-metastore` and `smithdb-taskdb` Kubernetes Secrets;
- the output `smithdb_helm_values`, which `make init-values` writes to
  `helm/values/langsmith-values-smithdb-sizing.yaml`.

Object-store traffic uses Private Google Access, not Cloud NAT. SmithDB requires
GKE Standard: `enable_smithdb = true` with `gke_use_autopilot = true` fails at
plan time.

## Configure infrastructure

Set `enable_smithdb = true` in `infra/terraform.tfvars`, or answer yes in
`make quickstart`. Then select the size and the cache mode:

```sh
make smithdb-configure SIZING=small CACHE=local-ssd
make deploy-all
```

`make smithdb-configure` writes `smithdb_sizing` and `smithdb_cache_storage` to
`infra/terraform.tfvars`. `CACHE` is optional. With no `CACHE`, the current
`smithdb_cache_storage` stays. For `SIZING=minimal` with no `CACHE`, the script
writes `null`, so a later size change gets the default cache mode, `local-ssd`.

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

`smithdb_sizing` sets the chart `resourceTier`, the explicit resources, the
replicas, the node pool shapes, the namespace quota headroom, and the default
tier of a created metastore. When it is unset, it follows `sizing_profile`:
`minimum` gives `minimal`, `dev` and `default` give `small`, `production` gives
`medium`, and `production-large` gives `large`.

The component rows are per replica, as CPU / memory / cache size:

| | `minimal` | `small` | `medium` | `large` |
|---|---|---|---|---|
| Throughput: ingest / query QPS | development only | 10 / 10 | 100 / 40 | 1000 / 100 |
| Chart `resourceTier` | `small`, explicit resources | `small` | `medium` | `large` |
| Replicas: `query` / `ingestion` / `compactionWorker` | 1 / 1 / 1 | 1 / 1 / 1 | 1 / 1 / 1 | 4 / 2 / 4 |
| `query` | 1 / 2Gi / 200Gi | 4 / 8Gi / 200Gi | 28 / 48Gi / 200Gi | 28 / 50Gi / 1000Gi |
| `ingestion` | 1 / 2Gi / 100Gi | 4 / 8Gi / 100Gi | 16 / 32Gi / 100Gi | 56 / 150Gi / 1000Gi |
| `compactionWorker` | 1 / 2Gi / 100Gi | 8 / 16Gi / 100Gi | 16 / 32Gi / 100Gi | 28 / 50Gi / 300Gi |
| `compaction` | 500m / 1Gi | 2 / 4Gi | 4 / 8Gi | 8 / 16Gi |
| `clusterManager` | 250m / 256Mi | 250m / 256Mi | 250m / 256Mi | 2 / 2Gi |
| Sum at these replicas (pods) | 3.75 / 7.25Gi (5) | 18.25 / 36.25Gi (5) | 64.25 / 120.25Gi (5) | 346 / 718Gi (12) |
| Backfill Job (CPU / memory / ephemeral) | 1 / 4Gi / 10Gi | 8 / 32Gi / 100Gi | 8 / 32Gi / 100Gi | 8 / 32Gi / 100Gi |
| Backfill taskdb, requests; limits | 2 / 4Gi; 4 / 8Gi | 2 / 4Gi; 4 / 8Gi | 2 / 4Gi; 4 / 8Gi | 2 / 4Gi; 4 / 8Gi |
| Cache HPA `maxReplicas` | 1 | 10 (chart default) | 10 (chart default) | 10 (chart default) |
| Cache pool, `local-ssd` (boot disk) | not allowed | n2-standard-16, 2 LSSD (100 GB) | n2-standard-32, 4 LSSD (100 GB) | n2-standard-64, 8 LSSD (100 GB) |
| Cache pool, `network-disk` (boot disk) | no pool; `standard-rwo` | c3-standard-22 (300 GB) | c3-standard-44 (300 GB) | c3-standard-88 (300 GB) |
| Compute pool | no pool | n2-standard-8 | n2-standard-8 | n2-standard-16 |
| Metastore: docs vCPU / memory; default Cloud SQL tier (vCPU / memory) | not in the docs; `db-custom-2-8192` (2 / 8Gi) | 2 / 16Gi; `db-custom-4-16384` (4 / 16Gi) | 4 / 32Gi; `db-custom-6-32768` (6 / 32Gi) | 8 / 64Gi; `db-custom-10-65536` (10 / 64Gi) |
| Quota headroom: CPU / memory / pods | 7 / 11Gi / 12 | 27 / 53Gi / 12 | 93 / 169Gi / 12 | 404 / 870Gi / 26 |
| Quota headroom with the backfill | 10 / 19Gi / 20 | 37 / 90Gi / 20 | 103 / 206Gi / 20 | 414 / 906Gi / 34 |

- The throughput and replica rows come from the SmithDB sizing table in the
  [LangSmith self-hosted docs](https://docs.langchain.com/langsmith/self-host-smithdb-scale).
  The replicas are the HPA `minReplicas` of the three cache components.
  `compaction` and `clusterManager` have no HPA and run one replica.
  `smithdb_tier_replicas` in `infra/locals.tf` is the code copy.
- The `small`, `medium`, and `large` component rows come from chart 0.17.0-rc.42
  `templates/_helpers.tpl` (`langsmith.smithdb.tierResources`), where requests
  equal limits. The chart tier sets these per-replica values only, not the
  replicas. `smithdb_tiers` in `infra/locals.tf` is the code copy.
- `minimal` values are requests, and its limits are 2x. `minimal` runs on the
  general node pool, so that pool must have room for it. Use `minimal` only for
  development and test.
- The taskdb row is the chart default for each size. The module sets no taskdb
  resources.
- A backfill on a test cluster ran with the `minimal` resources of the five
  components and of the backfill Job. The taskdb had the chart default
  resources.
- The quota rows include the Auth Proxy sidecar
  (`terraform -chdir=infra output smithdb_quota_extra`).
- The metastore row is for a created metastore
  (`smithdb_metastore_source = "create"`). The docs values come from the
  section "Metastore capacity" in
  [SmithDB scale](https://docs.langchain.com/langsmith/self-host-smithdb-scale).
  The docs baseline tiers do not include the metastore.
- A Cloud SQL custom tier (`db-custom-*`, Enterprise edition) has 1 vCPU or an
  even number of vCPU, and at most 6.5 GB of memory for each vCPU. So each
  default tier has more vCPU than the docs value, to get the docs memory.
  `minimal` keeps the earlier default. `smithdb_metastore_tier_defaults` in
  `infra/locals.tf` is the code copy.
- A `smithdb_metastore_tier` value that you set replaces the default, also after
  a size change. An external metastore does not use the tier. Then
  `terraform -chdir=infra output smithdb_metastore_tier` reports that the
  output is not found, because Terraform does not store a null output.
- A tier change takes the metastore offline for less than 60 seconds. The docs
  tell you to monitor the database resource use and the transaction latency
  during the rollout.

`large` runs 10 cache pods. On `n2-standard-64` (`local-ssd`), each `ingestion`
pod uses one node, and each other node holds two 28 CPU pods. That is about 6
cache nodes, plus 1 node for the backfill Job. On `c3-standard-88`
(`network-disk`), it is about 4 cache nodes, plus 1 for the backfill Job. The
compute pool needs 1 node. `smithdb_instance_store_max_nodes` (default 3) is per
zone, so 3 zones give a maximum of 9 cache nodes. If you set
`smithdb_node_locations` to one zone, set `smithdb_instance_store_max_nodes` to
7 or more. `make preflight` checks the quota at the maximum node count. For
`large` with `local-ssd` in 3 zones, that is 720 N2 vCPU and 27,000 GB of Local
SSD.

The pool rows are defaults. A `smithdb_instance_store_*` or
`smithdb_compute_machine_type` value that you set replaces them, also after a
size change. Terraform does not check that a pinned value fits the size:

- The machine type must have more vCPU than the largest pod on the pool. For
  example, the `medium` query pod requests 28 CPU, so `n2-standard-16` cannot
  hold it.
- An N2 cache pool takes only these Local SSD counts (375 GB each):
  - 12-20 vCPU: 2, 4, 8, 16, or 24.
  - 22-40 vCPU: 4, 8, 16, or 24.
  - 42-80 vCPU: 8, 16, or 24.

  Compute Engine rejects other counts when it creates the pool. That happens
  after Terraform deletes the old pool.
- C3 and Z3 `-lssd` types have a fixed count. Set
  `smithdb_instance_store_local_ssd_count = 0` for them.

Terraform rejects `local-ssd` when the cache pool has no Local SSD: a count of 0
on a type that does not end in `lssd`. It also rejects `network-disk` with the
backfill when the boot disk is below 300 GB, because the Job requests 100Gi.

A change of the machine type, the Local SSD count, or the cache mode replaces
the node pool, and each cache starts empty. Object storage keeps the data.

## Cache storage

`query`, `ingestion`, and `compactionWorker` keep a cache at `/data`. With no
cache values, chart 0.17 gives each pod a PVC from the default StorageClass. On
GKE, that class is `standard-rwo`, which is below the
[cache floor](https://docs.langchain.com/langsmith/self-host-smithdb-infrastructure#cache-storage)
of 7000 IOPS and 1000 MiB/s. The generated sizing file always sets the cache.

### local-ssd

Use `local-ssd` for production. Each cache is an `emptyDir` on node Local SSD.
The cache pool uses the GKE Local SSD-backed *ephemeral storage* mode, so the
Local SSD capacity is node allocatable `ephemeral-storage`. Raw block Local SSD
does not back `emptyDir`, and the cache then goes to the boot disk with no error.

For each cache component, the sizing file sets this cache block:

- the cache pool pin;
- `volumes: [{name: cache, emptyDir: {sizeLimit: <cache size>}}]`;
- `resources` with `ephemeral-storage` in `requests` and `limits`. The chart
  requires them for an `emptyDir` cache.

### network-disk

Each cache is a per-pod Hyperdisk Balanced volume. `modules/k8s-bootstrap`
creates the class `smithdb-cache<suffix>`: `pd.csi.storage.gke.io`,
`type: hyperdisk-balanced`, 7000 provisioned IOPS, 1000 MiB/s provisioned
throughput, `WaitForFirstConsumer`, `Delete`, and volume expansion. The chart
sizes each volume from the tier.

- The cache machine type must be C3 or C3D, with 0 Local SSD. E2, N1, N2, and
  N2D cannot attach Hyperdisk Balanced, and C4 and N4 need a Hyperdisk boot
  disk. Terraform rejects other types.
- All Hyperdisk and Persistent Disk volumes on a node share one VM throughput
  limit. For c3-standard-22 that limit is 1800 MiB/s, so three 1000 MiB/s cache
  volumes on one node cannot all get full throughput.

### minimal

`minimal` runs SmithDB on the general node pool with reduced resources and one
replica for each cache component. Each cache is a PVC from the GKE built-in
`standard-rwo` class. Terraform rejects `minimal` with `local-ssd`.

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

`deploy.sh` stops before Helm in these cases:

- A SmithDB values file is missing. `deploy.sh` tells you to run
  `init-values.sh`.
- The overlay has the chart 0.16 values `local-ssd-storage` or
  `smithdb.migration.deployment`. `deploy.sh` names each value.
- The backfill Job differs from the render. `deploy.sh` names the Job and the
  differences, and prints the `kubectl delete job` command.

## Staged rollout

Keep ClickHouse enabled in every phase. `make smithdb-phase` writes the three
Terraform gates for one phase. Run `make deploy-all` after each phase.
`make smithdb-status` shows the phase, the resolved size, the SmithDB pods,
Jobs, and PVCs, and the backfill progress, and changes nothing.

| Phase | Command | ingestion / migration / query |
|---|---|---|
| Off | `make smithdb-phase PHASE=off` | false / false / false |
| Dual write | `make smithdb-phase PHASE=dual-write` | true / false / false |
| Backfill | `make smithdb-phase PHASE=backfill [START_TIME=<RFC 3339>]` | true / true / false |
| Cutover | `make smithdb-phase PHASE=cutover [FORCE=true]` | true / false / true |

`smithdb_ingestion_enabled` defaults to `false`, so a chart upgrade does not
start dual write. `make quickstart` writes `true` for a new install.

1) Dual write. LangSmith writes to ClickHouse and SmithDB, and reads stay on
ClickHouse. The query Deployment serves the mutations path, so it must be
healthy. Confirm that segments arrive in the bucket.

2) Backfill, to copy the ClickHouse history. The phase adds the migration Job on
the cache pool and a taskdb Postgres on the compute pool (the general pool for
`minimal`). The backfill also reads the traces bucket; see
[Backfill access](#backfill-access-to-the-traces-bucket).

- Time window. On a test cluster with chart 0.17.0-rc.38, an empty start time
  covered only about the last 14 days. The chart values comment gives 400 days.
  Set `START_TIME` to a time before the oldest trace that you want.
- Duration. On a test cluster, about 10,000 rows took about 2 hours, with more
  than 30 minutes near 95%. That plateau is not a stall. A task whose window
  includes the last hour stays `pending` by design.
- Completion. The backfill is complete when every row of the taskdb table
  `migration_jobs` has `promoted_at`. Do not use the percent or the pod phase.

3) Cutover. Reads move to SmithDB, and the deploy removes the migration Job and
the taskdb, with its PVC and task state. `PHASE=cutover` refuses until every
`migration_jobs` row has `promoted_at`. It also refuses when the table is empty
or when it cannot read the table. Add `FORCE=true` only when you did not run a
backfill. On a test cluster, an early cutover showed fewer runs than ClickHouse.

4) Rollback. `PHASE=dual-write` moves reads back to ClickHouse, which has all
the data. `PHASE=off` stops the writes to SmithDB. SmithDB then misses the
traces written while it is off, so run a backfill before the next cutover.

## Verification

```sh
make smithdb-status
kubectl get nodes -L smithdb-local/instance-store,smithdb-local/compute
kubectl get pvc -n langsmith
kubectl exec -n langsmith deploy/langsmith-smithdb-query -- df -h /data

# After dual write starts, segments arrive at the bucket root.
gcloud storage ls "gs://$(terraform -chdir=infra output -raw smithdb_object_store_bucket)/**"
```

- `local-ssd`: no `*-cache` PVCs, and `df -h /data` shows about the Local SSD
  capacity. Do the check in `ingestion` and `compaction-worker` too. A size near
  the boot disk means raw block Local SSD.
- `network-disk`: one `<pod>-cache` PVC for each cache pod, on
  `smithdb-cache<suffix>`. `minimal`: the same, on `standard-rwo`.

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

1) Select the size. An unset `smithdb_sizing` now follows `sizing_profile`, so
`production` gives `medium`, `production-large` gives `large`, and `minimum`
gives `minimal` with no pools.
For `medium`, Terraform replaces the cache pool with `n2-standard-32` and 4
Local SSD. The compute pool stays `n2-standard-8`.
For `large`, Terraform replaces the cache pool with `n2-standard-64` and 8
Local SSD, and the compute pool with `n2-standard-16`. `large` runs 12 SmithDB
pods that request about 350 vCPU. To stay smaller, set `smithdb_sizing` to
`medium` or `small`. To keep the 0.16 pool (n2-standard-16, 2 Local SSD) and
the chart tier `small`:

```sh
make smithdb-configure SIZING=small CACHE=local-ssd
```

This command does not keep the metastore tier. See the next paragraph.

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
[Verification](#verification).

### Direct Helm upgrades

A direct `helm upgrade`, for example with values from `helm get values`, does
not load the sizing file. Remove the 0.16 keys: the `local-ssd-storage`
volumes, the `/data` `volumeMounts` (chart 0.17 mounts `cache` at `/data`), and
`smithdb.migration.deployment`. Then pass the Terraform output last, so that it
sets the full [cache block](#local-ssd) on `query`, `ingestion`, and
`compactionWorker`:

```sh
terraform -chdir=infra output -raw smithdb_helm_values > smithdb-sizing.yaml
helm upgrade langsmith langchain/langsmith -n langsmith --version <0.17 version> \
  -f current-values.yaml -f smithdb-sizing.yaml
```

A rename of the volume on `query` only is not enough: `ingestion` and
`compactionWorker` then get PVCs on the default class, with no error.

## Namespace quota headroom

`modules/k8s-bootstrap` puts the `langsmith-quota` ResourceQuota on the
namespace. Terraform adds SmithDB headroom from the resolved size for:

- the replicas of each component in the [sizing table](#sizing);
- one surge copy of the largest pod, for a rolling update;
- the Auth Proxy sidecars;
- the backfill Job and the taskdb, in the backfill phase.

Some SmithDB pods have limits above requests, so the extra covers both sides.
The quota rows of the [sizing table](#sizing) show the results.

Without surge room, an upgrade stops with no clear error: the quota refuses the
new pod (a `FailedCreate` event on the ReplicaSet), and Helm waits.

The headroom limits HPA scale-out above the minimum replicas. A scale-out gets
only the surge room and the unused part of the base quota. The quota then
refuses the next pod, with a `FailedCreate` event on the ReplicaSet. To check the
quota, run `kubectl describe resourcequota langsmith-quota -n langsmith`.

## Troubleshooting

### taskdb Pending on a zonal PVC

The taskdb PVC is a zonal disk. The taskdb stays `Pending` with `volume node
affinity conflict` when the compute pool cannot add a node in that zone. A PVC
from chart 0.16 can be in any zone of the general pool.

```sh
kubectl get pvc -n langsmith | grep taskdb-postgres
kubectl describe pv <VOLUME> | grep -A4 'Node Affinity'
```

Add that zone to `smithdb_node_locations`, or increase
`smithdb_compute_max_nodes`, then run `make apply`.

### Immutable migration Job

`helm upgrade` fails with `field is immutable`. A Job's pod template cannot
change, and a chart version change (the `helm.sh/chart` label), a values change,
or a new proxy image changes it. `deploy.sh` finds the difference first and prints:

```sh
kubectl delete job langsmith-smithdb-migration -n langsmith --cascade=foreground --wait=true
```

The taskdb keeps the task state, so a new Job continues the backfill.

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
`minimal` caps each HPA at one replica.

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
  `smithdb.cache.storageClassName`.
- The compute pool has no Local SSD, a smaller type, and the label and taint
  `smithdb-local/compute`.
- On Autopilot, the nodeSelector must change to
  `cloud.google.com/gke-ephemeral-storage-local-ssd`. This path is not tested.

## Production notes

- Use `local-ssd` for the cache.
- Keep Cloud SQL deletion protection and backups enabled.
- Keep `smithdb_bucket_force_destroy = false`.
- Set `smithdb_bucket_kms_key` to use CMEK. The module grants the Cloud Storage
  service agent `roles/cloudkms.cryptoKeyEncrypterDecrypter` on that key.
- Do not put object-store credentials in Helm values. Pods use Workload Identity.
- Terraform writes the metastore and taskdb passwords only into Kubernetes
  Secrets. They are not root outputs.
