# Teardown

Remove LangSmith first, then the infrastructure. Datastore volumes use a **Retain** StorageClass, so their data stays on
the nodes until you delete it by hand. That is deliberate: a `terraform destroy` should never be the only copy of a
decision to lose trace data.

## 1. Back up what you want to keep

| Data | How |
|---|---|
| LangSmith Postgres | `pg_dump` from the `postgres-langsmith` pod |
| SmithDB metastore | `pg_dump` from the `postgres-smithdb` pod, **at the same time** as the bucket copy |
| Object storage | copy buckets `smithdb` and `langsmith-blobs` with any S3 client (`aws s3 sync --endpoint-url ...`) |
| App secrets | `infra/.secrets.env` (without `API_KEY_SALT` and `JWT_SECRET`, restored keys and logins stop working) |

## 2. Uninstall LangSmith

```bash
helm --kube-context <ctx> uninstall langsmith -n langsmith
kubectl --context <ctx> -n langsmith get pvc     # SmithDB cache PVCs (larger tiers) are deleted with their pods
```

## 3. Destroy the infrastructure

```bash
make destroy
```

This removes the datastores, add-ons (MetalLB, Envoy Gateway, metrics-server, local-path), the optional tunnel
connector, the `langsmith` namespace, and every Secret Terraform created. While the tunnel flag is on, export
`TF_VAR_cloudflare_tunnel_token` first. Delete the tunnel and its DNS record in the Cloudflare dashboard separately.

If a namespace hangs in `Terminating`, a finalizer is waiting on a controller that was already removed; check
`kubectl get namespace <ns> -o yaml` and the remaining objects in it.

## 4. Remove retained data

The Postgres, Redis and RustFS PersistentVolumes outlive the destroy (status `Released`). For each:

```bash
kubectl --context <ctx> get pv                                   # note the node and path of each Released PV
kubectl --context <ctx> delete pv <name>                         # removes the object only
ssh <node> 'sudo rm -rf /opt/local-path-provisioner/pvc-<id>_<namespace>_<claim>'   # removes the data
```

Use the path printed by `kubectl get pv <name> -o jsonpath='{.spec.hostPath.path}'`, and double-check it before deleting.

## 5. Local files

`infra/terraform.tfstate*`, `infra/terraform.tfvars`, `infra/.secrets.env` and `helm/values/langsmith-values*.yaml` are
gitignored and contain credentials or cluster details. Delete them, or keep them somewhere safe if you plan to rebuild.
