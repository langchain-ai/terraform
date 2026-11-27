# SmithDB on AWS

This module provides AWS reference infrastructure and Helm values for SmithDB.
From 0.18, SmithDB is part of every install: `enable_smithdb` defaults to
`true`, and a new install writes runs to SmithDB and serves reads from it from
the start. It shares the LangSmith cluster and Helm release. ClickHouse stays on
alongside it unless you turn it off.

## What is provisioned

With `enable_smithdb = true` (the default), the infrastructure pass creates:

- a dedicated PostgreSQL 18 RDS metastore;
- a dedicated S3 object-store bucket;
- a SmithDB-specific IRSA role with bucket-scoped access;
- a dedicated EKS managed node group and a gp3 cache StorageClass (or caches on
  the nodes' local NVMe, see [Local SSD cache](#local-ssd-cache));
- the `smithdb-local` Kubernetes Secret containing metastore connection fields.

The existing S3 Gateway VPC endpoint is associated with the VPC route tables,
so same-region SmithDB S3 traffic takes the private AWS network path.

## Blob storage

LangSmith uses at least two buckets on AWS, and they follow different retention rules:

| Bucket | Created by | Lifecycle (TTL) rules |
|---|---|---|
| Platform bucket (trace blobs) | `modules/storage` | Yes. `ttl_s/` expires after 14 days, `ttl_l/` after 400 days, and `ttl_1d/` after 1 day. Set with `s3_ttl_enabled`, `s3_ttl_short_days`, and `s3_ttl_long_days`. |
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
ElastiCache Redis. The platform bucket's TTL rules match only the `ttl_s/`, `ttl_l/`,
and `ttl_1d/` prefixes, so they do not touch Sandbox data. Keep `sandbox_juicefs_name`
away from those prefixes. The application deletes Sandbox data, not S3: a
stopped sandbox is deleted by a server-side sweep after `delete_after_stop_seconds`,
typically 14 days by default and at most 30 days when set. Setting it to `0`
turns off automatic deletion, and a sandbox with `idle_ttl_seconds = 0` never
stops, so its data stays until you delete it. Snapshots are kept until someone
deletes them. See [Sandbox SDK usage](https://docs.langchain.com/langsmith/sandbox-sdk).
The module sets no size limit on Sandbox storage: the bucket grows with use.

## Configure infrastructure

Run `make quickstart`, or leave the SmithDB settings out of `infra/terraform.tfvars` to take the defaults.
Terraform always creates the metastore RDS instance and the S3 bucket, both dedicated to SmithDB.
An install that used an external metastore in 0.17 moves it first: see [Move an external metastore to RDS](#move-an-external-metastore-to-rds).

SmithDB services run on their own EKS managed node group. Every sizing
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
`langsmith-values-overrides.yaml`, for every SmithDB service, the metastore
migration Job and TaskDB. `make deploy` does not add them.

**Tier and node size.** The SmithDB example, `helm/values/examples/langsmith-values-smithdb.yaml`,
sets `smithdb.resourceTier: small`, so every install runs the small tier on the default
nodes. `make deploy` stops when the tier's
largest pod does not fit a SmithDB node. To move to a larger tier, follow
[Scaling up](#scaling-up).

**One pool.** To run SmithDB on the LangSmith nodes instead of its own group, set
`nodeSelector: null` and `tolerations: null` under each SmithDB key in
`helm/values/langsmith-values-local.yaml`, then run `make init-values`. For example:

```yaml
smithdb:
  query:
    deployment:
      nodeSelector: null
      tolerations: null
```

Repeat the block for each SmithDB service. The SmithDB node group is still created.

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
    query:
      enabled: true
```

An install with traces in ClickHouse turns SmithDB on in stages instead: set
`smithdb_ingestion_enabled = false` and `smithdb_query_enabled = false` in
`infra/terraform.tfvars`, then follow the installation guide provided by
LangChain to validate services and dual ingestion, optionally migrate historical
data, and finally switch queries, applying each stage separately. The gates
count only with `enable_smithdb = true`; with it false, both are off
whatever they are set to.

Historical backfill is customer-managed, including Helm values, TaskDB, and
source-storage permissions. Follow the
[SmithDB migration guide](https://docs.langchain.com/langsmith/self-host-smithdb-migrate).

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
`helm/values/langsmith-values-local.yaml`: `make init-values` merges it after the
SmithDB example, so its values win, and no script writes it.

To move to the medium tier:

1. In `infra/terraform.tfvars`, set `smithdb_node_instance_type = "m6a.8xlarge"`
   and `smithdb_node_min_count = 3`. One `m6a.8xlarge` holds one medium query pod,
   so the medium workloads need three nodes. Raise `smithdb_node_max_count` to at
   least 4, so a rolling update has a free node, and above that for the replicas
   the autoscalers add. Run `make apply`.
2. In `helm/values/langsmith-values-local.yaml`, set `smithdb.resourceTier: medium`.
3. Run `make init-values`, then `make deploy`.

To move to the large tier:

1. In `infra/terraform.tfvars`, set `smithdb_node_instance_type = "m6a.16xlarge"`
   and `smithdb_node_min_count = 7`. At the starting replicas, the large pods need
   seven `m6a.16xlarge` nodes. Raise `smithdb_node_max_count` to at least 8, and
   above that for the replicas the autoscalers add. Run `make apply`.
2. In `helm/values/langsmith-values-local.yaml`, set the tier and the starting
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

3. Run `make init-values`, then `make deploy`.

`make deploy` compares the tier with the SmithDB nodes before it upgrades the
release. It stops when no SmithDB node can hold the tier's largest pod, and it
names the input to change. A tier from a 0.17 sizing file goes in
`helm/values/langsmith-values-local.yaml` too, because that file merges after the
SmithDB example. In the unified layout (`smithdb.topology: unified`,
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
- `make init-values` writes each cache as an `emptyDir` named `cache`, with a
  `sizeLimit` of the tier's cache size. It sets requests equal to limits for CPU,
  memory, and `ephemeral-storage`, as in the guide's local SSD values. The tier is
  `smithdb.resourceTier`: small from the SmithDB example, or the tier you set in
  `langsmith-values-local.yaml`. Other volumes on those services stay.
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
3. Run `make init-values`, then `make deploy`. The caches move to the local SSD.

`make init-values` uses the local SSD only when `terraform.tfvars` and the applied node
group both have it, and `make deploy` stops when the applied node group changed
after `make init-values`. To move the caches back to gp3, keep this order:

1. In `infra/terraform.tfvars`, set `smithdb_cache_storage = "network-disk"`, and
   the `m6a` node type if you want it.
2. Run `make init-values`, then `make deploy`. The caches move to gp3 volumes on the current nodes.
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

For version upgrades, follow the [official LangSmith upgrade guide](https://docs.langchain.com/langsmith/self-host-upgrades) and contact [LangChain Support](https://support.langchain.com) for assistance. The Terraform module also requires the settings below.

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

**Metastore settings.** `smithdb_metastore_source = "external"` fails at plan,
because Terraform always creates the metastore. Move the data first, as in
[Move an external metastore to RDS](#move-an-external-metastore-to-rds).
`smithdb_existing_metastore_security_group_id` and
`smithdb_manage_byo_security_group_rules` are renamed to
`smithdb_metastore_existing_security_group_id` and
`smithdb_metastore_manage_existing_security_group_rules`, and the old names fail
at plan.

### Existing Karpenter deployments

In 0.17, `enable_smithdb = true` runs SmithDB on Karpenter node pools, and 0.18
has no Karpenter. An apply would delete those pools and the Karpenter controller
under the running SmithDB pods. `make apply` and `make quickdeploy` refuse a
state that still has them, but a plain `terraform apply` does not check. Contact
LangChain Support before you upgrade such an install, or build a new 0.18
install.

0.18 also removes the settings that configured those pools:
`smithdb_karpenter_chart_version`, `smithdb_karpenter_ami_alias`,
`smithdb_node_arch`, `smithdb_capacity_type`, `smithdb_instance_store_sizes`,
`smithdb_instance_store_min_local_nvme_gib`, `smithdb_instance_store_limits`,
`smithdb_compute_sizes`, and `smithdb_compute_limits`. Delete them from
`terraform.tfvars`. Terraform only warns about a value that it no longer
declares.

### Move an external metastore to RDS

From 0.18 the module always creates the SmithDB metastore as a dedicated RDS
instance, and `smithdb_metastore_source = "external"` fails at plan. Move the data
before the first 0.18 apply. That apply points the `smithdb-local` Secret at a new,
empty RDS instance. Writes made after the dump are not copied, so stop sending
traces until the move is done. The commands use the default namespace, `langsmith`.
In 0.17, an install with SmithDB also runs it on Karpenter, and `make apply`
refuses that state. Read [Existing Karpenter deployments](#existing-karpenter-deployments) first.

1. Save this pod as `smithdb-pg.yaml`. It reads the metastore connection from
   `smithdb-local` when it starts: before the apply, that is the external
   metastore, and after it, the new RDS instance. Use the image for your RDS engine
   version (`smithdb_metastore_engine_version`, default `18`):

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: smithdb-pg
     namespace: langsmith
   spec:
     restartPolicy: Never
     containers:
       - name: smithdb-pg
         image: postgres:18
         command: ["sleep", "3600"]
         env:
           - name: PGHOST
             valueFrom:
               secretKeyRef:
                 name: smithdb-local
                 key: smithdb_metastore_db_host
           - name: PGDATABASE
             valueFrom:
               secretKeyRef:
                 name: smithdb-local
                 key: smithdb_metastore_db_name
           - name: PGUSER
             valueFrom:
               secretKeyRef:
                 name: smithdb-local
                 key: smithdb_metastore_db_username
           - name: PGPASSWORD
             valueFrom:
               secretKeyRef:
                 name: smithdb-local
                 key: smithdb_metastore_db_password
   ```

   The Secret holds no port. If the external metastore does not listen on 5432,
   add a `PGPORT` variable with its port for the dump.

2. Dump the external metastore to your machine:

   ```bash
   kubectl apply -f smithdb-pg.yaml
   kubectl wait -n langsmith --for=condition=Ready pod/smithdb-pg --timeout=180s
   kubectl exec -n langsmith smithdb-pg -- pg_dump -Fc > smithdb-metastore.dump
   kubectl delete pod -n langsmith smithdb-pg
   ```

3. Remove `smithdb_metastore_source = "external"` and the
   `smithdb_external_metastore_*` lines from `infra/terraform.tfvars`, and unset
   `TF_VAR_smithdb_external_metastore_password`. Run `make apply`. It creates the
   RDS instance and points `smithdb-local` at it.
4. Restore the dump before `make deploy`, which runs the metastore migration Job.
   Start the pod again, so that it reads the new connection:

   ```bash
   kubectl apply -f smithdb-pg.yaml
   kubectl wait -n langsmith --for=condition=Ready pod/smithdb-pg --timeout=180s
   kubectl cp smithdb-metastore.dump langsmith/smithdb-pg:/tmp/smithdb-metastore.dump
   kubectl exec -n langsmith smithdb-pg -- \
     sh -c 'pg_restore --no-owner --no-privileges -d "$PGDATABASE" /tmp/smithdb-metastore.dump'
   kubectl delete pod -n langsmith smithdb-pg
   ```

5. Run `make init-values` and `make deploy`.
6. Keep the external database and `smithdb-metastore.dump` until LangSmith shows
   your traces. Terraform does not manage the external database, so delete it
   yourself.
