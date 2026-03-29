# LangSmith on AWS — SA Deployment Writeup

> **Audience:** SA team internal. Use this as prep for customer conversations, architecture reviews, or handoff docs. This is the e2e story of how we build a LangSmith cluster on AWS — module by module, dependency by dependency, decision by decision.

---

## The Two-Pass Model

Everything we do fits into two passes:

| Pass | What Happens | Tool | Time |
|------|-------------|------|------|
| **Pass 1** | Cloud infrastructure — networking, compute, data stores, IAM, load balancer | Terraform | 20–25 min |
| **Pass 2** | Application deployment — LangSmith Helm chart, secrets wiring, feature overlays | Helm + scripts | 10 min |

The split matters because Terraform owns all the durable infrastructure and Helm owns the application lifecycle. Customers can run `terraform destroy` to wipe infrastructure or `helm uninstall` to wipe the app, independently. It also means customer security teams can review Terraform separately from app config.

---

## Pass 1: Terraform Infrastructure

### What Gets Built

```
VPC
  └── EKS Cluster
        ├── Node Groups (auto-scaled)
        ├── AWS Load Balancer Controller
        ├── Cluster Autoscaler
        ├── Metrics Server
        ├── EBS CSI Driver
        └── K8s Bootstrap (KEDA, ESO, cert-manager, namespace, secrets)

RDS PostgreSQL         ──┐
ElastiCache Redis      ──┤── all in private subnets, behind security groups
S3 Bucket              ──┤
VPC Gateway Endpoint   ──┘

ALB (pre-provisioned)
  └── Optional: Route 53 Hosted Zone + ACM Certificate

Optional:
  ├── Bastion Host (EC2 w/ SSM)
  ├── CloudTrail (API audit log)
  └── WAF (OWASP + IP reputation + bad inputs)
```

### Naming Convention

Everything follows `{name_prefix}-{environment}-{resource}`. For example:
- `acme-prod-eks` — cluster
- `acme-prod-pg` — RDS instance
- `acme-prod-redis` — ElastiCache
- `acme-prod-traces-a1b2c3d4` — S3 bucket (random suffix for global uniqueness)
- `acme-prod-alb` — load balancer

All resources share common tags: `app=langsmith`, `environment`, `managed-by=terraform`.

---

## Module-by-Module Breakdown

### 1. `vpc` — Networking Foundation

**What it does:**
Creates the VPC that everything else lives in. Default CIDR is `10.0.0.0/16`. Provisions three private subnets (for EKS nodes, RDS, Redis, bastion) and three public subnets (for the ALB) across three availability zones. One NAT gateway for private subnet egress.

**Why it's designed this way:**
- Private subnets: workloads never have public IPs. All outbound traffic goes through NAT.
- Public subnets: only the ALB lives here. Traffic enters through port 80/443, nothing else.
- Subnet tagging: private subnets are tagged for internal ELB; public subnets are tagged for internet-facing ELB. AWS Load Balancer Controller uses these tags to auto-discover where to place the ALB.

**Key outputs:** `vpc_id`, `private_subnets`, `public_subnets`, `vpc_cidr_block`

**Skip this module if:** customer has an existing VPC. Set `create_vpc = false` and provide `vpc_id`, `private_subnets`, `public_subnets`, `vpc_cidr_block` manually.

---

### 2. `eks` — Kubernetes Cluster

**What it does:**
Provisions the EKS control plane, managed node groups, and a suite of add-ons required for LangSmith to run.

**Default node group:**
- Instance: `m5.4xlarge` (16 vCPU, 64 GB RAM)
- Min: 3 nodes, Max: 10 nodes
- Desired size is managed by Cluster Autoscaler — Terraform ignores drift on `desired_size`

**Add-ons installed by this module:**
| Add-on | What it does |
|--------|-------------|
| AWS Load Balancer Controller | Reconciles Kubernetes Ingress → ALB rules |
| Cluster Autoscaler | Scales node groups up/down based on pending pods |
| Metrics Server | Pod CPU/memory metrics (required for HPA) |
| EBS CSI Driver | Enables EBS volumes for PVCs (ClickHouse, etc.) |

**Storage class:**
Creates `gp3` as the cluster default. `allowVolumeExpansion: true` — PVCs can grow without pod restarts.

**IRSA (IAM Roles for Service Accounts):**
Creates an IRSA role scoped to the `langsmith` namespace. This is how LangSmith pods get AWS permissions (S3 access) without using static IAM keys. The OIDC provider federation is set up here — EKS issues JWT tokens that AWS STS validates against the OIDC provider URL.

