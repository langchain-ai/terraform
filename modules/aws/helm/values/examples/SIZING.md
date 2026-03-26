# LangSmith Helm Sizing Profiles

Four sizing profiles for different deployment scenarios. Each profile has a corresponding values file in this directory.

| Profile | Use Case | Values File |
|---|---|---|
| **Minimum** | Cost parking, idle standby, CI smoke tests, single-user demos | `langsmith-values-sizing-minimum.yaml` |
| **Dev** | Local dev, integration tests, demos, POCs — a developer actually using the system | `langsmith-values-sizing-dev.yaml` |
| **Production** | Any environment serving real traffic, multi-replica with HPA | `langsmith-values-sizing-production.yaml` |
| **Production Large** | High-volume (~50 concurrent users, ~1,000 traces/sec), elevated baselines | `langsmith-values-sizing-production-large.yaml` |

### Operator-managed pods (LGP resources)

The sizing values files control Helm-deployed components and `config.*.agent.resources` for operator-managed agent server/queue pods. Database and redis sidecar resources are written by the bootstrap job at production-scale defaults and **cannot be controlled via Helm values**.

To right-size database/redis sidecars after deploy, update via the **LangSmith UI**:

1. Log into LangSmith as an org admin
2. Navigate to each bundled agent deployment (agent-builder, clio, smith-polly)
3. Update the resource spec (db, redis) to match your sizing profile
4. This creates a new revision — the operator reconciles the lower resources automatically

---

## Minimum

Absolute floor. Keeps LangSmith alive at the lowest possible cost. Fits on a single small node (e.g. m5.xlarge — 4 vCPU, 16Gi). Will break under any meaningful traffic.

| Component | Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
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
| **Agent Builder** | | | | | |
| agentBuilderToolServer | 1 | 500m | 1,000m | 768Mi | 1,536Mi |
| agentBuilderTriggerServer | 1 | 100m | 250m | 256Mi | 384Mi |
| **Operator-Managed Agents** | | | | | |
| polly agent | 1 | 100m | 500m | 256Mi | 512Mi |
| insights agent | 1 | 100m | 500m | 256Mi | 512Mi |
| agentBuilder agent | 1 | 100m | 500m | 256Mi | 512Mi |
| **Data Services (Tier 1 only)** | | | | | |
| postgres | 1 | 200m | 500m | 512Mi | 1,024Mi |
| redis | 1 | 100m | 200m | 64Mi | 128Mi |
| clickhouse | 1 | 1,000m | 2,000m | 2,048Mi | 4,096Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App + Feature + Agent Builder (12 pods) | 1,310m | 5,500m | 4,384Mi (4.3Gi) | 8,832Mi (8.6Gi) |
| Operator-Managed Agents (3 pods) | 300m | 1,500m | 768Mi (0.8Gi) | 1,536Mi (1.5Gi) |
| Data Services (3 pods) | 1,300m | 2,700m | 2,624Mi (2.6Gi) | 5,248Mi (5.1Gi) |
| **All components (18 pods)** | **2,910m** | **9,700m** | **7,776Mi (7.6Gi)** | **15,616Mi (15.3Gi)** |

---

## Dev

Enough headroom for a developer to run traces, test agents, and use the playground without constant OOM kills. Single replica, no autoscaling.

| Component | Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
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
| hostBackend | 1 | 250m | 1,000m | 512Mi | 1,024Mi |
| listener | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| operator | 1 | 250m | 500m | 512Mi | 1,024Mi |
| **Agent Builder** | | | | | |
| agentBuilderToolServer | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| agentBuilderTriggerServer | 1 | 250m | 500m | 512Mi | 1,024Mi |
| **Operator-Managed Agents** | | | | | |
| polly agent | 1 | 250m | 500m | 512Mi | 1,024Mi |
| insights agent | 1 | 250m | 500m | 512Mi | 1,024Mi |
| agentBuilder agent | 1 | 250m | 500m | 512Mi | 1,024Mi |
| **Data Services (Tier 1 only)** | | | | | |
| postgres | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| redis | 1 | 200m | 500m | 256Mi | 512Mi |
| clickhouse | 1 | 2,000m | 4,000m | 8,192Mi | 16,384Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App + Feature + Agent Builder (12 pods) | 3,800m | 10,000m | 7,936Mi (7.8Gi) | 15,872Mi (15.5Gi) |
| Operator-Managed Agents (3 pods) | 750m | 1,500m | 1,536Mi (1.5Gi) | 3,072Mi (3.0Gi) |
| Data Services (3 pods) | 2,700m | 5,500m | 9,472Mi (9.3Gi) | 18,944Mi (18.5Gi) |
| **All components (18 pods)** | **7,250m** | **17,000m** | **18,944Mi (18.5Gi)** | **37,888Mi (37.0Gi)** |

