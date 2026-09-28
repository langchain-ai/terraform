# Migrating from chart 0.16 to chart 0.17

These modules wrap the LangSmith Helm chart, so a chart minor bump changes the
values files the modules ship. This note covers what changed, what you have to do,
and what the modules now do for you.

The 0.16 values schema carries over to 0.17. The one change the modules absorb is
sandboxes: chart 0.17 removes the bundled JuiceFS CSI driver. A deployment with
`enable_sandboxes = false` only moves the chart pin.

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

- The bucket identity moves to the sandbox-host ServiceAccount. The IRSA role (AWS)
  or Workload Identity service account (GCP) is now written there. On GCP, only the
  `juicefs-format` Job uses it (see the next items).
- On GCP, Terraform binds `langsmith-sandbox-host` to the LangSmith service account
  through Workload Identity, so run `terraform apply` before the deploy. The binding
  for the old `juicefs-csi-node-sa` stays through the upgrade. The `juicefs-format`
  Job uses this binding.
- On GCP, `sandbox-host` runs on the host network, and GKE does not give Workload
  Identity to host-network pods. The JuiceFS mount therefore uses the sandbox node
  service account (`<name>-sbox-node`). `terraform apply` now grants that account
  `roles/storage.objectAdmin` on the bucket, limited by an IAM condition to objects
  under `<sandbox_juicefs_name>/`. Without the grant, JuiceFS gets 403 from GCS.
- On GCP, `deploy.sh` sets `images.sandboxHostImage.tag` from the chart
  `appVersion`, as on AWS. `sandbox_host_image_tag` is ignored, so remove it from
  `terraform.tfvars`. Before, a tag from chart 0.16 kept the old `sandbox-host`
  image, and the `juicefs-format` Job used that image too.
- On GCP, the sandbox-host machine type now follows `sizing_profile`. With
  `production` or `production-large` and no `sandbox_host_machine_type`,
  `terraform apply` changes the pool to `n2-standard-32`. GKE recreates every
  sandbox-host node for the machine type change, so running sandboxes stop. See
  step 3.
- On GCP, `sandbox_host_min_node_count` now defaults to 0 per zone, not 1. With no
  explicit value, the autoscaler removes the empty sandbox-host nodes after
  `terraform apply`, and keeps the nodes that run sandbox-host. `make init-values`
  adds the `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` annotation to
  sandbox-host, so run `make init-values` and `make deploy` soon after
  `make apply`. To keep one node in every zone, set
  `sandbox_host_min_node_count = 1`.
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

## Upgrade path

1) Take a database backup. Chart downgrades are not supported, so 0.17 to 0.16 is not
   a rollback path - see [Self-host upgrades](https://docs.langchain.com/langsmith/self-host-upgrades).
2) Check out a `v0.17.*` tag.
3) Run `make apply`. On GCP with sandboxes, this adds the `langsmith-sandbox-host`
   Workload Identity binding and the bucket grant for the sandbox node service
   account. With `sizing_profile` set to `production` or `production-large`, and
   no `sandbox_host_machine_type` in `terraform.tfvars`, first set
   `sandbox_host_machine_type = "n2-standard-8"`. The pin keeps the current
   sandbox-host nodes and their mounted chart 0.16 volumes until the drain in
   step 5. After step 6, remove the pin. Then run `make apply` again. GKE recreates
   every sandbox-host node, and running sandboxes stop.
4) Run `make init-values` so the generated overrides file is regenerated in the 0.17
   shape.
5) Deploy: `make deploy`. If sandboxes ran on chart 0.16, the first run stops and
   prints the drain commands. Run them, then run `make deploy` again.
6) With sandboxes, confirm the format Job completed, sandbox-host is ready, and the
   CSI driver is gone:

```bash
kubectl get jobs -n langsmith -l app.kubernetes.io/component=juicefs-format
kubectl rollout status deployment -n langsmith -l app=sandbox-host --timeout=10m
kubectl get daemonset,statefulset -n langsmith | grep juicefs-csi   # expect no output
```