**Key outputs:** `cluster_name`, `cluster_endpoint`, `oidc_provider_arn`, `langsmith_irsa_role_arn`

**Customer question to anticipate:** *"Can we use Fargate?"* — Not with this module. EKS managed node groups give us better control over instance types, startup time, and add-on compatibility. Fargate also has constraints with DaemonSets and ClickHouse stateful workloads.

---

### 3. `postgres` — RDS PostgreSQL

**What it does:**
Provisions a PostgreSQL 16 RDS instance in private subnets. LangSmith uses this as its primary relational store (runs, projects, organizations, orgs, etc.).

**Default config:**
- Instance: `db.t3.large`
- Storage: 10 GB with autoscaling up to 100 GB
- Engine: PostgreSQL 16
- Multi-AZ: off by default (opt-in)
- Deletion protection: on by default

**Security:**
- Not publicly accessible — only reachable from within the VPC
- Security group: port 5432 from VPC CIDR only
- Storage encrypted (AES-256)

**IAM Database Auth (enabled by default):**
Instead of storing a Postgres password in the app, pods use their IRSA role to get a short-lived token from RDS. Eliminates long-lived database credentials. The IAM database user still needs to be created inside PostgreSQL once (one-time bootstrap step).

**Key output:** `connection_url` (with password) or `iam_connection_url` (IAM auth, no password)

**Gotcha:** `allocated_storage` has `lifecycle { ignore_changes }`. If storage autoscales, Terraform won't try to shrink it on the next apply.

**Gotcha:** `skip_final_snapshot = true` — safe for dev/POC, should be `false` for production.

---

### 4. `redis` — ElastiCache Redis

**What it does:**
Provisions an ElastiCache Redis 7.1 replication group in private subnets. LangSmith uses Redis for caching, session state, and queue coordination.

**Default config:**
- Instance: `cache.m6g.xlarge`
- Single node (no replication)
- TLS in-transit: enabled
- Auth token: required (minimum 16 chars, hex-compatible)

**Security:**
- Security group: port 6379 from VPC CIDR only
- At-rest encryption enabled
- TLS required for all connections

**Connection URL format:** `rediss://:auth_token@endpoint:6379` (note double `s` for TLS)

**Important caveat:** `num_cache_clusters = 1` — this is a single Redis node. No automatic failover. For production HA, use Redis Enterprise or LangChain Managed Redis (separate use case in this repo).

---

### 5. `storage` — S3 Blob Storage

**What it does:**
Provisions the S3 bucket where LangSmith stores trace payloads. This is always required — payloads must not go into ClickHouse or you'll blow up the cluster.

**Key features:**

**TTL lifecycle rules (built-in):**
- Objects under `ttl_s/*` expire after 14 days (short-lived traces)
- Objects under `ttl_l/*` expire after 400 days (long-retention traces)
- LangSmith routes traces to these prefixes based on retention policy set at project level

**VPC Gateway Endpoint:**
All S3 traffic stays on the AWS backbone — no public internet. The bucket policy enforces this by requiring `aws:SourceVpce` condition, meaning requests from outside the VPC are denied even if credentials are valid.

**Bucket policy (when enabled):**
Restricts access to:
1. Only the LangSmith IRSA role (no other IAM principal)
2. Only through the VPC Gateway Endpoint

**Encryption:** SSE-S3 (AES-256) by default. Pass `s3_kms_key_arn` to use SSE-KMS with a customer-managed key.

**Key outputs:** `bucket_name`, `bucket_arn`

---

### 6. `alb` — Application Load Balancer

**What it does:**
Pre-provisions the ALB before the Helm deploy. This is a deliberate design choice — ALB is created in Pass 1 so its DNS name is a known Terraform output before Helm values are generated.

**Why pre-provision instead of letting the Ingress controller create it?**
If the Ingress controller creates the ALB, you don't know the DNS name until after the Helm deploy. You'd have to deploy Helm first, wait for the ALB, then configure DNS. By pre-provisioning, the DNS name is available as a Terraform output and gets written directly into `langsmith-values-overrides.yaml`.

**What it creates:**
- ALB (internet-facing or internal, configurable)
- Security group: port 80 always open, port 443 if TLS enabled
- HTTP:80 listener → redirects to HTTPS (if ACM) or returns 404
- HTTPS:443 listener → fixed-response 404 (routing rules added by AWS LBC via Ingress)

