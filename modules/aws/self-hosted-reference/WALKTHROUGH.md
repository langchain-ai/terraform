# LangSmith Self-Hosted on AWS — Deployment Walkthrough (P0)

**Goal:** Get from zero → running LangSmith Self-Hosted → first successful trace → basic health validation.  
**Prerequisite:** Complete the [`PREFLIGHT.md`](./PREFLIGHT.md) checklist before starting. This ensures your environment is ready and helps prevent common deployment issues.

This walkthrough provides a step-by-step path to deploy LangSmith Self-Hosted. Following it sequentially will help you avoid common pitfalls and ensure a successful deployment.

---

## 0. Decisions to Make Before Starting

Before you begin deploying with Terraform, decide on the following:

- **AWS Region:** `us-west-2` (example — pick one and stick to it)
- **Environment name:** `dev` / `staging` / `prod` (do not share resources across envs)
- **DNS name:** `langsmith.<your-domain>`
- **Exposure model:** Public (ALB) or Private-only (VPN/PrivateLink)
- **Auth model:** Token-based (P0) or OIDC/SSO (P1 unless already standard internally)
- **Data store model:**
  - Postgres: RDS/Aurora (recommended)
  - Redis: ElastiCache (recommended)
  - ClickHouse: Externally managed (preferred) or in-cluster (allowed)

**Tip:** Document these decisions in a `deploy/ENV.md` file so you can reference them throughout the deployment process.

---

## 1. Clone Repos and Pin Versions

To ensure a reproducible deployment, use specific versions of the Terraform and Helm repositories rather than always using the latest code.

- Clone the required repositories:
  - `https://github.com/langchain-ai/terraform`
  - `https://github.com/langchain-ai/helm`
- Record the specific versions you're using:
  - Terraform repo commit SHA
  - Helm repo commit SHA or chart version
- Avoid using floating/latest versions to ensure you can reproduce your deployment later.

> **Why this matters:** Using pinned versions ensures you can recreate your exact deployment configuration later, which is essential for troubleshooting, upgrades, and disaster recovery.

---

## 2. Terraform: Provision AWS Infrastructure

### 2.1 Configure Terraform State
- Use S3 backend + DynamoDB lock (recommended).
- Ensure state is **unique per environment**.

### 2.2 Apply Infrastructure
Provision (at minimum):
- VPC + subnets (public for ALB, private for nodes/data)
  - Use a VPC CIDR block of at least /16 to ensure sufficient IP addresses for all nodes and pods
- EKS cluster + managed node groups
- RDS Postgres (14+)
- ElastiCache Redis
- S3 bucket for artifacts
- Security groups and IAM roles/policies
- (Optional) Route53 hosted zone / record scaffolding

**Hard requirement:** Ensure the EKS node groups provide at least:
- **16 vCPU / 64GB RAM** allocatable capacity total
- **ClickHouse capacity** if deploying in-cluster:
  - **Production:** Capacity for 3 replicas, each with **8 vCPU / 32GB RAM** allocatable (single-node ClickHouse is not supported for production)
  - **Dev-only:** Single node with **8 vCPU / 32GB RAM** allocatable (non-production proof-of-concept only)

> **For detailed production capacity and resource requirements, including ClickHouse topology requirements, see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md#3-clickhouse-traces--analytics-required).**

### 2.3 Verify Infrastructure Before Proceeding

Before moving to the next step, verify that your infrastructure is correctly provisioned:
- [ ] `aws eks describe-cluster` shows `ACTIVE`
- [ ] Worker nodes in private subnets can reach the internet (NAT)
- [ ] RDS reachable from EKS subnets/security groups
- [ ] Redis reachable from EKS subnets/security groups
- [ ] S3 bucket exists and IAM access path is defined (IRSA preferred)

---

## 3. Kubernetes: Connect and Validate the Cluster

### 3.1 Connect to the Cluster
- Update kubeconfig:
  - `aws eks update-kubeconfig --region <REGION> --name <CLUSTER_NAME>`
- Confirm:
  - `kubectl get nodes`

### 3.2 Install/Validate Required Add-ons
You must have:
- Metrics Server
- Cluster Autoscaler

