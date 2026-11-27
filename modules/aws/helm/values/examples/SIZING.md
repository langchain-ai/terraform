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

Every other service runs the chart's own requests, limits and replica count, and no example values file requests less than the chart's default; `make test-values` checks both. The pattern's Redis, 13 GiB, is the default ElastiCache node, `cache.m6g.xlarge`. The QuickStart Dev / POC profile writes `cache.m6g.large`, about 6.4 GiB, and `terraform.tfvars.dev` sets `cache.t3.medium`, about 3 GiB; set `redis_instance_type = "cache.m6g.xlarge"` in `terraform.tfvars` for the pattern's Redis. In-cluster ClickHouse stays below the pattern: see [ClickHouse](#clickhouse).

## Capacity

Rendered from chart 0.18.2, the core services, in-cluster ClickHouse included, request 22 CPU and 49 GiB across 21 pods at minimum replicas, and 42 CPU at maximum. Deployments, Fleet, LangSmith Chat and Insights together add about 10 CPU and 21 GiB at minimum replicas, and 13 CPU at maximum. SmithDB runs on its own node group, sized in [SMITHDB.md](../../../SMITHDB.md).

Cluster Autoscaler adds LangSmith nodes, up to the node group's `max_size`, as the HPA and KEDA scale out. On `m6a.2xlarge` nodes the sizing runs on 4 to 5 nodes at minimum replicas and needs up to 8 at maximum, so keep `max_size` at 8 or more. The Terraform default and both QuickStart profiles set 10. Under a lower ceiling, the replicas that the HPA and KEDA add stay `Pending`.

## Sizing beyond the pattern

Put the new values in `helm/values/langsmith-values-local.yaml`, then run `make init-values` and `make deploy`. `make init-values` merges that file last, so its values win over this sizing. Do not edit `helm/values/langsmith-values.yaml`: `make init-values` writes it again on every run, and `make deploy` stops on a hand edit. The scale guide's [high reads, high writes](https://docs.langchain.com/langsmith/self-host-scale#high-reads-high-writes) section has the next set of numbers. An autoscaler owns the replica count once it is on, so set `maxReplicas` at or above the count the pattern calls for. No feature overlay sets the replicas or autoscaling of these services, so the values hold.

The SmithDB example sets the small tier. Set another tier in `langsmith-values-local.yaml` too. See [Scaling up](../../../SMITHDB.md#scaling-up).

## Moving from a 0.17 sizing profile

0.18 removed `sizing_profile` and its four files. Terraform warns about a leftover `sizing_profile` line, and `make init-values` and `make deploy` stop while a `langsmith-values-sizing-*.yaml` is left in `helm/values`, because a deploy no longer applies that file. No value in that file applies after the move unless you copy it. To move:

1. Copy the ranges and limits in `helm/values/langsmith-values-sizing-<profile>.yaml` that you rely on, and any value you changed, into `helm/values/langsmith-values-local.yaml`. Keep each request at or above the chart's [default](https://docs.langchain.com/langsmith/self-host-scale#default-resource-requests-and-limits); some 0.17 profiles set requests below it.
   - `production` ran `frontend`, `platformBackend`, `aceBackend` and `playground` on HPAs, up to 10, 10, 5 and 5 replicas, where this sizing runs 2, 3, 1 and 1. It let `ingestQueue` reach 10 replicas, not 6, and `hostBackend` 10, not 5.
   - `production-large` set wider ranges, such as backend 10 to 50, queue and ingest-queue 6 to 24, and platform-backend 5 to 20. It also set limits of 4 CPU and 8 GiB on `backend`, `queue` and `ingestQueue`, and 2 CPU and 4 GiB on `frontend`, twice the chart's. Copy its `autoscaling` blocks and those limits.
   - `dev` and `minimum` are smaller than this sizing. Copy only the values you changed on purpose.
2. Check the LangSmith node group in `infra/terraform.tfvars` against [Capacity](#capacity), and run `make apply` after a change. A node group made from the 0.17 `minimum` preset, one or two `m5.xlarge` nodes, cannot hold even the minimum replicas.
3. Move the sizing file out of `helm/values`, and delete the `sizing_profile` line in `infra/terraform.tfvars`. The README section "Move from the 0.17 values layout" covers the other 0.17 files.
4. Run `make init-values`, then `make deploy`.

## ClickHouse

The pattern gives ClickHouse 16 CPU and 24 GiB, which do not fit an `m6a.2xlarge` LangSmith node. In-cluster ClickHouse, the default, keeps the chart's 3.5 CPU, 12 GiB and 50 GiB volume. With SmithDB serving reads, ClickHouse mostly takes writes, so its volume is the first limit. The scale guide plans 60 GiB for each day of short-lived trace TTL at a constant 100 traces per second, and the chart keeps short-lived traces for 14 days: 840 GiB, against the 50 GiB volume.

Grow the volume in place. The `gp3` StorageClass allows it, and EBS accepts one change to a volume every six hours:

```bash
kubectl patch pvc data-langsmith-clickhouse-0 -n langsmith \
  -p '{"spec":{"resources":{"requests":{"storage":"<size>Gi"}}}}'
```

Do not change `clickhouse.statefulSet.persistence.size` on an existing install. Kubernetes does not let a StatefulSet change its volume claim template, so `helm upgrade` fails. A new install can set it in `helm/values/langsmith-values-local.yaml` before its first `make init-values` and `make deploy`.

With SmithDB off, ClickHouse also serves the reads. Raise `clickhouse.statefulSet.resources` within what one LangSmith node can hold, or move to [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

## Product workloads

Fleet, LangSmith Chat and Insights each run an api-server and a queue Deployment. The chart gives these six Deployments no requests, so the module sets them:

- `fleet.apiServer.deployment.resources` and `fleet.queue.deployment.resources`, in the Fleet overlay
- `polly.apiServer.deployment.resources` and `polly.queue.deployment.resources`, in the Chat overlay
- `engineInsightsAgent.apiServer.deployment.resources` and `engineInsightsAgent.queue.deployment.resources`, which Insights and Engine share. `make init-values` writes them into `langsmith-values-overrides.yaml` on every run, and the Engine overlay repeats them. To change them, set `engineInsightsAgent` in `helm/values/langsmith-values-local.yaml`, which merges after both.

Each add-on keeps its data in its own database on the shared RDS instance and its own index on the shared ElastiCache.