**Integration:** AWS Load Balancer Controller watches Ingress resources. When Helm deploys LangSmith with the `alb.ingress.kubernetes.io/load-balancer-arn` annotation pointing to our pre-provisioned ALB, the controller adds forwarding rules to the existing ALB instead of creating a new one.

**Key outputs:** `alb_dns_name`, `alb_arn`, `alb_zone_id`

---

### 7. `dns` — Route 53 + ACM Certificate (Optional)

**What it does:**
Manages DNS and TLS certificate provisioning. Only runs when `langsmith_domain` is set and `acm_certificate_arn` is not provided.

**What it creates:**
- Route 53 hosted zone for the domain
- ACM certificate with DNS validation
- Route 53 CNAME records for DNS validation
- Route 53 A-record alias pointing the domain → ALB

**Three-option TLS model:**

| Option | How to Configure | When to Use |
|--------|-----------------|-------------|
| `none` | `tls_certificate_source = "none"` | Internal demo, HTTP only |
| `acm` | `tls_certificate_source = "acm"` + provide `acm_certificate_arn` or `langsmith_domain` | Production (AWS-managed cert) |
| `letsencrypt` | `tls_certificate_source = "letsencrypt"` + `letsencrypt_email` | External domain, auto-renewal via cert-manager |

**Two-apply pattern for new domains:**
1. First `terraform apply` — creates Route 53 zone, shows NS records
2. Customer delegates NS records at their registrar (manual step, may take hours)
3. Second `terraform apply` — ACM waits for DNS validation to complete, then activates HTTPS listener

---

### 8. `k8s-bootstrap` — Kubernetes Setup

**What it does:**
After EKS is provisioned, this module sets up the Kubernetes-layer infrastructure that LangSmith depends on.

**What it creates:**
- `langsmith` namespace with labels
- Kubernetes secrets: `langsmith-postgres` and `langsmith-redis` (connection URLs)
- **KEDA** (v2.19.0) — event-driven autoscaling, required for LangSmith's Deployments feature (scales listener/operator pods based on queue depth)
- **cert-manager** (v1.20.0) — only if `tls_certificate_source = "letsencrypt"`, manages ACME challenges
- **External Secrets Operator** (v2.1.0) — syncs AWS SSM Parameter Store values → Kubernetes secrets
- **Envoy Gateway** (optional) — Kubernetes Gateway API implementation, alternative to Ingress for advanced routing

**The 30-second wait:**
There's a `time_sleep.wait_for_alb_webhook` resource before k8s-bootstrap runs. The AWS Load Balancer Controller installs admission webhooks. If ESO or KEDA Helm releases are submitted before the webhook is ready, Kubernetes rejects them with "no endpoints available for service." The 30-second sleep prevents this race condition.

**ESO IRSA setup (in root main.tf):**
ESO needs an IAM role to read from SSM Parameter Store. The root module creates this role with:
- Trust: OIDC federation → `system:serviceaccount:external-secrets:external-secrets` (strictly scoped)
- Policy: `ssm:GetParameter*`, `ssm:GetParametersByPath` on `arn:aws:ssm:region:account:parameter/langsmith/{base_name}/*`

---

### 9. `bastion` — EC2 Bastion Host (Optional, `create_bastion = false`)

**What it does:**
Provides a jump host for accessing a private EKS cluster (when `enable_public_eks_cluster = false`). Also useful for RDS/Redis access without VPN.

**Default access method: SSM Session Manager (no SSH, no bastion SG hole):**
- No SSH port (22) open by default
- IAM role gives SSM access — connect via `aws ssm start-session`
- The terraform output gives you the exact `aws ssm start-session` command

**Pre-installed tools:** kubectl, helm, aws-cli, terraform

**IMDSv2 enforced:** Prevents SSRF attacks from stealing instance IAM credentials.

---

### 10. `cloudtrail` — API Audit Logging (Optional, `create_cloudtrail = false`)

**What it does:**
Records all AWS API calls made within the account to an S3 bucket. Useful for compliance customers (SOC2, HIPAA, FedRAMP-adjacent).

**When to suggest this:**
- Customer mentions audit requirements
- Customer has SIEM or log aggregation (CloudTrail → CloudWatch → Splunk/Datadog)
- Multi-region deployments where central trail is needed

**Note:** Many enterprise customers already have an org-level CloudTrail. Ask before adding this — it may be redundant.

---

### 11. `waf` — WAF Web ACL (Optional, `create_waf = false`)

