# SmithDB on Azure

SmithDB support on Azure is optional and starts at the LangSmith chart 0.17
line. Set `enable_smithdb = true` to provision its Azure dependencies
independently of the LangSmith application database and trace-blob account.

## Version requirements

Two version numbers apply here, and they are not the same thing.

**LangSmith chart: a stable release on the 0.17 or 0.18 line.**
The 0.17 line is the first with both the Azure SmithDB values and the per-pod
cache PVC contract, and 0.18 keeps that layout. `deploy.sh` accepts `0.17.x` and
`0.18.x`. It rejects 0.16, because the Azure values are absent there. To run
0.18, set it explicitly; the module never moves to a new minor on its own.

The default pin, `~0.17.0`, takes the newest released 0.17 patch. Helm leaves
prereleases out of a constraint like that, so it selects only stable releases.
Naming a prerelease exactly does install it, and that is not a supported
configuration: an RC carries an unreleased application image, so a problem found
on one cannot be told apart from a problem in the module.

**Module tag: `v0.17.*`.** SmithDB is an ordinary feature of the pinned line, so
it needs no chart selection of its own. Leave `langsmith_helm_chart_version`
empty to take the newest 0.17 patch, or set it to name one. A `v0.16.*` tag
cannot deploy SmithDB on Azure: its pin is `~0.16.0`, and the 0.16 chart has no
Azure SmithDB values.

## Infrastructure

The Terraform root creates:

- a dedicated private Azure Database for PostgreSQL Flexible Server 18 and an
  empty `smithdb` database;
- a dedicated Blob Storage account and private container, with Shared Key off
  by default. The chart's optional static-key path
  (`smithdb.config.objectStore.azure.accessKeySecretKey`) needs
  `smithdb_storage_shared_access_key_enabled = true`; the default runtime path does not
  use a key (README "Storage security defaults");
- a SmithDB-only user-assigned identity, federated to the chart-owned SmithDB
  Kubernetes ServiceAccount and scoped to `Storage Blob Data Contributor` on
  that account; and
- a Premium SSD v2 StorageClass for per-pod cache volumes. SmithDB workloads
  schedule on ordinary AKS nodes by default. The StorageClass is cluster-scoped,
  so its name carries the deployment suffix unless
  `smithdb_cache_storage_class_name` names one.

By default, the same SmithDB workload identity authenticates to PostgreSQL
through Microsoft Entra ID and is configured as the Flexible Server's Entra
administrator. This avoids a static database password and the separate SQL
bootstrap step that a less-privileged Entra principal would require.

To use password authentication instead, supply the password outside committed
tfvars. Because Terraform creates the server, that password is stored in
Terraform state:

```bash
export TF_VAR_smithdb_metastore_admin_password='<strong-random-password>'
terraform -chdir=infra apply
```

The metastore Secret is created in the LangSmith namespace before Helm runs. In
Entra mode it contains only the host, database, and username; the chart sets
`iamAuthProvider: azure`. Object-store access also uses Azure Workload Identity,
so no Storage Account key or SAS token is written to Kubernetes or Terraform
outputs.

## Chart contract

The chart 0.17 line supports Azure as a SmithDB object-store provider and
per-pod cache PVCs. `make init-values` generates the overlay from
`smithdb_storage_account_name` and `smithdb_storage_container_name`, annotates
the SmithDB ServiceAccount with `azure.workload.identity/client-id` from
`smithdb_workload_identity_client_id`, and labels SmithDB pods with
`azure.workload.identity/use: "true"`.

`deploy.sh` loads three SmithDB files, in this order:

