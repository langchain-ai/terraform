# Self-Hosted LangSmith — Production Readiness Checklist

This checklist is intended for **production self-hosted deployments** of LangSmith.  
If any item below is unmet, the deployment should be considered **at risk**.

---

## 1. Redis (Cache & Job Queues)

Redis is used for caching and job queues in the write path (Backend → Redis → Queue → ClickHouse). It buffers trace ingestion and manages queue processing, making it critical for handling write volume and preventing backpressure.

- [ ] Redis memory sized for expected write volume
- [ ] External Redis (e.g., AWS ElastiCache) used for production workloads with significant write volume
- [ ] Redis is not shared with unrelated services
- [ ] Memory usage, connection counts, and queue depths monitored
- [ ] Eviction and memory pressure metrics monitored

---

## 2. PostgreSQL (Metadata)

PostgreSQL stores LangSmith control-plane data (orgs, projects, users, API keys, config). It is **latency-sensitive** and **connection-bound**, not throughput-heavy. PostgreSQL outages commonly surface as authentication failures, project load errors, or global 500s—even when trace ingestion appears healthy.

### Architecture & Sizing
- [ ] Production uses a **managed or externally hosted PostgreSQL**
- [ ] Single-node embedded Postgres avoided for production (consider managed services for better reliability)
- [ ] Adequate IOPS and low-latency storage provisioned
- [ ] Automated backups enabled and tested

### Connections & Limits
- [ ] `max_connections` sized for expected backend and worker concurrency
- [ ] Connection pooling in place (e.g., PgBouncer or equivalent)
- [ ] Backend connection reuse verified (no per-request connections)
- [ ] Monitoring enabled for:
  - Active connections
  - Connection saturation
  - Slow queries

### Operational Readiness
- [ ] Disk usage monitored with alerting (>70%)
- [ ] Vacuum / autovacuum enabled and healthy
- [ ] Schema migrations tested in non-production before rollout
- [ ] Recovery procedure documented and rehearsed

---

## 3. ClickHouse (Traces & Analytics) (REQUIRED)

LangSmith uses ClickHouse as the primary storage engine for **traces** and **feedback**. ClickHouse stores run data fields and all feedback data fields, making it essential for production deployments. Proper ClickHouse architecture and configuration are critical for system stability and performance.

### Topology
- [ ] ClickHouse is deployed as a **replicated cluster**
- [ ] **Minimum 3 replicas** configured (baseline for production; single-node is not supported for production workloads)
- [ ] Total replicas ≤ 5 (guardrail: higher counts require careful coordination)
- [ ] Read and write concurrency can scale independently
- [ ] ClickHouse user permissions and row policies verified
- [ ] Migrations completed cleanly (no dirty schema state)

### Resource Sizing
- [ ] ≥ 8 vCPU / 32 GB RAM per node (baseline)
- [ ] SSD-backed persistent storage
- [ ] ~7000 IOPS and ~1000 MiB/s throughput
- [ ] Disk expansion supported (PVC allowVolumeExpansion where applicable)
- [ ] Disk usage monitored and alerting configured (>70%)
- [ ] Query concurrency and disk I/O metrics monitored (leading indicators, not just CPU/memory)

### Kubernetes Storage / EBS CSI (REQUIRED FOR CLICKHOUSE ON EKS)
- [ ] AWS EBS CSI Driver installed in the cluster
- [ ] Default StorageClass exists and provisions EBS volumes
- [ ] ClickHouse PVCs bind successfully and pods reach Ready state
- [ ] Volume expansion behavior understood / validated (if used)

> **Rationale**: ClickHouse persistence on EKS requires dynamic PersistentVolume provisioning via the AWS EBS CSI Driver. Without EBS CSI and a functional default EBS-backed StorageClass, ClickHouse PVCs cannot bind and pods will not start. This is a hard requirement for in-cluster ClickHouse deployments.

---

## 4. Blob Storage (REQUIRED FOR PRODUCTION)

**Blob storage (e.g., S3 or GCS) is REQUIRED for production deployments.** Blob storage stores large trace artifacts and payloads, reducing ClickHouse part counts, merge pressure, and read amplification. Without blob storage, large trace payloads stored inline in ClickHouse cause concurrency collapse, delayed trace visibility, and missing traces under load.

### Production Requirements
- [ ] Blob storage configured and enabled
- [ ] Blob storage connectivity validated from cluster
- [ ] Blob lifecycle policies aligned with ClickHouse TTL settings
- [ ] Object storage throughput and request limits verified

