# Migrating from chart 0.16 to chart 0.17

These modules wrap the LangSmith Helm chart, so a chart minor bump changes the
values files the modules ship. This note covers what changed, what you have to do,
and what the modules now do for you.

Most of the 0.16 values schema carries over to 0.17. The modules absorb two changes:

- Sandboxes: chart 0.17 removes the bundled JuiceFS CSI driver (sections 1 and 2).
- SmithDB on GCP: chart 0.17 changes the cache and migration values (section 3).

A deployment with `enable_sandboxes = false` and `enable_smithdb = false` only moves
the chart pin.

## Status of the 0.17 line

All four `deploy.sh` chart-line pins are on `~0.17.0`, so a deploy takes the newest
`0.17.x` patch and never crosses into `0.18`. Each `deploy.sh` refuses anything off
that line before it contacts the chart repository, and on AWS the
`langsmith_helm_chart_version` variable rejects it at plan time.

`CHART_VERSION` can still narrow the pin to an exact 0.17 patch:

```bash
cd modules/aws && make apply && make init-values && CHART_VERSION="0.17.0" make deploy
```

Two 0.16-only checks are gone. The `0.16.0-rc.24` prerelease check and the GCP
SmithDB `0.16.6` check cannot fire on a 0.17 version, and the 0.17 line carries the
migration Job fix that the second one guarded.

On Azure, `enable_smithdb = true` no longer needs `langsmith_helm_chart_version` set
explicitly. SmithDB is part of the pinned line.

Chart 0.17 also supports sandboxes on Azure (`storage: wasb`). The Azure module does
not provision them yet.

## 1) Sandboxes mount JuiceFS in sandbox-host

This applies to `enable_sandboxes = true` on AWS and GCP.

Chart 0.17 deletes the JuiceFS CSI driver: the `juicefs-csi-node` DaemonSet, the
`juicefs-csi-controller` StatefulSet, and the `smithbox-juicefs-csi` PVs and PVCs.
`sandbox-host` now mounts JuiceFS itself, and a new `juicefs-format` Job formats the
volume. Both run under the sandbox-host ServiceAccount, `langsmith-sandbox-host` for
the default release name.

| chart 0.16 | chart 0.17 |
|---|---|
| `sandboxes.juicefs.csi.existingSecretName` | `sandboxes.juicefs.existingSecretName` |
| `sandboxes.juicefs.csi.node.serviceAccount.annotations` | `sandboxes.sandboxHost.serviceAccount.annotations` |
| `sandboxes.juicefs.csi.mountPodPatch` (cache options) | `sandboxes.juicefs.hostMount.cacheDirs` and `mountOptions` |
| none | `sandboxes.juicefsFormatJob.*` |

`init-values.sh` generates the new shape. The JuiceFS Secret that Terraform creates
(`juicefs-csi-config` by default) keeps its name and its keys - `name`, `metaurl`,
`storage`, and `bucket` - and chart 0.17 reads the same keys. The volume, its data,
and its metadata carry over.

What the modules do for you:

- The bucket identity moves with the mount. The IRSA role (AWS) or Workload Identity
  service account (GCP) is now written to the sandbox-host ServiceAccount.
- On GCP, Terraform binds `langsmith-sandbox-host` to the LangSmith service account
  through Workload Identity, so run `terraform apply` before the deploy. The binding
  for the old `juicefs-csi-node-sa` stays through the upgrade.
- On AWS, when the sandbox-host nodes have spare instance-store NVMe
  (`sandbox_host_local_nvme_bootstrap_enabled` with more than one device),
  `init-values.sh` passes those mounts (`/mnt/juicefs-cache*`) as
  `hostMount.cacheDirs`. The defaults (`m5d.metal`, four devices) give three mounts,
  because the first device is swap. Otherwise the chart caches under
  `/var/cache/juicefs` on the root volume. The 0.16 modules never passed those mounts
  to the chart, so the cache moves onto NVMe with this upgrade.
- `deploy.sh` refuses a values file that still carries `sandboxes.juicefs.csi`. Chart
  0.17 ignores that block, and its own validation then fails the release on
  `sandboxes.juicefs.redis.metaURL`, which does not name the fix. Re-run
  `make init-values`.

If you keep your own overlay, move the keys as the table shows.

A rewrite of the Secret contents in place (a bump of
`sandbox_juicefs_csi_config_secret_revision`) no longer restarts anything, because
chart 0.17 tracks only the Secret name. Restart sandbox-host after such a change:

```bash
kubectl rollout restart deployment/langsmith-sandbox-host -n langsmith
```

## 2) Drain the JuiceFS CSI volumes before the upgrade

This applies to installs that ran sandboxes on chart 0.16.

The upgrade removes the CSI driver. If the old sandbox-host pods still mount its
volumes at that moment, kubelet cannot unmount them. The pods then stay in
`Terminating` on `juicefs.com/finalizer`, and the new sandbox-host pods cannot take
their nodes.

