# LangSmith Self-Hosted on AWS — Troubleshooting Guide (P0)

**Purpose:** Fast triage for the P0 reference deployment.  
**Style:** Symptom → likely cause → exact checks → common fix.

This guide focuses on actionable, evidence-based troubleshooting. Every item maps to an observable signal and a deterministic check.

---

## 0. First Rule of Triage: Gather Evidence First

Before changing anything, capture essential diagnostic information. The easiest way to do this is using the provided diagnostic capture script.

### Quick Start: Automated Diagnostics Capture

Use the official LangSmith Kubernetes debugging script to automatically capture all required diagnostic information. This script is maintained in the [LangChain Helm repository](https://github.com/langchain-ai/helm).

**Download and run the script:**

```bash
# Download the script
curl -O https://raw.githubusercontent.com/langchain-ai/helm/main/charts/langsmith/scripts/get_k8s_debugging_info.sh
chmod +x get_k8s_debugging_info.sh

# Run it with your namespace
./get_k8s_debugging_info.sh --namespace langsmith
```

**What the script captures:**
- Summary of all Kubernetes resources (`kubectl get all`)
- Detailed YAML for all resources
- Kubernetes events (sorted by timestamp)
- Resource usage for all pods and containers
- Container logs for all pods (last 24 hours)
- Previous container logs for restarted containers
- All output compressed to a zip or tar.gz file

**Script details:**
- **Source:** [get_k8s_debugging_info.sh](https://github.com/langchain-ai/helm/blob/main/charts/langsmith/scripts/get_k8s_debugging_info.sh)
- **Output location:** `/tmp/langchain-debugging-<timestamp>/`
- **Output format:** Compressed archive (`.zip` preferred, falls back to `.tar.gz`)
- **Required argument:** `--namespace <namespace>`

The script creates a timestamped directory with all diagnostic information and compresses it into a single archive file, making it easy to share with support teams or analyze later.

### Manual Capture (Alternative)

If you prefer to capture diagnostics manually, ensure you collect:

- `kubectl get pods -n langsmith -o wide`
- `kubectl describe pod <POD> -n langsmith` (for each pod)
- `kubectl logs <POD> -n langsmith --tail=200` (for each pod)
- `kubectl get events -n langsmith --sort-by=.lastTimestamp | tail -50`
- Ingress/ALB status:
  - `kubectl get ingress -n langsmith` (or your ingress resource type)
  - `kubectl describe ingress <INGRESS> -n langsmith`
- If AWS-managed:
  - ALB target group health (healthy/unhealthy + reason)

Capturing this information ensures you address the actual root cause rather than symptoms, making troubleshooting more efficient and effective.

---

## 1. The Deployment “Works” But UI Is Not Reachable

### Symptom
- DNS resolves but browser times out
- Browser shows `502/503`
- ALB exists but shows no healthy targets

### Likely Causes
- Ingress misconfigured
- Service port mismatch
- Pod readiness failing (so targets never become healthy)
- Security group / NACL blocks

### Checks
- `kubectl get ingress -n langsmith -o yaml`
- `kubectl get svc -n langsmith`
- `kubectl describe svc <SERVICE> -n langsmith`
- `kubectl get endpoints -n langsmith`
- `kubectl get pods -n langsmith`
- Inspect readiness:
  - `kubectl describe pod <POD> -n langsmith | sed -n '/Readiness/,/Conditions/p'`

### Fixes (Common)
- Ensure ingress points to the correct service + port
- Ensure service selectors match pod labels
- Fix readiness probe failures before touching ALB
- Confirm ALB security group allows inbound 443 and node security group allows target traffic

---

## 2. Pods CrashLoopBackOff Immediately

### Symptom
- Pods oscillate between `CrashLoopBackOff` and `Running`
- Logs show immediate exit

### Likely Causes
- Missing or invalid secrets
- DB/Redis/ClickHouse connection failure
- Misconfigured required env vars

### Checks
- `kubectl logs <POD> -n langsmith --previous --tail=200`
- `kubectl describe pod <POD> -n langsmith` (look for env var injection and secret refs)
- Confirm secrets exist:
  - `kubectl get secret -n langsmith`
- Confirm external connectivity from inside cluster:
  - Launch a temporary debug pod and test TCP connectivity to DB hosts/ports

### Fixes (Common)
- Correct secret names/keys referenced in Helm values
- Verify DB hostnames and ports (RDS endpoints, Redis endpoints)
- Fix network policy / security groups if connections time out

---

## 3. Everything Is Running, But “First Successful Trace” Fails

### Symptom
- UI loads
- SDK calls fail (401/403/404) or traces never appear
- Client sees timeouts or 5xx

### Likely Causes
- Wrong endpoint (`LANGSMITH_ENDPOINT`) or wrong path
- Auth mismatch (token vs SSO)
- Ingestion path failing due to ClickHouse or Redis issues
- ALB health is fine but app errors on ingest

### Checks
- From client machine:
  - Confirm endpoint resolves and responds (TLS + HTTP status)
- In cluster logs:
  - Search logs of the API/ingestion service for auth or write errors
- Check ClickHouse health:
  - Look for write failures, memory pressure, disk pressure
- Check Redis:
  - Look for connection errors or queue backlog signals (if exposed)

### Fixes (Common)
- Ensure client is using the correct base URL and auth method
- Regenerate token / verify permissions
- Fix ClickHouse sizing or disk throughput issues if writes fail
- Fix Redis connectivity if queues are used for ingest

---

## 4. ALB Exists But Targets Are “Unhealthy”

### Symptom
- ALB target group shows all targets unhealthy
- UI returns `503` even though pods are running

### Likely Causes
- Readiness probe failing
- Target group health check path/port mismatch
- Service isn’t exposing the expected port
- Pods are running but not listening

### Checks
- `kubectl describe pod <POD> -n langsmith` (readiness probe results)
- `kubectl get svc -n langsmith -o yaml`
- Confirm the container port aligns with service targetPort
- Confirm health check path matches what the service actually serves

### Fixes (Common)
- Correct ingress annotations / health check settings
- Fix readiness probe configuration or dependencies causing readiness to fail
- Align service ports with actual container ports

---

## 5. DB Connectivity Failures (PostgreSQL)

### Symptom
- App logs show:
  - authentication failures
  - connection refused
  - timeout
  - “could not translate host name”
- App won’t start or fails on request

### Likely Causes
- Wrong credentials
- Security group blocks EKS to RDS
- RDS not in the right subnets or routing broken
- DNS/resolution issues inside cluster

### Checks
- Validate the RDS endpoint and port
- Confirm security groups allow inbound from EKS node group / pod CIDR (depending on setup)
- Test connectivity from a debug pod:
  - DNS resolution
  - TCP connect to `<rds-endpoint>:5432`

### Fixes (Common)
- Correct creds in secrets
- Fix SG rules
- Ensure private subnets have proper routing and NAT where required
- Ensure RDS is reachable from EKS VPC/subnets

---

## 6. Redis Connectivity Failures

### Symptom
- Logs show Redis connection errors/timeouts
- Background jobs stall (if used)
- Ingestion or async tasks fail

### Likely Causes
- Wrong endpoint/port
- Security group blocks EKS to ElastiCache
- Auth mismatch (if Redis auth enabled)

### Checks
- Confirm ElastiCache endpoint and port
- Test TCP connectivity from debug pod
- Check whether Redis auth is enabled and whether Helm values match

### Fixes (Common)
- Fix endpoint in values
- Fix security group rules
- Align auth config

---

## 7. ClickHouse Problems (Most Common Real Root Cause)

### 7.1 ClickHouse OOM / Memory Pressure

**Symptom**
- ClickHouse pod restarts
- OOMKilled events
- Trace writes fail or become slow

**Likely Cause**
- ClickHouse undersized (4/16 used for real workload)
- Memory limits too tight
- Query pressure

**Checks**
- `kubectl describe pod <clickhouse-pod> -n langsmith` (look for OOMKilled)
- `kubectl logs <clickhouse-pod> -n langsmith --tail=200`
- `kubectl top pod <clickhouse-pod> -n langsmith`

**Fixes**
- Move to **8 vCPU / 32GB RAM** baseline (see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md#3-clickhouse-traces--analytics-required) for production requirements)
- Increase memory limits/requests
- Reduce concurrent ingest/query load

---

### 7.2 ClickHouse Disk / IO Throughput Issues

**Symptom**
- Latency spikes
- Writes time out
- ClickHouse logs mention slow merges / IO waits

**Likely Cause**
- Slow storage class
- Inadequate IOPS/throughput
- Disk nearing capacity

**Checks**
- Confirm PV storage class and performance characteristics
- Check disk usage in ClickHouse pod
- Review ClickHouse logs for merge pressure / IO wait

**Fixes**
- Use SSD-backed storage with sufficient IOPS/throughput (see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md#3-clickhouse-traces--analytics-required) for storage requirements)
- Increase volume size
- Move ClickHouse to a dedicated node group / better instance type

---

### 7.3 ClickHouse Not Persistent (Data Loss Risk)

**Symptom**
- ClickHouse redeploy loses data
- Traces disappear after restart

**Likely Cause**
- No persistent volume attached
- StatefulSet misconfigured

**Checks**
- Confirm PVC exists and is bound:
  - `kubectl get pvc -n langsmith`
- Confirm ClickHouse uses that PVC

**Fixes**
- Attach PVC and ensure StatefulSet mounts it
- Do not treat ClickHouse as stateless

---

## 8. Kubernetes Scheduling Issues

### Symptom
- Pods stuck in `Pending`
- Events show “insufficient cpu/memory”
- ClickHouse never schedules

### Likely Causes
- Cluster too small
- Node group instance types too small
- Taints/affinity constraints prevent scheduling

### Checks
- `kubectl describe pod <POD> -n langsmith` (look at scheduling events)
- `kubectl get nodes -o wide`
- Check taints:
  - `kubectl describe node <NODE> | sed -n '/Taints/,/Conditions/p'`

### Fixes
- Increase node group size
- Use larger instance types
- Remove/adjust taints and affinities
- Ensure ClickHouse has a node that can fit **8/32 allocatable** (see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md#3-clickhouse-traces--analytics-required) for production requirements)

---

## 9. TLS / Certificate Issues

### Symptom
- Browser warnings
- Client SDK fails TLS handshake
- Mixed content or redirect loops

### Likely Causes
- Wrong ACM cert attached
- Wrong DNS name on cert
- HTTP/HTTPS mismatch

### Checks
- Confirm ALB listener is HTTPS
- Confirm cert CN/SAN includes your DNS name
- Confirm DNS record points to the correct ALB

### Fixes
- Attach correct cert
- Fix DNS record
- Enforce HTTPS redirects intentionally (not accidentally)

---

## 10. “It Worked Yesterday” Failures (The Dangerous Ones)

### Symptom
- Random 5xx
- Slow UI
- Traces intermittently missing

### Likely Causes
- Resource pressure (CPU throttling / memory pressure)
- ClickHouse disk pressure or merge backlog
- Redis saturation
- Node churn / autoscaling issues

### Checks
- `kubectl top pods -n langsmith`
- Pod restarts:
  - `kubectl get pods -n langsmith --sort-by=.status.containerStatuses[0].restartCount`
- Node events and scaling activity
- DB metrics (RDS CPU/connections; Redis CPU/memory; ClickHouse memory/disk)

### Fixes
- Add capacity (scale nodes)
- Increase ClickHouse resources or improve disk class
- Increase Redis tier if saturated
- Tune autoscaler limits (don’t let it starve the cluster)

---

## 11. What to Include in a Support Request (If You Must Escalate)

If you open a ticket, include:

- Reference path confirmation:
  - “Deployed via reference architecture + terraform + helm”
  - repo SHAs / chart versions
- Current cluster state:
  - `kubectl get pods -n langsmith -o wide`
  - relevant `describe` output
  - last 200 lines of logs from failing pods
- External dependencies:
  - Postgres type/version (RDS/Aurora, PG version)
  - Redis type/version
  - ClickHouse model (external vs in-cluster) + sizing (see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md) for production requirements)
- ALB target health status and error reason

Providing this information upfront enables faster resolution. If diagnostics are incomplete, the first step will be to collect the necessary diagnostic data.

---

## 12. Add to This Guide (How)

Only add entries that:
- Came from a real failure
- Include a deterministic check
- Include a fix that is repeatable