1. `langsmith-values-smithdb-sizing.yaml`, which `init-values.sh` writes from
   the `smithdb_helm_values` output on every run. It holds the chart tier, the
   replicas, and the `minimal` resources. Do not edit it; see [Sizing](#sizing).
2. `langsmith-values-smithdb.yaml`, the overlay. `init-values.sh` copies it once
   and never overwrites it, so scheduling and other hand edits go here.
3. `langsmith-values-smithdb-overrides.yaml`, which `init-values.sh` writes from
   the identity, storage, and metastore outputs on every run.

A later file wins, so a `smithdb.resourceTier` line in the overlay replaces the
size. An overlay copied before the sizing file existed has that line.
`init-values.sh` warns about it; delete the line.

Select the chart line explicitly alongside the flag, as described in
[Version requirements](#version-requirements):

```hcl
enable_smithdb               = true
langsmith_helm_chart_version = "~0.17.0"
```

The chart is intentionally a separate deployment pass: `terraform apply`
provisions the Azure and Kubernetes prerequisites but does not install
LangSmith itself.

The federated identity subject is derived with the same fullname convention as
the chart. For example, release `langsmith` uses `langsmith-smithdb`, while
release `prod` uses `prod-langsmith-smithdb`.

## Sizing

`smithdb_sizing` sets the chart `resourceTier`, the replicas, the `minimal`
resources, and the default metastore SKU. Set it in `infra/terraform.tfvars`,
then run `make deploy-all`:

```hcl
smithdb_sizing = "small"   # minimal, small, medium, or large
```

When it is unset, it follows `sizing_profile`: `minimum`
gives `minimal`, `dev` and `default` give `small`, `production` gives `medium`,
and `production-large` gives `large`.

The component rows are per replica, as CPU / memory / cache volume:

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
| Cache HPA `maxReplicas` | 1 | 10 (chart default) | 10 (chart default) | 10 (chart default) |
| VM for the largest pod, for example | general pool | 16 vCPU, `Standard_D16s_v5` | 32 vCPU, `Standard_D32s_v5` | 64 vCPU and over 150 GiB, `Standard_D64s_v5` |
| Default metastore SKU (vCPU / memory) | `GP_Standard_D2ds_v5` (2 / 8Gi) | `MO_Standard_E2ds_v5` (2 / 16Gi) | `MO_Standard_E4ds_v5` (4 / 32Gi) | `MO_Standard_E8ds_v5` (8 / 64Gi) |

- The throughput and replica rows come from the SmithDB sizing table in the
  [LangSmith self-hosted docs](https://docs.langchain.com/langsmith/self-host-smithdb-scale).
  The replicas are the HPA `minReplicas` of the three cache components.
  `compaction` and `clusterManager` have no HPA and run one replica.
- The `small`, `medium`, and `large` component rows and the cache volumes come
  from the chart tier, where requests equal limits. `minimal` runs the `small`
  tier, so it keeps the `small` cache volumes. Its values are requests, and its
  limits are 2x. Use `minimal` only for development and test.
- The metastore defaults match the "Metastore capacity" section of the same
  docs page. A `smithdb_metastore_sku_name` that you set replaces the default,
  also after a size change. A SKU change restarts the Flexible Server.
- The VM row is the smallest shape that holds the largest pod. Set the pool
  `max_count` to cover the sum row at that shape, plus one node for the surge
  copy of the largest pod.

A wrapper root that calls this module must declare `smithdb_sizing` and pass
it through. It must also re-export `smithdb_helm_values`, which the scripts read through
`LANGSMITH_INFRA_DIR`. Without it, `init-values.sh` stops when SmithDB is on.

### Metastore SKU on an existing install

Earlier module versions used `GP_Standard_D2ds_v5` for an unset
`smithdb_metastore_sku_name`. On an existing install that leaves it unset, the
first `make apply` with this module version changes the SKU for every size
except `minimal`, and Azure restarts the metastore. Check the Edsv5 vCPU quota before the apply. To
keep the current SKU, set it in `infra/terraform.tfvars`:

```hcl
smithdb_metastore_sku_name = "GP_Standard_D2ds_v5"
```

For the downtime and the quota commands, see
[SmithDB metastore SKU on Azure](../../MIGRATION-0.16-to-0.17.md#6-smithdb-metastore-sku-on-azure).

## Staged rollout

Keep ClickHouse enabled in every stage. Set the gates in
`infra/terraform.tfvars`, and apply after each stage.

| Stage | How | ingestion / query |
|---|---|---|
| Off | The defaults | false / false |
| Dual write | Set `smithdb_ingestion_enabled = true` | true / false |
| Cutover | Set `smithdb_query_enabled = true` | true / true |

Apply each stage before you start the next one:

- In this repo's root, run `make deploy-all`.
- Under a wrapper root, `make apply` refuses to run, so `make deploy-all` does
  too. Run `terraform apply` in the wrapper root. Then export
  `LANGSMITH_INFRA_DIR` and `LANGSMITH_VALUES_DIR` and run
  `make seed-secrets k8s-secrets init-values deploy`.

1) Dual write. LangSmith writes to ClickHouse and SmithDB, and reads stay on
ClickHouse. Confirm that segments arrive in the SmithDB container.

Historical backfill is customer-managed, including Helm values, TaskDB, and
source-storage permissions. Follow the
[SmithDB migration guide](https://docs.langchain.com/langsmith/self-host-smithdb-migrate)
before switching queries.

2) Cutover. Set `smithdb_query_enabled = true`, then run `make deploy-all`.
Reads move to SmithDB.

3) Rollback. Set `smithdb_query_enabled = false` to move reads back to
ClickHouse, which has all the data. Set `smithdb_ingestion_enabled = false` to
stop the writes to SmithDB. SmithDB then misses the traces written while it is
off, so run a backfill before the next cutover.

## Network and sizing notes

By default the Storage Account firewall admits the AKS subnet through its
`Microsoft.Storage` service endpoint. The account keeps its public endpoint and
denies all other traffic.

Set `storage_private_endpoint_enabled = true` to replace that with a Private
Endpoint and turn the public endpoint off. The setting covers the LangSmith
trace-blob account as well, so the two accounts never end up with different
postures. SmithDB keeps using the same account hostname, which then resolves to
a VNet address through the `privatelink.blob.core.windows.net` zone. Supply
`storage_private_dns_zone_id` when the VNet already resolves that zone; Azure
links a zone name to a VNet once, so creating a second one fails.

PostgreSQL uses the delegated database subnet and the VNet's private PostgreSQL
DNS zone. Each Private Endpoint takes one further address in its subnet.

SmithDB pods run on the default node pool, so they consume its pod and IP
budget rather than adding a pool of their own. In node-subnet mode the subnet capacity check counts
`(default_node_pool_max_count + 1) * (default_node_pool_max_pods + 1)`, which is
a per-node reservation and already covers anything scheduled onto those nodes;
in overlay mode it counts nodes only, and the pods draw from `aks_pod_cidr`.
What SmithDB does change is how much of that budget is in use, so size the
default pool for the SmithDB pod count the chart adds and raise
`default_node_pool_max_count` before enabling ingestion. The capacity check then
follows the new maximum on its own. Use `additional_node_pools` with chart
scheduling overrides when SmithDB needs isolation from the rest of LangSmith.

Terraform creates the cache StorageClass with 7,000 IOPS and 1,000 MB/s. The
generated Helm overrides select it for SmithDB's per-pod cache PVCs.
`smithdb_cache_disk_iops` and `smithdb_cache_disk_throughput_mbps` tune it,
within two Azure limits: throughput cannot exceed 0.25 MB/s per provisioned IOPS
(the root module rejects that combination at plan time), and IOPS is capped by
volume size, which rises 500 IOPS per GiB above 6 GiB. Cache volume size is a
chart value, so Terraform cannot check the second limit.

Premium SSD v2 is what makes zones a requirement rather than a preference. In
most regions that offer availability zones, a Premium SSD v2 disk attaches only
to a zonal VM, so `enable_smithdb = true` requires `availability_zones` to name
at least one zone. The root module refuses the combination at plan time, because
AKS zones apply at creation and carry `ignore_changes` - recovering from a
nonzonal pool means rebuilding it, not editing a variable. A
[small set of regions](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-deploy-premium-v2#nonzonal-premium-ssd-v2-deployments)
does support nonzonal Premium SSD v2.

On an attached AKS cluster, set `availability_zones` to the zones the existing
nodes already use, and confirm those nodes are zonal before enabling SmithDB.

Adding zones to an already-built cluster does not re-zone it. The module ignores
zone changes on an existing node pool, so the plan comes back clean, the
precondition above is satisfied, and the nodes stay where they were. The
`aks_node_pool_zone_drift` check (the default pool) and the
`aks_additional_node_pool_zone_drift` check (the additional pools) report this as
a plan warning naming the live zones against the requested ones. Read that
warning: a nonzonal pool with SmithDB enabled gets a cache StorageClass no pod
can bind to. Re-zoning means rebuilding the pool. On a zoned cluster with
SmithDB on, plan also refuses an `additional_node_pools` entry that sets
`zones = []`: SmithDB's components carry no `nodeSelector` by default, so a
regional pool can receive them. That refusal reads the requested zones, not the
live ones. An additional pool created regional before `availability_zones`
reached additional pools, the default `large` pool included, passes it, and only
the drift warning names it. Replace such a pool with a zonal one before turning
SmithDB on. On a cluster built nonzonal, the path is a
zonal additional pool with SmithDB pinned to it; see
[Adding a zonal pool to a nonzonal cluster](#adding-a-zonal-pool-to-a-nonzonal-cluster).

### Adding a zonal pool to a nonzonal cluster

A cluster built without zones can take SmithDB without a rebuild. Add a zonal
pool to `additional_node_pools` and leave `availability_zones` as it is.
`availability_zones` also places PostgreSQL and Redis, so changing it on a
running deployment can move them. A pool with `zones` set satisfies the plan-time
zone check on its own.

```hcl
additional_node_pools = {
  large = {
    vm_size   = "Standard_D16s_v3"
    min_count = 0
    max_count = 2
  }
  smithdb = {
    vm_size     = "Standard_D16s_v3"
    min_count   = 1
    max_count   = 3
    zones       = ["1", "2", "3"]
    node_taints = ["workload=smithdb:NoSchedule"]
  }
}
```

Restate every pool you already run, because the map replaces the default rather
than merging with it. Set `zones` when the pool is created.

Taint the pool. An untainted pool takes any pod, and the first rollout after it
joins can fill it with LangSmith services until SmithDB no longer fits. The pool
can't scale out past `max_count` for the stranded pod.

Leave room for a rollout. A single-replica deployment starts its new pod before
it stops the old one, so a pool with no spare node for the largest SmithDB pod
leaves the new pod `Pending` after any values change, including each staged gate
flip. The chart exposes no `strategy` for compaction or compactionWorker. Plan
rejects a `smithdb` pool whose `max_count` equals its `min_count`. Confirm the VM
family's regional vCPU quota covers `max_count` nodes, or the autoscaler cannot
add the surge node either. If a rollout stalls anyway, delete the old pod and
the rollout completes.

Size the VM for the largest SmithDB pod at the chosen size; see the VM row in
[Sizing](#sizing). The `D16s_v3` pool above fits `small`, not `medium` or
`large`.

The pool does nothing until SmithDB is scheduled onto it. Pin every SmithDB
service to the pool and give it the matching toleration in
`langsmith-values-smithdb.yaml`. `init-values.sh` copies that file once and
never overwrites it.

```yaml
smithdb:
  query:
    deployment:
      nodeSelector: &smithdb_pool
        kubernetes.azure.com/agentpool: smithdb
      tolerations: &smithdb_toleration
        - key: workload
          operator: Equal
          value: smithdb
          effect: NoSchedule
  ingestion:
    deployment:
      nodeSelector: *smithdb_pool
      tolerations: *smithdb_toleration
  compactionWorker:
    deployment:
      nodeSelector: *smithdb_pool
      tolerations: *smithdb_toleration
  compaction:
    deployment:
      nodeSelector: *smithdb_pool
      tolerations: *smithdb_toleration
  clusterManager:
    deployment:
      nodeSelector: *smithdb_pool
      tolerations: *smithdb_toleration
  mutations:
    deployment:
      nodeSelector: *smithdb_pool
      tolerations: *smithdb_toleration
  runRules:
    deployment:
      nodeSelector: *smithdb_pool
      tolerations: *smithdb_toleration
  statsQuery:
    deployment:
      nodeSelector: *smithdb_pool
      tolerations: *smithdb_toleration
```

## Pre-apply review

Run the normal local gate:

```bash
bash scripts/check.sh modules/azure/infra
```

Before a real apply, also confirm:

- PostgreSQL 18 and the selected Flexible Server SKU are available in the
  chosen region, and the regional vCPU quota for its family covers it. See
  [Metastore SKU on an existing install](#metastore-sku-on-an-existing-install);
- Premium SSD v2 is available in the chosen region, and the AKS nodes are zonal.
  In most regions that offer availability zones a Premium SSD v2 disk attaches
  only to a zonal VM, so `availability_zones` has to name the zones the nodes
  run in. Zones apply at cluster creation, so an existing nonzonal pool needs
  rebuilding rather than a variable change;
- the default node pool is sized for the SmithDB pods the chart adds, and the
  AKS subnet holds every pool at maximum scale; and
- the chart PR's Azure provider values and workload-identity annotations match
  the outputs listed above.