The AWS and GCP `deploy.sh` therefore stop before they change anything while the
namespace still has JuiceFS claims or mount pods. They print the commands that drain
the volumes while the driver still runs. With the default names:

```bash
kubectl delete -n langsmith deployment.apps/langsmith-sandbox-host
kubectl delete -n langsmith persistentvolumeclaim/smithbox-juicefs-csi
kubectl delete -n langsmith persistentvolumeclaim/smithbox-juicefs-csi-host
kubectl get pods -n langsmith | grep juicefs   # wait until only juicefs-csi-* pods remain
```

Running sandboxes stop during the drain. Their data stays: both PVs use
`persistentVolumeReclaimPolicy: Retain`, and the JuiceFS data and metadata live in
object storage and Redis. Chart 0.17 mounts the same volume through the same Secret.

Run `make deploy` again after the drain. The check passes once no claim or mount pod
is left, and the upgrade then removes the driver.

## 3) SmithDB on GCP

This section applies to `enable_smithdb = true` on GCP. The AWS SmithDB overlay is
not yet fixed for chart 0.17: it still sets `smithdb.migration.deployment`, which
chart 0.17 rejects, and it sets no cache volume.

| chart 0.16 | chart 0.17 |
|---|---|
| With no cache values, each cache is an `emptyDir` | With no cache values, each cache is a per-pod PVC from `smithdb.cache.storageClassName`, or the cluster default class (`standard-rwo` on GKE, too slow for the cache) |
| The GCP overlay names the `/data` volume `local-ssd-storage` | The volume must be named `cache` |
| `smithdb.migration.deployment` | `smithdb.migration.job`. The chart fails on the old key |

The GCP module now writes the SmithDB tier, resources, HPA minimum replicas, cache
volumes, and node placement to the generated `langsmith-values-smithdb-sizing.yaml`.
The Cloud SQL Auth Proxy is now the default for a created metastore.

- Check the size. An unset `smithdb_sizing` follows `sizing_profile`.
  - An existing `production` install resolves to `medium`. Terraform then replaces
    the cache pool with `n2-standard-32` and 4 Local SSD. The compute pool stays
    `n2-standard-8`.
  - An existing `production-large` install resolves to `large`. Terraform then
    replaces the cache pool with `n2-standard-64` and 8 Local SSD, and the compute
    pool with `n2-standard-16`. `large` runs 12 SmithDB pods that request about
    350 vCPU. To avoid this, set `smithdb_sizing = "medium"` or `"small"`.
  - A `minimum` install resolves to `minimal` and has no SmithDB node pools.
  - To keep the 0.16 pool (n2-standard-16, 2 Local SSD), set
    `smithdb_sizing = "small"`: `make smithdb-configure SIZING=small CACHE=local-ssd`.
- Check the metastore tier. An unset `smithdb_metastore_tier` now follows the size.
  - For a created metastore, the tier goes from `db-custom-2-8192` to
    `db-custom-4-16384` for `small`, `db-custom-6-32768` for `medium`, and
    `db-custom-10-65536` for `large`. `minimal` keeps `db-custom-2-8192`.
  - `make apply` then resizes the Cloud SQL instance. The resize takes the instance
    offline for less than 60 seconds.
  - To keep the old tier, set `smithdb_metastore_tier = "db-custom-2-8192"`.
  - An external metastore does not change.

Then do the other steps in
[Upgrade from chart 0.16](modules/gcp/SMITHDB.md#upgrade-from-chart-016): the
metastore TLS values, the overlay, and the backfill Job. That section also covers
a direct `helm upgrade`.

## Upgrade path

1) Take a database backup. Chart downgrades are not supported, so 0.17 to 0.16 is not
   a rollback path - see [Self-host upgrades](https://docs.langchain.com/langsmith/self-host-upgrades).
2) Check out a `v0.17.*` tag. With SmithDB on GCP, make the `terraform.tfvars` and
   overlay changes of section 3 before step 3. Steps 3 to 5 then run `make apply`,
   `make init-values`, and `make deploy`.
3) Run `make apply`. On GCP with sandboxes, this adds the `langsmith-sandbox-host`
   Workload Identity binding.
4) Run `make init-values` so the generated overrides file is regenerated in the 0.17
   shape.
5) Deploy: `make deploy`. If sandboxes ran on chart 0.16, the first run stops and
   prints the drain commands. Run them, then run `make deploy` again.
6) With sandboxes, confirm the format Job completed, sandbox-host is ready, and the
   CSI driver is gone:

```bash
kubectl get jobs -n langsmith -l app.kubernetes.io/component=juicefs-format
kubectl rollout status deployment/langsmith-sandbox-host -n langsmith --timeout=10m
kubectl get daemonset,statefulset -n langsmith | grep juicefs-csi   # expect no output
```
