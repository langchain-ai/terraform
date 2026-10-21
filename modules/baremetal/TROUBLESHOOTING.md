# Troubleshooting

Symptom → cause → fix. Commands assume `kubectl --context <your context>`.

## Terraform and access

| Symptom | Cause | Fix |
|---|---|---|
| `no route to host` to node IPs from kubectl/terraform on macOS, while `curl`/`nc` work | macOS Local Network privacy blocks the terminal app | System Settings → Privacy & Security → Local Network → allow your terminal, then quit and reopen it |
| Plan fails with a budget error | requested CPU/memory of the profile + features exceed `cluster_nodes` × `max_request_ratio` | pick a smaller `sizing_profile`, disable features, or add nodes; `terraform output budget` shows the breakdown |
| Plan fails on MetalLB/Envoy custom resources | their CRDs don't exist before the first apply | `make apply ARGS="-target=module.metallb -target=module.envoy_gateway"`, then `make apply` |
| `enable_cloudflare_tunnel = true needs cloudflare_tunnel_token` | the token is a sensitive variable | `export TF_VAR_cloudflare_tunnel_token=...` before `make plan`/`apply` |

## Networking and ingress

| Symptom | Cause | Fix |
|---|---|---|
| LoadBalancer IP assigned but unreachable | the range overlaps DHCP, or is on a different subnet than the nodes, or no speaker runs on a ready node (e.g. `metallb_l2_node_selector` set to a label your nodes don't carry) | use unused addresses on the node subnet, outside the DHCP pool; keep the selector `{}` unless your nodes are labeled; `kubectl -n metallb-system get pods -o wide` |
| Plan fails: `envoy_gateway_lb_ip … is inside metallb_addresses` | the gateway IP has its own pool and must not be in the shared range | move it out of `metallb_addresses` (e.g. gateway `.50`, range `.51–.59`) |
| Apply fails: `pool "langsmith-gateway" overlaps with already defined CIDR` | upgrading an install whose `lan-pool` still contains the gateway IP: Helm creates the new pool before shrinking the old one | shrink `lan-pool` first (`kubectl -n metallb-system patch ipaddresspool lan-pool --type merge -p '{"spec":{"addresses":[...]}}'` without the gateway IP), then `make apply` again |
| `http://<gateway IP>` returns 404 after setting `langsmith_domain` | the chart's route matches only the domain | the module adds a LAN catch-all route when a domain is set; check `kubectl -n langsmith get httproute` |
| HTTP **504** after ~15 s on slow reads | Envoy Gateway's default route timeout | `envoy_gateway_route_timeout` (default 60 s); check `kubectl -n langsmith get backendtrafficpolicy` |
| SDK loses runs at process exit; frontend logs **413** | the SDK flushes its whole queue as one large multipart request on shutdown | raise the frontend body size limit, or flush more often in the client |

## LangSmith and Helm

| Symptom | Cause | Fix |
|---|---|---|
| `deploy.sh` says a Secret is missing | `make apply` or `make setup-env` hasn't run | run them in order: apply → setup-env → init-values → deploy |
| Users logged out and API keys invalid after a redeploy | `API_KEY_SALT` or `JWT_SECRET` changed | never rotate them; `setup-env` keeps existing values. Restore `infra/.secrets.env` from backup |
| A later `make deploy` still applies old experiments | `langsmith-values-local.yaml` is loaded last on every deploy | edit or delete it |
| `helm template` fails after adding `extraEnv` | the chart rejects duplicate env names | only add names the chart doesn't set already |
| Multipart batches return **500** `error enriching feedback meta … clickhouse` and their runs are lost | SmithDB-only install: feedback on recent runs falls back to ClickHouse | `ENABLE_EVALUATE_EXPIRED_EXPERIMENTS=false` on platform-backend (in the example values) |
| `POST /api/v1/runs/query` returns **501** | v1 run query needs ClickHouse | use `POST /api/v2/runs/query` |
| Agent deployment stuck in `DEPLOYING` | `config.deployment.tlsEnabled` doesn't match the hostname scheme | Terraform sets it from `langsmith_url_scheme`; re-run `make init-values` and `make deploy` after changing the scheme |
| Agent deployment pods crash on import (`TypeError: Cannot create a consistent method resolution order`) | the image pins a `langgraph` version older than the LangGraph server base image ships | don't pin `langgraph` in the agent's requirements, or pin a compatible version; rebuild with `langgraph build` |
| Agent deployments never scale, or the operator logs ScaledObject errors | KEDA isn't installed | `enable_deployments = true` installs it; check `kubectl -n keda get pods` |
| Fleet, Polly or Insights pods stay `Pending` after enabling them, though the plan passed | values from an older copy of an example file (copied once by `init-values`) set larger requests than the budget counted | replace the copied `helm/values/langsmith-values-<feature>.yaml` with the current example, then `make init-values` and `make deploy` |
| A product's queue or API pod is `OOMKilled` when it starts work | a memory limit too low for the work (older values sized limits from the slim requests) | limits now come from the full-tier sizes; refresh the copied feature files as above |
| Core `langsmith-queue` `OOMKilled` after enabling Insights | Insights clustering (`cluster_runs_job`) runs in the core queue, sized for 2 GiB by the dev profile | the Insights feature file raises the queue's memory limit to 4 GiB; refresh the copied `langsmith-values-standalone-insights.yaml` |
| SDK got 202 but the trace isn't visible | 202 means queued in Redis, not stored yet | check ingest-queue backlog and logs, and smithdb-ingestion logs |

## Ingest and Redis

| Symptom | Cause | Fix |
|---|---|---|
| Runs missing with no error anywhere | the ingest backlog grew older than `redisRunsExpirySeconds`, so queued runs expired | add ingest workers (`GO_INGESTION_CONCURRENCY_PER_CPU`, replicas), raise the expiry; alert on oldest task age |
| Ingest drain stuck well below the accept rate, nothing near its CPU limit | workers default to one per **node** core and the drain waits on I/O | raise `GO_INGESTION_CONCURRENCY_PER_CPU`; see [SIZING.md](SIZING.md#ingest-workers-ingest-queue) |
| platform-backend returns 500 `OOM command not allowed when used memory > 'maxmemory'` | Redis is full; at `noeviction` even the drain's writes fail | size Redis per [SIZING.md](SIZING.md#redis); enable blob storage; lower the expiry |
| Redis keeps growing past the expiry window | expiry can't keep up with key churn at Redis defaults | `hz 50`, `active-expire-effort 5` (the module sets them in `redis.conf`) |
| Redis memory floor creeps up; keys with TTL −1 under `smith:runs:pending:*` | run hashes recreated without a TTL when a task runs after its run expired | avoid backlogs past the expiry; remove pending hashes with TTL −1 and no `post`/`patch` field during a quiet period |
| Ingest slows under load, pods throttled | CPU limits of 1 on platform-backend, ingest-queue or Redis | limits of 2 or more; the drain pipeline is latency-sensitive |

## SmithDB

| Symptom | Cause | Fix |
|---|---|---|
| Query reads slow; logs `Too many open files (os error 24)` and `degraded cache … memory-only` | containerd's default soft limit of 1,024 open files | containerd `LimitNOFILE=1048576` on every node, restart containerd, **recreate** the pods |
| SmithDB `Flush failed … Error performing PUT` | the object store is down, restarting or out of memory | give RustFS ≥ 4 GiB and CPU; check its restarts |
| Reads of the project being written are slow | its newest files aren't merged yet and are scanned on the ingestion pods | expected; reads recover once the files merge (~10–13 min after writing stops). See [SMITHDB.md](SMITHDB.md#reads-of-a-project-being-written) |
| One project reads 10× or more slower than others its size | fresh segments left on an ingestion pod (e.g. after a restart) | metastore: `run_segments` with `writer_server_id` set and `created_at` older than 30 min; an ingestion restart releases them |
| `OOMKilled` smithdb-ingestion or compaction-worker | memory scales with payload size | raise memory limits; with MiB-scale payloads start at 8 GiB |
| compaction-worker restarts about hourly, same project each time | one compaction job over hundreds of tiny segments exhausts memory and is retried | delete the project if it's disposable; otherwise more memory and scratch space |
| compaction-worker evicted: `EmptyDir volume "cache" exceeds the limit` | merges write temporary files to its scratch volume | larger `deployment.volumes` cache size (and `ephemeral-storage` limit) |
| A deleted project's data is still in the bucket | deletes apply after the recovery window (1 h by default) | wait; see [SMITHDB.md](SMITHDB.md#deleting-a-project) |
| Idle `smithdb-compaction` and the metastore use CPU on a fresh install | the scheduler polls aggressively until the workspace has data | expected; settles once traces arrive |

## Storage

| Symptom | Cause | Fix |
|---|---|---|
| A node's root disk fills | local-path doesn't enforce PVC sizes; the object store grows with retention | watch node disk; shorten retention; move RustFS to a larger disk |
| PV stays `Released` after deleting a PVC | `local-path-retain` keeps data | reuse it (clear `spec.claimRef`) or delete the PV **and** its directory on the node |
| Deleted a Retain PV, disk still full | deleting the PV object never touches the data | remove the `pvc-…` directory under the provisioner path on that node |
| `ImagePullBackOff` on MinIO images | MinIO community images are no longer published | this module uses RustFS |
