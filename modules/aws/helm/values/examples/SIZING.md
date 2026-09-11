# LangSmith Helm Sizing Profiles

Four sizing profiles for different deployment scenarios. Each profile has a corresponding values file in this directory.

| Profile | Use Case | Values File |
|---|---|---|
| **Minimum** | Cost parking, idle standby, CI smoke tests, single-user demos | `langsmith-values-sizing-minimum.yaml` |
| **Dev** | Local dev, integration tests, demos, POCs — a developer actually using the system | `langsmith-values-sizing-dev.yaml` |
| **Production** | Any environment serving real traffic, multi-replica with HPA | `langsmith-values-sizing-production.yaml` |
| **Production Large** | High-volume (~50 concurrent users, ~1,000 traces/sec), elevated baselines | `langsmith-values-sizing-production-large.yaml` |

### Product workloads (Insights, LangSmith Chat (formerly Polly), Fleet)

On chart 0.16 the standalone agents are ordinary Deployments, and everything about them is settable from Helm values. Each agent splits into an api-server and a queue:

- `polly.apiServer.deployment.resources` and `polly.queue.deployment.resources`
- `engineInsightsAgent.apiServer.deployment.resources` and `engineInsightsAgent.queue.deployment.resources`
- `fleet.apiServer.deployment.resources` and `fleet.queue.deployment.resources`

Each agent also gets its own Postgres and Redis. Left alone those are in-cluster StatefulSets sized by `<agent>.postgres.statefulSet.resources` and `<agent>.redis.statefulSet.resources` (`engineInsightsAgent.*` for Insights). Setting `<agent>.postgres.external.enabled` points the agent at a managed database instead, which is what the `langsmith-values-standalone-*.yaml` overlays do.

