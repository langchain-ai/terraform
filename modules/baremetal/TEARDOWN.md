# Teardown

Remove LangSmith first, then the infrastructure. With local-path (the default), datastore volumes use a **Retain**
StorageClass, so their data stays on the nodes until you delete it by hand. Your own `storage_class` must be Retain too;
`make plan` refuses another. A `terraform destroy` is never the only decision behind losing trace data.

## 1. Back up what you want to keep

A consistent copy needs writes stopped first: SmithDB's metastore and its bucket must describe the same files, and Redis
holds runs not yet ingested. Scale the platform backend to 0 so nothing new arrives, wait until the ingest queue is
empty, then scale the ingest queue and SmithDB's ingestion and compaction Deployments to 0 (`kubectl -n langsmith get
deploy` names them). Take the copies below, then scale each back or carry on with the teardown.

| Data | How |
|---|---|
| LangSmith Postgres | `pg_dump` from the `postgres-langsmith` pod |
| SmithDB metastore | `pg_dump` from the `postgres-smithdb` pod, **at the same time** as the bucket copy |
| ClickHouse (`clickhouse_source = "in-cluster"`) | finish the migration to SmithDB first, or back up its volume (claim `data-langsmith-clickhouse-0`) |
| Object storage | copy buckets `smithdb` and `langsmith-blobs` (and `sandbox-juicefs` with Sandboxes on) with any S3 client (`aws s3 sync --endpoint-url ...`) |
| App secrets | `infra/.secrets.env` (without `API_KEY_SALT` and `JWT_SECRET`, restored keys and logins stop working) |
| Datastore passwords | the `*-credentials` Secrets in `langsmith-data` (`kubectl get secret -o yaml`). A destroy forgets them and the next apply generates new ones, which a retained data directory refuses. Rebuild by restoring the dumps above into fresh stores; the retained volumes are the last resort, readable only with these old passwords |
| Secrets you made | every Secret you created in `langsmith` (an external store's, `gateway_tls_secret`): the destroy deletes the namespace and them with it |

## 2. Uninstall LangSmith

```bash
helm --kube-context <ctx> uninstall langsmith -n langsmith
kubectl --context <ctx> -n langsmith get pvc     # SmithDB cache PVCs (larger tiers) are deleted with their pods
```

ClickHouse's volume stays after the uninstall, on `local-path-retain`: deleting its PVC leaves the data on disk until
step 4 removes it.

## 3. Destroy the infrastructure

```bash
make destroy
```

This removes the datastores, the add-ons this module installed (MetalLB, Envoy Gateway, metrics-server, local-path,
each unless its `install_*` input is `false`), the optional tunnel connector, the sandbox nodes' label and taint, the
`langsmith` namespace, and every Secret Terraform created. While the tunnel flag is on, export
`TF_VAR_cloudflare_tunnel_token` first. Delete the tunnel and its DNS record in the Cloudflare dashboard separately.

If a namespace hangs in `Terminating`, a finalizer is waiting on a controller that was already removed; check
`kubectl get namespace <ns> -o yaml` and the remaining objects in it.

## 4. Remove retained data

With local-path, the Postgres, Redis, RustFS and ClickHouse PersistentVolumes outlive the destroy (status `Released`). For each:

```bash
kubectl --context <ctx> get pv                                   # note the node and path of each Released PV
kubectl --context <ctx> delete pv <name>                         # removes the object only
ssh <node> 'sudo rm -rf /opt/local-path-provisioner/pvc-<id>_<namespace>_<claim>'   # removes the data
```

`/opt/local-path-provisioner` is the default `local_path_node_path`. Use the path printed by
`kubectl get pv <name> -o jsonpath='{.spec.hostPath.path}'`, and double-check it before deleting.

## 5. Local files

`infra/terraform.tfstate*`, `infra/terraform.tfvars`, `infra/.secrets.env` and `helm/values/langsmith-values*.yaml` are
gitignored and contain credentials or cluster details. Delete them, or keep them somewhere safe if you plan to rebuild.