**What it does:**
Attaches a WAFv2 Web ACL to the ALB with three AWS managed rule groups:
- **CommonRuleSet** — OWASP Top 10 (SQLi, XSS, path traversal)
- **AmazonIpReputationList** — botnets, scanners, Tor exits
- **KnownBadInputsRuleSet** — Log4Shell, Spring4Shell, etc.

**Cost:** ~$8/month base + $0.60/million requests. Low for most customers.

**When to suggest this:** Public-facing deployments, especially in financial services, healthcare, or any customer with a security-conscious posture. Easy win — adds meaningful protection with no app changes.

---

## IRSA: How AWS Permissions Work (No Static Keys)

This is a key talking point with security-conscious customers.

**Problem:** LangSmith pods need to read/write S3. Traditionally you'd create an IAM user and inject access keys — a static credential that can be rotated but never truly zero-trust.

**Our solution: IRSA (IAM Roles for Service Accounts)**

```
LangSmith Pod
  ↓ presents Kubernetes service account JWT
EKS OIDC Provider
  ↓ validates JWT, returns temporary AWS credentials
AWS STS
  ↓ issues short-lived access token (1-hour TTL)
LangSmith S3 Access
```

The `langsmith_irsa_role_arn` from the EKS module is annotated onto LangSmith's Kubernetes service account. AWS SDK in the pod automatically picks up the credential chain — no code changes, no secrets to rotate.

**Scope:** The IRSA role allows any service account in the `langsmith` namespace. ESO has its own separate, stricter IRSA role scoped to exactly `system:serviceaccount:external-secrets:external-secrets`.

---

## Secrets Flow: SSM → ESO → Kubernetes → LangSmith

```
AWS SSM Parameter Store
  /langsmith/{base_name}/postgres-password
  /langsmith/{base_name}/redis-auth-token
  /langsmith/{base_name}/langsmith-api-key-salt
  /langsmith/{base_name}/langsmith-jwt-secret
  ...
        ↓  (ESO reads via IRSA, syncs every 1h)
External Secrets Operator
        ↓  (creates/updates Kubernetes Secret)
Kubernetes Secret: langsmith-config-secret
        ↓  (mounted as env vars)
LangSmith Pods
```

**Why ESO instead of mounting SSM directly?**
ESO gives you standard Kubernetes secret semantics. Apps don't need AWS SDK awareness. Secrets are rotated in SSM, ESO picks up the new value within the sync interval, no pod restarts needed.

---

## Pass 2: Helm Deployment

### init-values.sh — Generating Values from Terraform

Before deploying Helm, run `init-values.sh`. It reads your `terraform.tfvars` and `terraform output` and generates:

1. `langsmith-values.yaml` — base AWS config (copied from examples)
2. `langsmith-values-overrides.yaml` — auto-generated with your specific values:
   - `bucket_name` from Terraform output
   - `langsmith_irsa_role_arn` from Terraform output
   - `alb_dns_name` from Terraform output (or custom domain)
   - TLS settings based on `tls_certificate_source`
3. Feature overlay files (based on which features you enabled)
4. Sizing values file (based on `sizing_profile`)

### deploy.sh — Helm Values Layering

Values are merged in order — last file wins:

```
Base values (langsmith-values.yaml)
  + Overrides (langsmith-values-overrides.yaml)
  + Feature: Deployments (langsmith-values-agent-deploys.yaml)     [if enabled]
  + Feature: Agent Builder (langsmith-values-agent-builder.yaml)   [if enabled]
  + Feature: Insights (langsmith-values-insights.yaml)             [if enabled]
  + Feature: Polly (langsmith-values-polly.yaml)                   [if enabled]
  + Sizing (langsmith-values-sizing-{profile}.yaml)                [applied last]
```

**Why sizing is applied last:** Sizing values override replica counts and resource limits. If you apply sizing first and then agent-deploys, the agent-deploys file might reset replica counts. Applying sizing last ensures it always wins.

### Sizing Profiles

| Profile | Use Case | Replicas | Resources |
|---------|----------|----------|-----------|
| `minimum` | Cost optimization, POC | 1x each | Bare minimum |
| `dev` | Dev/CI/demo | 1x each | Low requests/limits |
| `default` | Chart defaults | Chart default | No override |
| `production` | ~20 users, 100 traces/sec | Multi-replica + HPA | Medium |
| `production-large` | ~50 users, 1000 traces/sec | Wide HPA range | High |

---

## Deployment Topology Options

### Option A: All Internal (Dev/POC Only)