### Non-Production Guidance
Blob storage may be omitted **only** in dev/eval environments that are:
- Low-traffic (minimal trace volume)
- Short-lived (proof-of-concept or temporary)
- Not subject to production SLAs

For reference, the following heuristics indicate when blob storage becomes critical (but production should have it enabled regardless):
- More than ~10 active tenants
- Peak concurrent ClickHouse queries > 100 (or spikes > 200)
- P95 query latency > 2s for trace or run retrieval
- P95 ingestion delay (`received_at → inserted_at`) > 60s
- One or more tenants produce large or verbose traces


---

## 5. Autoscaling (HPA REQUIRED; KEDA OPTIONAL)

### Horizontal Pod Autoscaler (HPA) - Required
- [ ] HPA configured for LangSmith services (backend, workers, etc.)
- [ ] Resource requests/limits set to make HPA meaningful
- [ ] HPA metrics validated (CPU, memory, or custom metrics as appropriate)
- [ ] HPA scaling behavior tested under load

### KEDA (Optional / Advanced)
- [ ] If KEDA is used: triggers documented and understood
- [ ] Interaction with HPA validated (KEDA can work alongside HPA but requires careful configuration)
- [ ] Rollback plan exists if KEDA causes issues
- [ ] Team understands KEDA is optional (P1/advanced) and not part of P0 baseline

> **Rationale**: HPA is the Kubernetes-native autoscaling mechanism and is sufficient for the P0 reference architecture. KEDA adds complexity and is positioned as optional advanced autoscaling (P1). The baseline keeps to HPA for simplicity, supportability, and to avoid unnecessary operational overhead.

---

## 6. Scaling Mental Model (UNDERSTOOD)

> **For detailed explanation of read vs write paths, see [`README.md`](./README.md#65-read-vs-write-path-mental-model).**

- [ ] Team understands **write path**:
  - Backend → Redis → Queue → ClickHouse
- [ ] Team understands **read path**:
  - Backend → ClickHouse
- [ ] Scaling actions target the correct bottleneck (write path vs read path)
- [ ] Team validates ClickHouse capacity before scaling queue workers

> Scaling the wrong layer (e.g., adding workers without scaling ClickHouse) can worsen outages.

---

## 7. Networking & Proxies

- [ ] Frontend / ingress `maxBodySize` supports expected trace payload sizes
- [ ] Reverse proxy timeouts reviewed for large reads
- [ ] Network ACLs allow access to blob storage endpoints
- [ ] Internal service-to-service latency validated

---

## 8. Operational Safeguards

- [ ] Monitoring in place for:
  - Concurrent ClickHouse queries (leading indicator)
  - Query duration (P95 / P99)
  - Ingestion delay (received_at → inserted_at)
  - Disk usage and I/O (leading indicator)
  - Redis memory and queue depth
  - ClickHouse merge operations and part counts
- [ ] Alerts configured for sustained ingestion delay or query saturation
- [ ] Usage limits configured (or planned) for high-volume tenants

---

## 9. Optional Performance Levers (NOT FIXES)

- [ ] `CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT=0` evaluated as an optional ingest lever to reduce write latency
- [ ] Team understands this setting does not fix underlying ClickHouse saturation
- [ ] Timeouts reviewed but not used to mask slow queries

> These settings can improve behavior under load but **do not resolve underlying ClickHouse saturation**. If ClickHouse is saturated, these may mask symptoms temporarily but will not resolve root causes.

---

## 10. Diagnostics & Support Readiness

- [ ] Log collection procedures documented (Kubernetes / Docker)
- [ ] Ability to collect ClickHouse system tables (`system.query_log`, parts, merges)
- [ ] Browser HAR capture process documented for UI errors
- [ ] Backup and restore procedures tested (ClickHouse, Redis, Postgres)

---

## 11. Known Failure Mode Awareness

- [ ] Team understands that failures often present as:
  - "Traces created but not visible"
  - Large delays before traces appear
  - 500 errors during UI or API access
- [ ] Team recognizes these symptoms usually indicate **ingestion backpressure or ClickHouse saturation**, not missing data
- [ ] Team has a troubleshooting process for trace visibility issues:
  - Check ClickHouse query concurrency and disk I/O metrics
  - Review queue depth and worker processing rates
  - Examine ClickHouse merge operations and part counts
  - Monitor ingestion delay metrics (`received_at → inserted_at`)

---

## Final Sign-off

- [ ] Architecture reviewed against this checklist
- [ ] All REQUIRED items satisfied
- [ ] Production requirements (blob storage, EBS CSI, HPA) verified

> If multiple items above are unchecked, production incidents are more likely under moderate to high load. This checklist serves as guidance to help identify and address potential risks before they impact production.