Verification:
- `kubectl top nodes` returns metrics
- Autoscaler is running and has permissions

### 3.3 Create a Namespace
Create a dedicated namespace, e.g.:
- `langsmith`

## 3.4 Validate Ingress Before Installing LangSmith

**Important:** Complete this validation **before** installing LangSmith with Helm. This step helps isolate any ingress configuration issues from application-level problems, making troubleshooting much easier if something goes wrong.

Many deployment issues that appear to be LangSmith problems are actually related to ingress, controller, or subnet-tagging configuration.

### 3.4.1 Deploy a Test Application

Deploy a minimal HTTP echo service (or any simple web service) into a test namespace (or the `langsmith` namespace). This will serve as a test target for your ingress.

Verify the test app is running:
- `kubectl get pods` shows the pod in `Running` state
- `kubectl get svc` shows the service has endpoints

### 3.4.2 Create a Test Ingress

Create an Ingress resource pointing at your test service. This will trigger the AWS Load Balancer Controller to provision an ALB.

Verify everything works:
- [ ] An **ALB** is created in AWS
- [ ] A target group is created and associated with the ALB
- [ ] Targets become **healthy** in the target group
- [ ] You can successfully access the endpoint over **HTTPS** and receive a response

### 3.4.3 Troubleshooting Ingress Issues

If the test ingress fails, **do not proceed** to installing LangSmith until this is resolved. Fixing ingress issues after LangSmith is installed makes troubleshooting more difficult.

If the ingress test fails, check these areas first:
- Kubernetes events on the Ingress resource: `kubectl describe ingress <ingress-name>`
- AWS Load Balancer Controller logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`
- ALB target group health status in the AWS console (look for specific error reasons)

> **Note:** This reference architecture requires AWS ALB for ingress. If you're using a different ingress controller, you'll need to adapt the configuration accordingly.

---

## 4. Prepare Dependencies and Secrets

### 4.1 Collect Required Connection Info
You need:
- Postgres host/port/db/user/password
- Redis host/port (and auth if enabled)
- ClickHouse endpoint/user/password (or in-cluster config)
- S3 bucket name and region

### 4.2 Store Secrets Securely

**Critical:** Never commit passwords, API keys, or other secrets to version control.

**Recommended approach:** Use AWS Secrets Manager with External Secrets Operator to automatically sync secrets into Kubernetes.

**Minimum requirement:** 
- Keep all secrets out of your git repository
- Use a secrets management solution (AWS Secrets Manager, HashiCorp Vault, etc.)
- Inject secrets into Kubernetes securely using External Secrets, CSI driver, or secure environment variable injection

> **Security reminder:** If secrets end up in your git history, they can be exposed. Always use a proper secrets management solution.

---

## 5. Helm: Install LangSmith

### 5.1 Choose the Values Strategy
You should have:
- `values.yaml` (non-secret config)
- `secrets.yaml` OR external secrets (secret values only, not committed)

### 5.2 Configure Required Values
Your Helm values must define:
- External Postgres connection
- External Redis connection
- ClickHouse configuration (external or in-cluster)
- S3 artifact storage (strongly recommended)
- Ingress configuration (ALB + TLS)

> **For production requirements for each component, see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md).**

### 5.3 Install/Upgrade
- Install the chart into the `langsmith` namespace.
- Use `helm upgrade --install` (idempotent).

### 5.4 Verify Helm Installation

After installing LangSmith, verify that everything is running correctly:
- [ ] All pods in `langsmith` namespace reach `Running` or expected steady state
- [ ] No CrashLoopBackOff
- [ ] Services have endpoints
- [ ] Ingress is created and gets an ALB hostname/address

**Verification commands:**
- `kubectl get pods -n langsmith` - Check all pods are running
- `kubectl describe pod <pod-name> -n langsmith` - Inspect any pods that aren't running
- `kubectl get svc -n langsmith` - Verify services are created
- `kubectl get ingress -n langsmith` - Confirm ingress resource exists and has an ALB address

---

## 6. Ingress + DNS: Make It Reachable

### 6.1 TLS
- Ensure the ALB listener is HTTPS
- Ensure cert is valid (ACM recommended)

### 6.2 DNS
- Create a Route53 record:
  - `langsmith.<domain>` → ALB DNS name

### 6.3 Verify Reachability
- [ ] You can load the LangSmith UI at `https://langsmith.<domain>`
- [ ] Auth behaves as intended (token login or SSO)

