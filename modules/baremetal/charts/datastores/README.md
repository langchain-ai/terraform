# datastores

LangSmith's in-cluster Postgres, Redis and RustFS, the stores a cloud would run as managed services. The bare-metal
module installs this chart with `helm_release` (`infra/datastores.tf`); anyone applying their own manifests
installs the same chart with the same values through Helm or Argo CD.

## Two runtimes, one interface

| Store | `runtime: statefulset` (default) | `runtime: operator` |
|---|---|---|
| Postgres `langsmith`, `smithdb` | a StatefulSet on the official image, one pod | a [CloudNativePG](https://cloudnative-pg.io/documentation/current/) `Cluster`, `replicas` instances, product databases as `Database` resources |
| Redis `langsmith`, `juicefs` | a StatefulSet on the official image, one pod | an [OpsTree](https://github.com/OT-CONTAINER-KIT/redis-operator) `RedisReplication`; above one replica, three Sentinels fail it over |
| RustFS | a StatefulSet, bucket Jobs | the same: RustFS has no operator |

What LangSmith reads is the same in both, so nothing downstream changes with the runtime:

- Postgres at `postgres-<instance>.<namespace>.svc.cluster.local:5432`: the StatefulSet's headless Service, or a
  Service CloudNativePG manages on the primary (`managed.services.additional`, selector `rw`).
- Redis at `redis-<instance>.<namespace>.svc.cluster.local:6379`: the StatefulSet's headless Service, or a Service on
  the pod the operator labels `redis-role: master`. The operator's own Service, named after the resource
  (`redis-<instance>-replication`), selects replicas too.
- RustFS at `http://rustfs.<namespace>.svc.cluster.local:9000`.
- The user, database and password you give. In both runtimes the Postgres user is a superuser, because LangSmith's
  migrations create extensions ([external Postgres requirements](https://docs.langchain.com/langsmith/self-host-external-postgres#requirements)),
  and Redis runs `maxmemory-policy noeviction` ([external Redis](https://docs.langchain.com/langsmith/self-host-external-redis)).

Every store that runs as one pod (each StatefulSet) has a PodDisruptionBudget of zero, named for its instance: its
volume is on one node, so a drain of that node stops and names it instead of taking the store down. The module's
ARCHITECTURE.md has the drain procedure.

With `replicas` above 1 under the operator runtime, those two Services are what make a failover invisible to LangSmith:
the Postgres one selects whichever instance CloudNativePG has made primary (the same selector as its `-rw` Service),
and the Redis one whichever pod the operator labels `redis-role: master` after the Sentinels promote it (the same
selector as the operator's `-master` Service).

Every object is named for its instance (`postgres-langsmith`, `postgres-smithdb`, `redis-langsmith`, `redis-juicefs`,
`rustfs`, their Secrets `<instance>-credentials`, and a Redis StatefulSet's `redis.conf` in a ConfigMap `<instance>-config`) and selected by the label
`langsmith.lab/datastore-instance`, so all of them can share one namespace: set `namespace` (the module sets
`langsmith-data`) and a shared cluster gets one data namespace per environment beside LangSmith's. Left empty, each
instance goes to its own `namespace`.

Each namespace gets a default-deny NetworkPolicy, except one in `allowedNamespaces` (the stores in LangSmith's own
namespace, whose pods nothing here admits), and Pod Security `baseline` (`restricted` when it holds RustFS alone);
each instance a policy that admits its own namespace, `allowedNamespaces` and its `allowedCidrs`, and a preferred anti-affinity on
`datastoreLabel` that spreads the stores across nodes. Postgres sizes `shared_buffers` (a quarter) and
`effective_cache_size` (a half) from its memory limit; Redis sets `maxmemory` to three quarters of its own, leaving room
for the copy-on-write fork of a save.

## Values

Every key, with its default and why, is in [values.yaml](values.yaml); [values.schema.json](values.schema.json)
refuses anything else.

| Key | What it sets |
|---|---|
| `runtime` | `statefulset` or `operator` |
| `storageClass` | every data volume's class; use one that retains the volume when its claim is deleted |
| `namespace` | one namespace for every store; empty: each instance's own `namespace` |
| `createNamespaces` | `false` when the stores' namespaces already exist |
| `existingSecrets` | `true`: render no credential Secret and read the ones your secret store writes, of the same names and keys ([values.yaml](values.yaml) lists them); every password and key is then ignored |
| `allowedNamespaces` | namespaces whose pods may connect to every store: LangSmith's |
| `datastoreLabel` | the label the anti-affinity spreads by |
| `operatorNamespaces.postgres`, `.redis` | where the operators run, admitted to their stores' pods |
| `postgres.image`, `.operatorImage` | the official image, and the CloudNativePG operand image of the same version |
| `postgres.instances.langsmith`, `.smithdb` | `enabled`, `namespace`, `database`, `username`, `password`, `databases` (one per product), `maxConnections`, `replicas` (operator only), `resources`, `volumeSize` |
| `redis.image`, `.operatorImage`, `.sentinelImage` | the official image, and the OpsTree images the operator drives |
| `redis.sentinelResources` | each Sentinel's requests and limits (100m, 128Mi: the operator's own replication-with-Sentinel example) |
| `redis.instances.langsmith`, `.juicefs` | `enabled`, `namespace`, `password`, `persistence` (`rdb` or `aof`), `maxmemoryPolicy`, `allowedCidrs`, `replicas` (operator only), `resources`, `volumeSize` |
| `rustfs` | `enabled`, `namespace`, `image`, `awsCliImage`, `accessKey`, `secretKey`, `buckets`, `ttlBuckets` (the blob bucket, with LangSmith's `ttl_s/` and `ttl_l/` expiry), `ttlDays`, `allowedCidrs`, `resources`, `volumeSize` |

Unless `existingSecrets` is set, passwords and keys are required and alphanumeric: they are pasted into connection URLs. Keep them in a values file of
their own, out of git, as the module does (it passes them as a second values document).

## Applying it yourself

1. With `runtime: operator`, install the operators first, each its own release, because a custom resource cannot be
   installed in the release that brings its CRD:
   ```bash
   helm upgrade -i cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version 0.29.1 \
     -n cnpg-system --create-namespace --wait
   helm upgrade -i redis-operator redis-operator --repo https://ot-container-kit.github.io/helm-charts \
     --version 0.27.0 -n redis-operator --create-namespace --wait
   ```
2. Take the values the module would use: `terraform output -raw datastore_values > datastores-values.yaml` in
   `infra/`, or write them by hand from [values.yaml](values.yaml). Put the passwords in `datastores-secrets.yaml`:
   ```yaml
   postgres: { instances: { langsmith: { password: <32 alphanumerics> }, smithdb: { password: <...> } } }
   redis: { instances: { langsmith: { password: <...> } } }
   rustfs: { accessKey: <20 alphanumerics>, secretKey: <40 alphanumerics> }
   ```
3. Install it, from any namespace (the module keeps the release in `langsmith`; the stores go to `namespace`):
   ```bash
   helm upgrade -i langsmith-datastores ./charts/datastores -n langsmith \
     -f datastores-values.yaml -f datastores-secrets.yaml --wait --timeout 15m
   ```
   Argo CD: an Application with this chart as its source and both files as `valueFiles` (the secrets one through your
   secret store's plugin), or, with External Secrets, `existingSecrets: true` and an ExternalSecret per Secret
   [values.yaml](values.yaml) names, synced before the chart. The bucket and database Jobs are Helm hooks, which Argo CD runs as PostSync.
4. Create the Secrets LangSmith reads in its namespace from the same passwords, as the module's `main.tf` does:
   `langsmith-postgres` (`connection_url` = `langsmith:<password>@postgres-langsmith.langsmith-data.svc.cluster.local:5432/langsmith`,
   no scheme), `langsmith-redis` (`connection_url` = `redis://:<password>@redis-langsmith.langsmith-data.svc.cluster.local:6379/0`),
   `smithdb-config` (the metastore's host, database, user and password, and RustFS's two keys), and one
   `langsmith-<product>-postgres` and `-redis` per standalone product.

## Behaviour to know

- A StatefulSet's volume claim keeps the size it was created with: Kubernetes refuses a change to it, so the chart reads
  the claim already in the cluster and keeps it (where `lookup` has no cluster, as in `helm template` and Argo CD, a new
  size fails the sync). A real resize means expanding the claim on a driver that can.
- Uninstalling the release deletes the namespaces it created and the claims in them; on a Retain class the volumes and their data stay
  until you delete them.
- Bump `version` in [Chart.yaml](Chart.yaml) with every change: the Terraform helm provider upgrades a local chart only
  when its values or version change.
- `bash scripts/check.sh modules/baremetal` lints and renders the chart with each file in `ci/`: one per runtime, and one with `existingSecrets`.