The sizing profiles do not override these six product-service Deployments. Their
resources come from the Fleet, Chat, and Insights overlays and therefore stay the
same in every table below. Totals use all three products with external Postgres,
Redis, and ClickHouse, as rendered by chart 0.16.6. Treat them as starting points:
the [scale guide](https://docs.langchain.com/langsmith/self-host-scale) notes that
optimal capacity depends on actual usage and trace payloads.

This replaces the chart 0.15 arrangement, where `config.*.agent.resources` fed an agent-bootstrap Job that wrote database and redis sidecars at production-scale defaults which could then only be reduced through the LangSmith UI. Chart 0.16 removed that Job, so there is no longer anything to correct after the fact - and `config.agentBuilder.agent.resources` is no longer read at all.

---

## Minimum

Absolute floor for the core LangSmith services. The core-only profile can fit on
a small node, but enabling Fleet, Chat, and Insights raises the rendered minimum
to 8.31 vCPU and 18.3Gi of requested memory before in-cluster databases. It will
break under meaningful traffic.

Host-backend remains HPA-managed but is capped at one replica; Fleet API retains
its add-on HPA range of one to five replicas.

| Component | Minimum Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|---:|
| **Application** | | | | | |
| backend | 1 | 50m | 500m | 576Mi | 1,024Mi |
| frontend | 1 | 10m | 250m | 32Mi | 256Mi |
| platformBackend | 1 | 25m | 250m | 64Mi | 256Mi |
| playground | 1 | 25m | 250m | 384Mi | 512Mi |
| queue | 1 | 100m | 1,000m | 768Mi | 1,536Mi |
| ingestQueue | 1 | 25m | 250m | 64Mi | 256Mi |
| aceBackend | 1 | 25m | 250m | 64Mi | 256Mi |
| **Deployments Feature** | | | | | |
| hostBackend | 1 | 100m | 500m | 384Mi | 768Mi |
| listener | 1 | 250m | 1,000m | 768Mi | 1,536Mi |
| operator | 1 | 100m | 250m | 256Mi | 512Mi |
| **Fleet infrastructure** | | | | | |
| fleetToolServer | 1 | 500m | 1,000m | 768Mi | 1,536Mi |
| fleetTriggerServer | 1 | 100m | 250m | 256Mi | 384Mi |
| **Product services (external Postgres/Redis)** | | | | | |
| Fleet api-server | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| Fleet queue | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| LangSmith Chat api-server | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| LangSmith Chat queue | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| Insights api-server | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| Insights queue | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| **Shared data services (when in-cluster)** | | | | | |
| postgres | 1 | 200m | 500m | 512Mi | 1,024Mi |
| redis | 1 | 100m | 200m | 64Mi | 128Mi |
| clickhouse | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App + full Deployments + Fleet infrastructure (12 pods) | 1,310m | 5,750m | 4,384Mi (4.3Gi) | 8,832Mi (8.6Gi) |
| Product services (6 pods) | 7,000m | 16,000m | 14,336Mi (14.0Gi) | 32,768Mi (32.0Gi) |
| Data Services (3 pods) | 1,300m | 2,700m | 2,624Mi (2.6Gi) | 5,248Mi (5.1Gi) |
| **Full Deployments + Fleet + all product services (18 pods, external storage)** | **8,310m** | **21,750m** | **18,720Mi (18.3Gi)** | **41,600Mi (40.6Gi)** |

---

## Dev

Enough headroom for a developer to run traces, test agents, and use the playground
without constant OOM kills. Core components start at one replica; host-backend and
Fleet API retain their add-on HPAs (minimum 1, maximum 5).

| Component | Minimum Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|---:|
| **Application** | | | | | |
| backend | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| frontend | 1 | 100m | 500m | 256Mi | 512Mi |
| platformBackend | 1 | 250m | 1,000m | 512Mi | 1,024Mi |
| playground | 1 | 250m | 1,000m | 512Mi | 1,024Mi |
| queue | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| ingestQueue | 1 | 250m | 1,000m | 512Mi | 1,024Mi |
| aceBackend | 1 | 200m | 500m | 512Mi | 1,024Mi |
| **Deployments Feature** | | | | | |
| hostBackend | 1 | 250m | 1,000m | 1,024Mi | 2,048Mi |
| listener | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| operator | 1 | 250m | 500m | 512Mi | 1,024Mi |
| **Fleet infrastructure** | | | | | |
| fleetToolServer | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| fleetTriggerServer | 1 | 250m | 500m | 512Mi | 1,024Mi |
| **Product services (external Postgres/Redis)** | | | | | |
| Fleet api-server | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| Fleet queue | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| LangSmith Chat api-server | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| LangSmith Chat queue | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| Insights api-server | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| Insights queue | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| **Shared data services (when in-cluster)** | | | | | |
| postgres | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| redis | 1 | 200m | 500m | 256Mi | 512Mi |
| clickhouse | 1 | 2,000m | 4,000m | 8,192Mi | 16,384Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App + full Deployments + Fleet infrastructure (12 pods) | 3,800m | 10,000m | 8,448Mi (8.3Gi) | 16,896Mi (16.5Gi) |
| Product services (6 pods) | 7,000m | 16,000m | 14,336Mi (14.0Gi) | 32,768Mi (32.0Gi) |
| Data Services (3 pods) | 2,700m | 5,500m | 9,472Mi (9.3Gi) | 18,944Mi (18.5Gi) |
| **Full Deployments + Fleet + all product services (18 pods, external storage)** | **10,800m** | **26,000m** | **22,784Mi (22.3Gi)** | **49,664Mi (48.5Gi)** |

---

## Production

Multi-replica with HPA autoscaling. Recommended for any environment serving real traffic.

Profile-defined HPAs target **50% CPU** and **80% memory** utilization. Fleet API
keeps the add-on overlay's **70% CPU** target.

| Component | Min Replicas | Max Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|---:|---:|
| **Application** | | | | | | |
| backend | 3 | 10 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| frontend | 2 | 10 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| platformBackend | 2 | 10 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| playground | 1 | 5 | 500m | 1,000m | 1,024Mi | 8,192Mi |
| queue | 3 | 10 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| ingestQueue | 3 | 10 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| aceBackend | 1 | 5 | 200m | 1,000m | 1,024Mi | 2,048Mi |
| **Deployments Feature** | | | | | | |
| hostBackend | 2 | 10 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| listener | 2 | 10 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| operator | 1 | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| **Fleet infrastructure** | | | | | | |
| fleetToolServer | 1 | 1 | 1,000m | 2,500m | 1,024Mi | 3,072Mi |
| fleetTriggerServer | 1 | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| **Product services (external Postgres/Redis)** | | | | | | |
| Fleet api-server | 1 | 5 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| Fleet queue | 1 | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| LangSmith Chat api-server | 1 | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| LangSmith Chat queue | 1 | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| Insights api-server | 1 | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| Insights queue | 1 | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| **Shared data services (when in-cluster)** | | | | | | |
| clickhouse | 1 | 1 | 2,000m | 4,000m | 8,192Mi | 16,384Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App (7 components, 15 pods) | 11,700m | 24,000m | 24,576Mi (24.0Gi) | 55,296Mi (54.0Gi) |
| Feature (3 components, 5 pods) | 2,500m | 5,000m | 5,120Mi (5.0Gi) | 10,240Mi (10.0Gi) |
| Fleet infrastructure (2 components, 2 pods) | 1,500m | 3,500m | 2,048Mi (2.0Gi) | 5,120Mi (5.0Gi) |
| Product services (6 pods) | 7,000m | 16,000m | 14,336Mi (14.0Gi) | 32,768Mi (32.0Gi) |
| Data Services (1 pod) | 2,000m | 4,000m | 8,192Mi (8.0Gi) | 16,384Mi (16.0Gi) |
| **Full Deployments + Fleet + all product services (28 pods, external storage)** | **22,700m** | **48,500m** | **46,080Mi (45.0Gi)** | **103,424Mi (101.0Gi)** |

---

## Production Large

High-volume deployments with elevated baselines. Based on the High/High pattern from the [LangSmith scale guide](https://docs.langchain.com/langsmith/self-host-scale): ~50 concurrent users, ~1,000 traces/sec.

Profile-defined HPAs target **50% CPU** and **80% memory** utilization. Fleet API
keeps the add-on overlay's **70% CPU** target.

| Component | Min Replicas | Max Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|---:|---:|
| **Application** | | | | | | |
| backend | 10 | 50 | 1,000m | 4,000m | 2,048Mi | 8,192Mi |
| frontend | 4 | 10 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| platformBackend | 5 | 20 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| playground | 2 | 10 | 500m | 2,000m | 1,024Mi | 8,192Mi |
| queue | 6 | 24 | 1,000m | 4,000m | 2,048Mi | 8,192Mi |
| ingestQueue | 6 | 24 | 1,000m | 4,000m | 2,048Mi | 8,192Mi |
| aceBackend | 2 | 10 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| **Deployments Feature** | | | | | | |
| hostBackend | 4 | 10 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| listener | 4 | 10 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| operator | 1 | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| **Fleet infrastructure** | | | | | | |
| fleetToolServer | 1 | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| fleetTriggerServer | 1 | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| **Product services (external Postgres/Redis)** | | | | | | |
| Fleet api-server | 1 | 5 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| Fleet queue | 1 | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| LangSmith Chat api-server | 1 | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| LangSmith Chat queue | 1 | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| Insights api-server | 1 | 1 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| Insights queue | 1 | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |
| **Shared data services (when in-cluster)** | | | | | | |
| clickhouse | 1 | 1 | 4,000m | 8,000m | 16,384Mi | 32,768Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App (7 components, 35 pods) | 31,000m | 114,000m | 63,488Mi (62.0Gi) | 241,664Mi (236.0Gi) |
| Feature (3 components, 9 pods) | 4,500m | 18,000m | 9,216Mi (9.0Gi) | 36,864Mi (36.0Gi) |
| Fleet infrastructure (2 components, 2 pods) | 1,000m | 4,000m | 2,048Mi (2.0Gi) | 8,192Mi (8.0Gi) |
| Product services (6 pods) | 7,000m | 16,000m | 14,336Mi (14.0Gi) | 32,768Mi (32.0Gi) |
| Data Services (1 pod) | 4,000m | 8,000m | 16,384Mi (16.0Gi) | 32,768Mi (32.0Gi) |
| **Full Deployments + Fleet + all product services (52 pods, external storage)** | **43,500m** | **152,000m** | **89,088Mi (87.0Gi)** | **319,488Mi (312.0Gi)** |

---

## Quick Comparison

The comparison uses minimum replica counts, full Deployments, and external
storage. Fleet itself needs host-backend, but not listener or operator. Choosing
in-cluster Fleet, LangSmith Chat, or Insights storage adds one Postgres and one
Redis StatefulSet per product.

| Profile | Pods | CPU Reserved | Memory Reserved | CPU Limit | Memory Limit |
|---|---:|---:|---:|---:|---:|
| Minimum | 18 | 8.3 vCPU | 18.3Gi | 21.8 vCPU | 40.6Gi |
| Dev | 18 | 10.8 vCPU | 22.3Gi | 26.0 vCPU | 48.5Gi |
| Production | 28 | 22.7 vCPU | 45.0Gi | 48.5 vCPU | 101.0Gi |
| Prod Large | 52 | 43.5 vCPU | 87.0Gi | 152.0 vCPU | 312.0Gi |