---

## 7. Send Your First Trace

A deployment isn't complete until you can successfully send and view traces. This step validates that the entire ingestion pipeline is working correctly.

### 7.1 Create an API Key / Token (if applicable)
- Create the token per your configured auth model.
- Store it securely.

### 7.2 Send a Minimal Trace
From a laptop or CI runner with egress to the endpoint:
- Configure `LANGSMITH_ENDPOINT`
- Configure auth (`LANGSMITH_API_KEY` or equivalent)
- Run a minimal trace-producing script (LangChain example or direct API).

### 7.3 Verify Trace Ingestion

Check that your trace was successfully ingested:
- [ ] The trace appears in the LangSmith UI
- [ ] The trace includes at least one run/span with data
- [ ] No ingestion errors appear in the application logs

**If traces don't appear:** Don't proceed to operational tasks yet. Fix the ingestion pipeline first. Common issues include:
- ClickHouse connectivity problems
- Redis queue issues
- Authentication/authorization errors
- Network connectivity between services

See [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) for detailed troubleshooting steps.

---

## 8. Basic Health Validation (P0 Ops Readiness)

### 8.1 What “Healthy” Means (Minimum)
- UI loads reliably
- API responds
- DB connections stable
- No sustained error logs
- ClickHouse writes succeed
- Redis queues not stuck

### 8.2 Validate Logs
Check:
- LangSmith app logs for errors
- ClickHouse logs for disk/memory pressure
- Ingress/ALB logs (4xx/5xx spikes)

### 8.3 Validate Resource Pressure
- `kubectl top pods -n langsmith`
- Look for:
  - OOMKills
  - CPU throttling
  - Persistent volume saturation

---

## 9. Backup & Restore Planning

Before considering your deployment production-ready, ensure you have a backup and restore strategy:

- **RDS backups:** Confirm automated backups are enabled and test that you can restore from them
- **ClickHouse persistence:** Verify your ClickHouse data is stored on persistent volumes and understand how to restore it
- **S3 bucket lifecycle:** Confirm your S3 bucket has appropriate lifecycle policies and versioning configured

**Important:** You don't need to perform a full restore test immediately, but you should document the restore procedure and understand how long it would take to recover from a failure.

---

## 10. Common Failure Points (Fast Triage)

If deployment fails, the usual culprits are:

1. **Networking / Security Groups**
   - EKS can’t reach Postgres/Redis/ClickHouse
2. **ClickHouse undersized or slow disk**
   - OOM, high latency, ingestion failures
3. **Ingress misconfiguration**
   - ALB created but no healthy targets
4. **Auth mismatch**
   - UI loads but API calls fail
5. **Secrets handling**
   - Bad credentials injected, pods loop

When something breaks: capture
- `kubectl describe`
- pod logs
- DB connection test results
- ALB target health

This data becomes your failure-mode catalog later.

---

## 11. Deployment Complete Checklist

Your deployment is complete when all of the following are true:

- [ ] Terraform applied cleanly and is reproducible
- [ ] Helm install is idempotent (`upgrade --install` works)
- [ ] UI reachable via HTTPS on your chosen DNS
- [ ] First successful trace appears in the UI
- [ ] Basic health checks are green (no crash loops, stable DB connectivity)

If any item isn't checked, continue working through the walkthrough or consult [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) to resolve the issue.

---

## Appendix: Notes for Your First Deployment

As you go through this walkthrough for the first time, consider keeping notes on:
- Steps where you needed to pause and look up additional information
- Decisions you had to make that weren't clearly documented
- Any issues you encountered and how you resolved them
- Configuration choices you made and why

These notes will be valuable for:
- Troubleshooting future issues
- Onboarding other team members
- Planning upgrades or changes
- Understanding your specific deployment configuration
