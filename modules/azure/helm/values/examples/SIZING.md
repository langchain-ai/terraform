# LangSmith Helm Sizing Profiles

Four sizing profiles for different deployment scenarios. Each profile has a corresponding values file in this directory, and that file holds the per-component replicas, requests, limits, and HPA ranges.

| Profile | Use Case | Values File |
|---|---|---|
| **Minimum** | Cost parking, idle standby, CI smoke tests, single-user demos | [`langsmith-values-sizing-minimum.yaml`](langsmith-values-sizing-minimum.yaml) |
| **Dev** | Local dev, integration tests, demos, POCs, with a developer actually using the system | [`langsmith-values-sizing-dev.yaml`](langsmith-values-sizing-dev.yaml) |
| **Production** | Any environment serving real traffic, multi-replica with HPA | [`langsmith-values-sizing-production.yaml`](langsmith-values-sizing-production.yaml) |
| **Production Large** | High-volume (~50 concurrent users, ~1,000 traces/sec), higher baselines | [`langsmith-values-sizing-production-large.yaml`](langsmith-values-sizing-production-large.yaml) |

### Agent workloads (Insights, Polly, Fleet)

On chart 0.16 the standalone agents are ordinary Deployments, and everything about them is settable from Helm values. Each agent splits into an api-server and a queue:

- `polly.apiServer.deployment.resources` and `polly.queue.deployment.resources`
- `engineInsightsAgent.apiServer.deployment.resources` and `engineInsightsAgent.queue.deployment.resources`
- `fleet.apiServer.deployment.resources` and `fleet.queue.deployment.resources`

Each agent also gets its own Postgres and Redis. Left alone those are in-cluster StatefulSets sized by `<agent>.postgres.statefulSet.resources` and `<agent>.redis.statefulSet.resources` (`engineInsightsAgent.*` for Insights). Setting `<agent>.postgres.external.enabled` points the agent at a managed database instead, which is what the `langsmith-values-standalone-*.yaml` overlays do.

This replaces the chart 0.15 arrangement, where `config.*.agent.resources` fed an agent-bootstrap Job that wrote database and redis sidecars at production-scale defaults which could then only be reduced through the LangSmith UI. Chart 0.16 removed that Job, so there is no longer anything to correct after the fact - and `config.agentBuilder.agent.resources` is no longer read at all.

---

## Quick Comparison

Totals from rendering chart 0.16.34 with each profile, at minimum replica counts. Postgres and Redis are managed services (the default), and ClickHouse runs in-cluster. System pods are not included.

| Profile | Scope | Pods | CPU Reserved | Memory Reserved | CPU Limit | Memory Limit |
|---|---|---:|---:|---:|---:|---:|
| Minimum | Core | 8 | 1.6 vCPU | 3.9Gi | 5.5 vCPU | 8.0Gi |
| Minimum | + Deployments and Fleet | 16 | 3.2 vCPU | 7.3Gi | 11.5 vCPU | 17.4Gi |
| Dev | Core | 8 | 4.0 vCPU | 12.2Gi | 10.0 vCPU | 24.5Gi |
| Dev | + Deployments and Fleet | 16 | 5.8 vCPU | 15.8Gi | 14.0 vCPU | 31.5Gi |
| Production | Core | 16 | 13.7 vCPU | 32.0Gi | 28.0 vCPU | 70.0Gi |
| Production | + Deployments and Fleet | 26 | 17.2 vCPU | 39.0Gi | 35.0 vCPU | 84.0Gi |
| Prod Large | Core | 36 | 35.0 vCPU | 78.0Gi | 122.0 vCPU | 268.0Gi |
| Prod Large | + Deployments and Fleet | 50 | 40.5 vCPU | 89.0Gi | 144.0 vCPU | 312.0Gi |

Fleet's Redis sets no resources in any profile, and its api-server and queue set none outside Minimum. Those containers get the namespace LimitRange default, which these totals leave out.
