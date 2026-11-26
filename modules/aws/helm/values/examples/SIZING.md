# LangSmith sizing on AWS

Every install runs one sizing: the [medium reads, medium writes](https://docs.langchain.com/langsmith/self-host-scale#medium-reads-medium-writes) pattern in the scale guide, about 20 concurrent users and 100 traces per second, with the SmithDB small tier. [`langsmith-values.yaml`](langsmith-values.yaml) sets it:

| Service | Setting | Source |
|---|---|---|
| `frontend` | 2 replicas | the pattern |
| `backend` | HPA, 8 to 16 replicas | the pattern's autoscaling range |
| `ingestQueue` | KEDA, 3 to 6 replicas | the pattern's autoscaling range |
| `queue` | KEDA, 1 to 10 replicas | the chart's range, with KEDA on |
| SmithDB compaction worker | KEDA, 1 to 10 replicas | [SmithDB scale guide](https://docs.langchain.com/langsmith/self-host-smithdb-scale) |
| `config.settings.redisRunsExpirySeconds` | `3600` | the pattern |
| `CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT` | `0`, in the generated overrides file | the pattern |

Every other service runs the chart's own requests, limits and replica count, and no example values file requests less than the chart's default; `make test-values` checks both. The pattern's Redis, 13 GiB, is the default ElastiCache node, `cache.m6g.xlarge`. Its ClickHouse, 16 CPU and 24 GiB, does not fit the default `m6a.2xlarge` LangSmith nodes, and with SmithDB serving reads ClickHouse mostly takes writes, so in-cluster ClickHouse keeps the chart's 3.5 CPU and 12 GiB.

Rendered from chart 0.18.2 at minimum replicas, the core services request 22 CPU and 49 GiB across 21 pods, in-cluster ClickHouse included. Deployments, Fleet, LangSmith Chat and Insights together add about 10 CPU and 21 GiB, and Insights moves ClickHouse out of the cluster. SmithDB runs on its own node group, sized in [SMITHDB.md](../../../SMITHDB.md). Cluster Autoscaler adds LangSmith nodes, up to the node group's `max_size`, as the HPA and KEDA scale out.

## Sizing beyond the pattern

Edit `helm/values/langsmith-values.yaml`, the copy `make init-values` made, then run `make deploy`. The scale guide's [high reads, high writes](https://docs.langchain.com/langsmith/self-host-scale#high-reads-high-writes) section has the next set of numbers. An autoscaler owns the replica count once it is on, so set `maxReplicas` at or above the count the pattern calls for. No feature overlay sets the replicas or autoscaling of these services, so this file's values hold.

The SmithDB tier is set in `langsmith-values-smithdb.yaml`, which loads after this file; `make deploy` stops when `langsmith-values.yaml` sets a different tier. See [Scaling up](../../../SMITHDB.md#scaling-up).

## Moving from a 0.17 sizing profile

0.18 removed `sizing_profile` and its four files. Terraform warns about a leftover `sizing_profile` line, and `make deploy` stops while a `langsmith-values-sizing-*.yaml` is left in `helm/values`, because it no longer loads that file. To move:

1. `make init-values` copies `langsmith-values.yaml` only when `helm/values` has none, so a 0.17 copy lacks this sizing. Copy the `frontend`, `backend` and `config.settings` blocks from `helm/values/examples/langsmith-values.yaml` into it.
2. Copy any values you changed in `helm/values/langsmith-values-sizing-<profile>.yaml` into `helm/values/langsmith-values.yaml`.
3. Delete the sizing file, and the `sizing_profile` line in `infra/terraform.tfvars`.
4. Run `make init-values`, then `make deploy`.

A `production-large` install keeps that profile's ranges (backend 10 to 50, queue and ingest-queue 6 to 24) only by copying them across.

## Product workloads

Fleet, LangSmith Chat and Insights each run an api-server and a queue Deployment, sized in their overlays:

- `fleet.apiServer.deployment.resources` and `fleet.queue.deployment.resources`
- `polly.apiServer.deployment.resources` and `polly.queue.deployment.resources`
- `engineInsightsAgent.apiServer.deployment.resources` and `engineInsightsAgent.queue.deployment.resources`

The chart gives these six Deployments no requests, so the overlays set them. Each add-on keeps its data in its own database on the shared RDS instance and its own index on the shared ElastiCache.