---

## Production

Multi-replica with HPA autoscaling. Recommended for any environment serving real traffic.

All autoscaled components target **50% CPU** and **80% memory** utilization.

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
| **Agent Builder** | | | | | | |
| agentBuilderToolServer | 1 | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| agentBuilderTriggerServer | 1 | 1 | 500m | 1,000m | 1,024Mi | 2,048Mi |
| **Operator-Managed Agents (chart defaults)** | | | | | | |
| polly agent | 1 | 5 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| insights agent | 1 | 5 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| agentBuilder agent | 1 | 5 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| **Data Services (Tier 1 only)** | | | | | | |
| clickhouse | 1 | 1 | 2,000m | 4,000m | 8,192Mi | 16,384Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App (7 components, 15 pods) | 11,200m | 26,000m | 23,552Mi (23.0Gi) | 60,416Mi (59.0Gi) |
| Feature (3 components, 5 pods) | 1,500m | 3,000m | 3,072Mi (3.0Gi) | 6,144Mi (6.0Gi) |
| Agent Builder (2 components, 2 pods) | 1,000m | 2,000m | 2,048Mi (2.0Gi) | 4,096Mi (4.0Gi) |
| Operator-Managed Agents (3 pods) | 6,000m | 12,000m | 12,288Mi (12.0Gi) | 24,576Mi (24.0Gi) |
| Data Services (1 pod) | 2,000m | 4,000m | 8,192Mi (8.0Gi) | 16,384Mi (16.0Gi) |
| **All components (26 pods)** | **21,700m** | **47,000m** | **49,152Mi (48.0Gi)** | **111,616Mi (109.0Gi)** |

> Operator-managed agent resources use chart defaults (2 CPU / 4Gi each) — this profile does not override them.

---

## Production Large

High-volume deployments with elevated baselines. Based on the High/High pattern from the [LangSmith scale guide](https://docs.langchain.com/langsmith/self-host-scale): ~50 concurrent users, ~1,000 traces/sec.

All autoscaled components target **50% CPU** and **80% memory** utilization.

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
| **Agent Builder** | | | | | | |
| agentBuilderToolServer | 1 | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| agentBuilderTriggerServer | 1 | 1 | 500m | 2,000m | 1,024Mi | 4,096Mi |
| **Operator-Managed Agents (chart defaults)** | | | | | | |
| polly agent | 1 | 5 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| insights agent | 1 | 5 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| agentBuilder agent | 1 | 5 | 2,000m | 4,000m | 4,096Mi | 8,192Mi |
| **Data Services (Tier 1 only)** | | | | | | |
| clickhouse | 1 | 1 | 4,000m | 8,000m | 16,384Mi | 32,768Mi |

| | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|
| App (7 components, 35 pods) | 27,000m | 114,000m | 55,296Mi (54.0Gi) | 253,952Mi (248.0Gi) |
| Feature (3 components, 9 pods) | 4,500m | 18,000m | 9,216Mi (9.0Gi) | 36,864Mi (36.0Gi) |
| Agent Builder (2 components, 2 pods) | 1,000m | 4,000m | 2,048Mi (2.0Gi) | 8,192Mi (8.0Gi) |
| Operator-Managed Agents (3 pods) | 6,000m | 12,000m | 12,288Mi (12.0Gi) | 24,576Mi (24.0Gi) |
| Data Services (1 pod) | 4,000m | 8,000m | 16,384Mi (16.0Gi) | 32,768Mi (32.0Gi) |
| **All components (50 pods)** | **42,500m** | **156,000m** | **95,232Mi (93.0Gi)** | **356,352Mi (348.0Gi)** |

> Operator-managed agent resources use chart defaults (2 CPU / 4Gi each).

---

## Quick Comparison

All values at minimum replica counts, all components including data services.

| Profile | Pods | CPU Reserved | Memory Reserved | CPU Limit | Memory Limit |
|---|---:|---:|---:|---:|---:|
| Minimum | 18 | 2.9 vCPU | 7.6Gi | 9.7 vCPU | 15.3Gi |
| Dev | 18 | 7.3 vCPU | 18.5Gi | 17.0 vCPU | 37.0Gi |
| Production | 26 | 21.7 vCPU | 48.0Gi | 47.0 vCPU | 109.0Gi |
| Prod Large | 50 | 42.5 vCPU | 93.0Gi | 156.0 vCPU | 348.0Gi |