```
EKS Cluster
  ├── LangSmith pods
  ├── PostgreSQL (in-cluster)
  ├── Redis (in-cluster)
  └── ClickHouse (in-cluster StatefulSet)
```

Set `postgres_source = "internal"`, `redis_source = "internal"`. No RDS or ElastiCache. Fastest to spin up, lowest cost. **Not production-grade** — data is ephemeral, no backups, single points of failure.

### Option B: External Postgres + Redis + S3, Internal ClickHouse

```
EKS Cluster          AWS Managed
  ├── LangSmith ──→  RDS PostgreSQL
  ├── S3 ──────────→ S3 Bucket
  ├── ClickHouse      ElastiCache Redis
  └── (in-cluster)
```

This is the **quick-start production path**. Managed data stores for durability. In-cluster ClickHouse is fine for small teams but watch it — it's a single StatefulSet pod, no replication, no backups.

### Option C: All External (Production Recommended)

```
EKS Cluster              AWS / LangChain Managed
  └── LangSmith ──→      RDS PostgreSQL
                    ──→  ElastiCache Redis
                    ──→  S3 Bucket
                    ──→  LangChain Managed ClickHouse
```

External ClickHouse means no stateful workloads in the cluster. Full durability, proper HA. This is what you recommend to any customer with production SLOs.

---

## Dependency Graph (Pass 1)

```
[vpc] ──────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  ├──→ [eks] ──→ [time_sleep 30s] ──→ [k8s-bootstrap]                       │
  │      │                                                                   │
  │      └──→ [storage] (uses eks.langsmith_irsa_role_arn)                   │
  │                                                                          │
  ├──→ [postgres] (uses vpc.private_subnets)                                 │
  ├──→ [redis]    (uses vpc.private_subnets)                                 │
  ├──→ [alb]      (uses vpc.public_subnets)                                  │
  │      │                                                                   │
  │      └──→ [dns] ──→ [route53_record.langsmith_alb_alias]                 │
  │                                                                          │
  ├──→ [bastion]  (uses vpc + eks)                                           │
  ├──→ [cloudtrail]                                                          │
  └──→ [waf]      (uses alb.alb_arn)                                         │
                                                                             │
root module: IRSA S3 policy (uses eks.langsmith_irsa_role_arn + storage.bucket_arn)
root module: ESO IAM role (uses eks.oidc_provider_arn)                       │
```

**Critical path:** vpc → eks → (storage in parallel, postgres in parallel, redis in parallel, alb in parallel) → 30s sleep → k8s-bootstrap.

EKS is the longest-running step (~15 min). Everything else is 3–5 min. Total Pass 1: ~20–25 min.

---

## Key Customer Talking Points

### "How is this secure?"

- No pods have public IPs. Only the ALB is internet-facing.
- No static IAM credentials — IRSA gives pods short-lived tokens (1-hour TTL).
- S3 payloads never touch the public internet (VPC Gateway Endpoint + bucket policy).
- All RDS and Redis traffic is inside the VPC (no public endpoints).
- Optional WAF adds OWASP Top 10 protection at the ALB layer.
- Optional CloudTrail gives full API audit trail.

### "What happens if a node dies?"

- EKS distributes pods across multiple nodes (3+ by default).
- Cluster Autoscaler replaces terminated nodes automatically.
- ALB health checks remove unhealthy pods from rotation.
- Single points of failure: RDS (no Multi-AZ by default — enable for prod), Redis (single node by default — use Redis Enterprise for HA).

### "Who manages the Kubernetes control plane?"

AWS does. EKS is a managed control plane — patching, HA, and availability are AWS's responsibility. You're responsible for node groups, application workloads, and cluster add-ons.

### "How do we upgrade LangSmith?"

Pass 2 only — `helm upgrade langsmith`. No Terraform changes needed. Run `helm repo update`, bump the chart version, rerun deploy.sh.

### "How do we upgrade Kubernetes?"

Update `eks_cluster_version` in `terraform.tfvars`, run `terraform apply`. EKS does a rolling upgrade of the control plane first, then managed node groups. Node groups are upgraded one at a time, pods are drained before node replacement.

### "Can we bring our own VPC?"

Yes. Set `create_vpc = false` and provide `vpc_id`, `private_subnets`, `public_subnets`, `vpc_cidr_block`. The only requirement is that private subnets can route to the internet (NAT gateway or equivalent) and public subnets are tagged for ELB.

### "Can we use our own domain and TLS cert?"

Two options:
1. Provide an existing ACM certificate ARN via `acm_certificate_arn`.
2. Set `langsmith_domain` and let Terraform create the Route 53 zone + ACM cert automatically. Requires delegating NS records.

