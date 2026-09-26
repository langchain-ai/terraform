# LangSmith Helm Sizing Profiles

Four sizing profiles for different deployment scenarios. Each profile has a corresponding values file in this directory, and that file holds the per-component replicas, requests, limits, and autoscaling settings.

| Profile | Use Case | Values File |
|---|---|---|
| **Minimum** | Cost parking, idle standby, CI smoke tests, single-user demos | [`langsmith-values-sizing-minimum.yaml`](langsmith-values-sizing-minimum.yaml) |
| **Dev** | Local dev, integration tests, demos, POCs, with a developer actually using the system | [`langsmith-values-sizing-dev.yaml`](langsmith-values-sizing-dev.yaml) |
| **Production** | Any environment serving real traffic, multi-replica with HPA/KEDA | [`langsmith-values-sizing-production.yaml`](langsmith-values-sizing-production.yaml) |
| **Production Large** | High-volume (~50 concurrent users, ~1,000 traces/sec), higher baselines | [`langsmith-values-sizing-production-large.yaml`](langsmith-values-sizing-production-large.yaml) |

Dev and production profiles use KEDA for `queue` and `ingestQueue` (queue target: 10), and HPA for other core services. Node autoscaling is configured separately.

`make init-values` preserves existing sizing files; merge template updates manually. When disabling an autoscaler, also set the component's fixed replica count.

### Product workloads (Insights, LangSmith Chat (formerly Polly), Fleet)

On chart 0.16 the standalone agents are ordinary Deployments, and everything about them is settable from Helm values. Each agent splits into an api-server and a queue:

- `polly.apiServer.deployment.resources` and `polly.queue.deployment.resources`
- `engineInsightsAgent.apiServer.deployment.resources` and `engineInsightsAgent.queue.deployment.resources`
- `fleet.apiServer.deployment.resources` and `fleet.queue.deployment.resources`

Each agent also gets its own Postgres and Redis. Left alone those are in-cluster StatefulSets sized by `<agent>.postgres.statefulSet.resources` and `<agent>.redis.statefulSet.resources` (`engineInsightsAgent.*` for Insights). Setting `<agent>.postgres.external.enabled` points the agent at a managed database instead, which is what the `langsmith-values-standalone-*.yaml` overlays do.

The sizing profiles do not override these six product-service Deployments. Their resources come from the Fleet, Chat, and Insights overlays, so they are the same in every profile.

This replaces the chart 0.15 arrangement, where `config.*.agent.resources` fed an agent-bootstrap Job that wrote database and redis sidecars at production-scale defaults which could then only be reduced through the LangSmith UI. Chart 0.16 removed that Job, so there is no longer anything to correct after the fact - and `config.agentBuilder.agent.resources` is no longer read at all.

---

## Quick Comparison

Totals from rendering chart 0.16.34 in `deploy.sh`'s values order, at minimum replica counts, with Postgres and Redis on RDS and ElastiCache. System pods are not included.

- **Core:** no add-ons, with in-cluster ClickHouse.
- **Full:** Deployments, Fleet, LangSmith Chat, and Insights, each product on external Postgres and Redis. The Insights overlay requires external ClickHouse, so this scope has no ClickHouse pod. Fleet itself needs host-backend, but not listener or operator. Choosing in-cluster storage for a product adds one Postgres and one Redis StatefulSet for it.

| Profile | Scope | Pods | CPU Reserved | Memory Reserved | CPU Limit | Memory Limit |
|---|---|---:|---:|---:|---:|---:|
| Minimum | Core | 8 | 1.3 vCPU | 3.9Gi | 4.8 vCPU | 8.0Gi |
| Minimum | Full | 18 | 8.3 vCPU | 18.3Gi | 21.8 vCPU | 40.6Gi |
| Dev | Core | 8 | 4.0 vCPU | 12.2Gi | 10.0 vCPU | 24.5Gi |
| Dev | Full | 18 | 10.8 vCPU | 22.3Gi | 26.0 vCPU | 48.5Gi |
| Production | Core | 16 | 13.7 vCPU | 32.0Gi | 28.0 vCPU | 70.0Gi |
| Production | Full | 28 | 22.7 vCPU | 45.0Gi | 48.5 vCPU | 101.0Gi |
| Prod Large | Core | 36 | 35.0 vCPU | 78.0Gi | 122.0 vCPU | 268.0Gi |
| Prod Large | Full | 52 | 43.5 vCPU | 87.0Gi | 152.0 vCPU | 312.0Gi |

Treat these as starting points: the [scale guide](https://docs.langchain.com/langsmith/self-host-scale) notes that optimal capacity depends on actual usage and trace payloads.
