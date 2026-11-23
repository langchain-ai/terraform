# SmithDB on AWS

This module provides AWS reference infrastructure and Helm values for SmithDB.
From 0.18, SmithDB is part of every install: `enable_smithdb` defaults to
`true`, and a new install writes runs to SmithDB and serves reads from it from
the start. It shares the LangSmith cluster and Helm release. ClickHouse stays on
alongside it unless you turn it off.

## What is provisioned

With `enable_smithdb = true` (the default), the infrastructure pass creates:

- a dedicated PostgreSQL 18 RDS metastore, or wiring for dedicated BYO Postgres;
- a dedicated S3 object-store bucket;
- a SmithDB-specific IRSA role with bucket-scoped access;
- a dedicated EKS managed node group and a gp3 cache StorageClass (or caches on
  the nodes' local NVMe, see [Local SSD cache](#local-ssd-cache));
- the `smithdb-local` Kubernetes Secret containing metastore connection fields.

The existing S3 Gateway VPC endpoint is associated with the VPC route tables,
so same-region SmithDB S3 traffic takes the private AWS network path.

## Configure infrastructure

Run `make quickstart`, or leave the SmithDB settings out of
`infra/terraform.tfvars` to take the defaults. Managed PostgreSQL is the default. To use an existing
metastore:

```hcl
smithdb_metastore_source            = "external"
smithdb_external_metastore_host     = "postgres.internal.example"
smithdb_external_metastore_username = "smithdb"
```

Supply `TF_VAR_smithdb_external_metastore_password` outside the tfvars file.
The Postgres database and S3 bucket must be dedicated to SmithDB.

SmithDB services and TaskDB run on their own EKS managed node group. Every sizing
profile runs the SmithDB small tier, and the defaults below fit it. For the medium
or large tier, see [Scaling up](#scaling-up).

| Input | Default | Notes |
| --- | --- | --- |
| `smithdb_node_instance_type` | `m6a.4xlarge` | Fits the small tier. The medium tier needs `m6a.8xlarge`, the large tier `m6a.16xlarge`. |
| `smithdb_node_min_count` | `2` | At least 1, for the Helm migration hooks. |
| `smithdb_node_max_count` | `5` | Must exceed the minimum, so a rolling update has room. Raise it for medium and large. |
| `smithdb_cache_storage` | `network-disk` | `local-ssd` puts the caches on the nodes' instance-store NVMe. See [Local SSD cache](#local-ssd-cache). |

Set them in `infra/terraform.tfvars`. QuickStart asks for the two counts.
LangSmith uses its own group, defaulting to `m6a.2xlarge`.
That default was `m5.4xlarge` before this release. Changing a node group's instance
type replaces the group and drains its pods, so an install that relies on the default
(no `eks_managed_node_groups` in `terraform.tfvars`) replaces its default node group on
the next `make apply`, and each node has half the vCPU and memory. Set
`eks_managed_node_groups` to keep the previous size. A `terraform.tfvars` written by
QuickStart already names the instance type.

Nodes keep the 100 GiB boot-disk default. `smithdb.resourceTier` sets service
resources and cache sizes. By default, caches use gp3
(7,000 IOPS, 1,000 MiB/s), set through `smithdb.cache.storageClassName`.

**Scheduling.** `make init-values` writes the node selector and tolerations for the
SmithDB group (`langsmith-nodepool/smithdb`) into
`langsmith-values-smithdb-overrides.yaml`, for every SmithDB service, the metastore
migration Job and TaskDB. `make deploy` does not add them. If
`langsmith-values-smithdb.yaml` is a copy from an older release that still pins the
Karpenter pools, `make init-values` replaces it with the current example and keeps
the old copy as `langsmith-values-smithdb.legacy.yaml`.

**Tier and node size.** `langsmith-values-smithdb.yaml` sets
`smithdb.resourceTier: small`, and no sizing profile changes it, so every profile
runs the small tier on the default nodes. `make deploy` stops when the tier's
largest pod does not fit a SmithDB node. To move to a larger tier, follow
[Scaling up](#scaling-up).

**One pool.** To run SmithDB on the LangSmith nodes instead of its own group, delete
the `nodeSelector` and `tolerations` blocks under each SmithDB key in
`langsmith-values-smithdb-overrides.yaml`. `make init-values` rewrites that file, so
repeat the edit after each run. The SmithDB node group is still created.

**Migration.** The migration Job (`make smithdb-migration-job-start`) runs on the SmithDB
nodes. Each pod requests 100Gi of ephemeral storage, so raise
`smithdb_node_root_volume_size_gb` and run `make apply` before you enable migration.
The script stops when the boot disk is under 150 GiB. With the
[local SSD cache](#local-ssd-cache), ephemeral storage is on the instance store, and
the boot disk size does not count.

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

The generated values follow the three LangSmith gates. A new install has no
history to migrate, so it starts with ingestion and query on:

```yaml
smithdb:
  langsmith:
    ingestion:
      enabled: true
    migration:
      enabled: false
    query:
      enabled: true
```

An install with traces in ClickHouse turns SmithDB on in stages instead: set
`smithdb_ingestion_enabled = false` and `smithdb_query_enabled = false` in
`infra/terraform.tfvars`, then follow the installation guide provided by
LangChain to validate services and dual ingestion, optionally migrate historical
data, and finally switch queries, applying each stage separately. The gates
count only with `enable_smithdb = true`; with it false, all three are off
whatever they are set to.

To run the historical migration, run `make smithdb-migration-job-start`, then `make apply`, `make init-values`, and `make deploy`.
It asks whether TaskDB is chart-managed or an external Postgres, how many runs to migrate in how many days, and how many migration pods to run (suggesting a count from the LangSmith formula plus 50% headroom), then stores the TaskDB settings in SSM, writes `helm/values/langsmith-values-smithdb-migration.yaml`, and sets `smithdb_migration_enabled = true`.
Existing chart-managed migrations keep using `smithdb-migration-taskdb/postgres_password` when that Secret exists, so the helper does not change the Job's immutable secret reference.
With the flag on, Terraform grants the SmithDB role read access to the traces bucket, and the deploy starts the migration Job.
Once the Job is Complete, run `make smithdb-migration-job-end`, then the same three commands, to remove the grant, TaskDB, and its settings.
An external TaskDB Postgres is not deleted.
If migration pods are OOMKilled, raise their memory in `langsmith-values-smithdb-migration.yaml` (keep requests equal to limits).
Preserve TaskDB and its PVC, delete only the failed migration Job, then rerun `make deploy`. Kubernetes cannot update an existing Job's pod template; the recreated Job resumes from progress saved in TaskDB.

## Scaling up

Terraform sizes the SmithDB node group for the small tier. The medium and large
tiers need larger nodes, and the large tier also starts with more replicas. The
per-replica sizes below come from the chart's tier table.
[Configure SmithDB for scale](https://docs.langchain.com/langsmith/self-host-smithdb-scale)
lists the load each tier was tested at.

| Tier | Largest pod | Node type | Starting replicas |
| --- | --- | --- | --- |
| `small` | compaction worker: 8 vCPU, 16 GiB | `m6a.4xlarge` (default) | 1 of each |
| `medium` | query: 28 vCPU, 48 GiB | `m6a.8xlarge` | 1 of each |
| `large` | ingestion: 56 vCPU, 150 GiB | `m6a.16xlarge` | query 4, ingestion 2, compaction worker 4 |

Each replica also gets a gp3 cache volume of the tier's cache size, up to
1,000 GiB in the large tier. Put the Helm settings in
`helm/values/langsmith-values-smithdb.yaml`: it loads after the base and sizing
files, so its values win, and `make init-values` keeps your copy.

To move to the medium tier:

1. In `infra/terraform.tfvars`, set `smithdb_node_instance_type = "m6a.8xlarge"`
   and `smithdb_node_min_count = 3`. One `m6a.8xlarge` holds one medium query pod,
   so the medium workloads need three nodes. Raise `smithdb_node_max_count` to at
   least 4, so a rolling update has a free node, and above that for the replicas
   the autoscalers add. Run `make apply`.
2. In `helm/values/langsmith-values-smithdb.yaml`, set `smithdb.resourceTier: medium`.
3. Run `make deploy`.

To move to the large tier:

1. In `infra/terraform.tfvars`, set `smithdb_node_instance_type = "m6a.16xlarge"`
   and `smithdb_node_min_count = 7`. At the starting replicas, the large pods need
   seven `m6a.16xlarge` nodes. Raise `smithdb_node_max_count` to at least 8, and
   above that for the replicas the autoscalers add. Run `make apply`.
2. In `helm/values/langsmith-values-smithdb.yaml`, set the tier and the starting
   replicas:

   ```yaml
   smithdb:
     resourceTier: large
     query:
       autoscaling:
         hpa:
           minReplicas: 4
     ingestion:
       autoscaling:
         hpa:
           minReplicas: 2
     compactionWorker:
       autoscaling:
         keda:
           minReplicaCount: 4
   ```

3. Run `make deploy`.

`make deploy` compares the tier with the SmithDB nodes before it upgrades the
release. It stops when no SmithDB node can hold the tier's largest pod, and it
names the input to change. It also stops when your sizing file still sets
`smithdb.resourceTier` to another tier, as a copy from an earlier build of this
module can: the SmithDB values file loads later and would replace that tier
without notice. Move the tier into `helm/values/langsmith-values-smithdb.yaml`. In the unified layout (`smithdb.topology: unified`,
chart 0.18 or later), one pod runs every role and the tier sizes it; the same node
types fit it, and the check covers it too.

## Local SSD cache

By default, each SmithDB cache is a gp3 volume. With
`smithdb_cache_storage = "local-ssd"`, the caches use the instance-store NVMe disks
of the SmithDB nodes instead. Local NVMe has lower latency and higher throughput
than gp3, and no EBS volume is created for each pod. The
[SmithDB infrastructure guide](https://docs.langchain.com/langsmith/self-host-smithdb-infrastructure#local-ssd)
recommends local SSD for production.

The SmithDB node type must have instance store. Each type below has the vCPU and
memory of the `m6a` type for the same tier, so the node counts in
[Scaling up](#scaling-up) do not change.

| Tier | Node type | Instance store | Largest cache |
| --- | --- | --- | --- |
| `small` | `m6id.4xlarge` | 1 × 950 GB | 200 GiB |
| `medium` | `m6id.8xlarge` | 1 × 1,900 GB | 300 GiB (unified layout) |
| `large` | `m6id.16xlarge` | 2 × 1,900 GB | 1,000 GiB |

With `local-ssd`, the module does these steps:

- Terraform adds a `nodeadm` `NodeConfig` to `node-group-smithdb`. It joins the
  instance-store disks as RAID0 and moves the kubelet, containerd, and pod-log
  directories onto the array, so the node reports the array as allocatable
  `ephemeral-storage`. This is the configuration in
  [Provision EKS managed node groups](https://docs.langchain.com/langsmith/self-host-smithdb-infrastructure#provision-eks-managed-node-groups).
- The plan fails when `smithdb_node_instance_type` has no instance store.
- `make deploy` writes each cache as an `emptyDir` named `cache`, with a
  `sizeLimit` of the tier's cache size. It sets requests equal to limits for CPU,
  memory, and `ephemeral-storage`, as in the guide's local SSD values. The tier is
  the one in `langsmith-values-smithdb.yaml`. Other volumes on those services stay.
- `make deploy` stops when no SmithDB node can hold the tier's largest pod, or its
  largest cache in allocatable `ephemeral-storage`.
- The gp3 StorageClass stays, so you can switch back.

A local SSD cache lasts as long as its pod, as a gp3 cache volume does.

To move the caches to the local SSD:

1. In `infra/terraform.tfvars`, set the cache storage and the node type for your
   tier:

   ```hcl
   smithdb_cache_storage      = "local-ssd"
   smithdb_node_instance_type = "m6id.4xlarge"
   ```

2. Run `make apply`. EKS replaces the SmithDB nodes. The caches stay on gp3 until
   the next step.
3. Run `make deploy`. The caches move to the local SSD.

`make deploy` uses the local SSD only when `terraform.tfvars` and the applied node
group both have it. To move the caches back to gp3, keep this order:

1. In `infra/terraform.tfvars`, set `smithdb_cache_storage = "network-disk"`, and
   the `m6a` node type if you want it.
2. Run `make deploy`. The caches move to gp3 volumes on the current nodes.
3. Run `make apply`. EKS replaces the SmithDB nodes without the RAID0 array.

Do step 2 before step 3. A node without the array cannot hold a local SSD cache,
so the pods would stay Pending until the next deploy.

To verify, check the allocatable ephemeral storage of each SmithDB node and the
cache filesystem of a query pod:

```sh
kubectl get nodes -l langsmith-nodepool/smithdb=true \
  -o custom-columns='NAME:.metadata.name,EPHEMERAL:.status.allocatable.ephemeral-storage'
kubectl exec -n langsmith deploy/langsmith-smithdb-query -- df -h /data
```

## Production notes

- Keep RDS deletion protection, backups, and final snapshots enabled.
- Keep S3 `force_destroy` disabled.
- Set `s3_kms_key_arn` to use SSE-KMS. The SmithDB role receives key-scoped
  `kms:GenerateDataKey` and `kms:Decrypt`; the key policy must also permit it.
- Do not place object-store credentials in Helm values. Pods use IRSA.
- Verify SmithDB workloads schedule on the dedicated managed group and can
  reach PostgreSQL and S3.
- For the best cache performance, use the [local SSD cache](#local-ssd-cache).

## Upgrading from 0.17

**SmithDB settings.** The defaults now turn SmithDB on with queries served from
it. In 0.17 an unset `enable_smithdb`, `smithdb_ingestion_enabled` or
`smithdb_query_enabled` meant off, so a `terraform.tfvars` that leaves them out
would switch an install to querying a SmithDB that holds none of its ClickHouse
history. Before the first 0.18 apply, write them explicitly:

- without SmithDB: `enable_smithdb = false`, or turn it on and stage it as above;
- with SmithDB still staged: `smithdb_ingestion_enabled` and
  `smithdb_query_enabled` as they are today, `false` unless already cut over.

`make apply` and `make quickdeploy` refuse the first 0.18 apply until these are
set (`infra/scripts/upgrade-guard.sh`). Installs written by the QuickStart
wizard already carry them.

`make init-values` also checks the live Helm release, so it covers an apply run
outside `make apply` too, such as a plain `terraform apply` or a CI pipeline. It
refuses to switch a release that serves reads from ClickHouse to SmithDB unless
`terraform.tfvars` sets `smithdb_query_enabled = true`.

### Existing Karpenter deployments

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