### "What's the cost estimate?"

Rough monthly baseline (us-east-1, on-demand pricing):
| Component | Cost/month |
|-----------|-----------|
| EKS control plane | ~$73 |
| 3x m5.4xlarge nodes | ~$1,100 |
| RDS db.t3.large | ~$100 |
| ElastiCache cache.m6g.xlarge | ~$150 |
| ALB | ~$20 |
| S3 (varies with data) | ~$5–50 |
| NAT Gateway | ~$45 |
| **Total baseline** | **~$1,500–1,600/mo** |

Savings levers: Reserved Instances (up to 40% off), Spot for non-stateful node groups, right-sizing with `dev` profile for non-production.

---

## Common Failure Modes

| Symptom | Root Cause | Fix |
|---------|-----------|-----|
| k8s-bootstrap Helm release fails with "no endpoints" | ALB webhook not ready | The 30s sleep should handle this; if it recurs, increase `time_sleep` duration |
| ACM cert stuck in PENDING | NS records not delegated | Delegate NS at registrar, wait for propagation (~TTL), re-apply |
| Pods stuck in `Pending` | Node autoscaler not triggered or max nodes hit | Check `kubectl describe pod`, check autoscaler logs, increase `max_size` in node group |
| S3 access denied | IRSA role ARN missing from service account annotation | Verify `serviceAccountAnnotations` in Helm values includes the IRSA role ARN |
| ESO not syncing secrets | ESO IRSA role missing SSM permission | Verify root module created ESO IAM role and ESO service account has the annotation |
| RDS `final snapshot` error on destroy | `deletion_protection = true` or `skip_final_snapshot = false` | Disable deletion protection, set skip_final_snapshot = true, then re-destroy |
| ALB listener returning 404 for everything | Helm hasn't been deployed yet (no Ingress rules) | Normal state after Pass 1. Deploy Helm (Pass 2). |

---

## File Reference

```
terraform/aws/
├── infra/
│   ├── main.tf                     Root module: module wiring, IRSA policies, ESO role
│   ├── locals.tf                   Naming convention (base_name, tags)
│   ├── variables.tf                All ~590 input variables with validation
│   ├── outputs.tf                  50+ outputs (ALB DNS, bucket name, IRSA ARN, etc.)
│   ├── versions.tf                 Provider pins (Terraform ~1.5, AWS ~5.100)
│   ├── backend.tf                  Remote state backend config (configure before init)
│   ├── terraform.tfvars.example    Starter values — copy to terraform.tfvars
│   └── modules/
│       ├── vpc/                    VPC, subnets, NAT gateway
│       ├── eks/                    EKS cluster, node groups, add-ons, IRSA
│       ├── postgres/               RDS PostgreSQL
│       ├── redis/                  ElastiCache Redis
│       ├── storage/                S3 bucket, VPC endpoint, lifecycle, bucket policy
│       ├── alb/                    Application Load Balancer, listeners, SG
│       ├── k8s-bootstrap/          Namespace, secrets, KEDA, ESO, cert-manager
│       ├── dns/                    Route 53 zone, ACM certificate, DNS records
│       ├── bastion/                EC2 bastion, SSM access, pre-installed tools
│       ├── cloudtrail/             CloudTrail + S3 audit bucket
│       ├── waf/                    WAFv2 ACL with managed rule groups
│       └── networking/             (Reserved — additional SG/NACLs if needed)
│
└── helm/
    ├── scripts/
    │   ├── deploy.sh               Main orchestrator: values merge + helm upgrade
    │   ├── init-values.sh          Generates values from Terraform outputs
    │   ├── apply-eso.sh            Applies ESO ClusterSecretStore + ExternalSecret
    │   ├── preflight-check.sh      Pre-deploy validation (connectivity, ESO, namespace)
    │   └── uninstall.sh            Removes Helm release + cleans namespace
    └── values/
        └── examples/
            ├── langsmith-values.yaml               Base AWS config
            ├── langsmith-values-sizing-production.yaml
            ├── langsmith-values-sizing-production-large.yaml
            ├── langsmith-values-sizing-dev.yaml
            ├── langsmith-values-sizing-minimum.yaml
            ├── langsmith-values-agent-deploys.yaml
            ├── langsmith-values-agent-builder.yaml
            ├── langsmith-values-insights.yaml
            └── langsmith-values-polly.yaml
```

---

*Last updated: 2026-03-28 — covers current `feat/dz-local` branch state*
