# LangSmith on AWS — Architecture

---

## Platform Layers

LangSmith on AWS is deployed in three passes.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Pass 3 — LangSmith Deployments  (enable_langsmith_deployments = true)       │
│                                                                              │
│  Purpose: Deploy and manage LangGraph applications from the LangSmith UI.   │
│                                                                              │
│  Adds to cluster:                                                            │
│    • host-backend   — deployment lifecycle API                               │
│    • listener       — syncs desired state into Kubernetes                    │
│    • operator       — controls LGP CRD and manages rollouts                 │
│                                                                              │
│  Per deployed graph:                                                         │
│    • api-server, queue, redis, postgres  (operator-managed)                  │
│                                                                              │
│  Requires: KEDA (installed in Pass 1 via k8s-bootstrap module)              │
├──────────────────────────────────────────────────────────────────────────────┤
│  Pass 2 — LangSmith Base Platform  (deploy_langsmith = true)                 │
│                                                                              │
│  Purpose: Observability, tracing, evaluations, experiments, API keys.        │
│                                                                              │
│  Components (Helm chart, namespace: langsmith):                              │
│    • backend        — core API server                                        │
│    • frontend       — React UI                                               │
│    • playground     — LLM prompt playground                                  │
│    • queue          — background job worker                                  │
│    • clickhouse     — trace analytics store                                  │
│    • redis          — task queue (in-cluster or ElastiCache)                 │
│    • postgres       — metadata store (in-cluster or RDS)                     │
│                                                                              │
│  Storage:  RDS PostgreSQL → metadata / S3 → trace blobs (VPC endpoint)      │
│  Ingress:  AWS ALB → HTTP 80 or HTTPS 443 (based on TLS config)             │
├──────────────────────────────────────────────────────────────────────────────┤
│  Pass 1 — AWS Infrastructure                                                 │
│                                                                              │
│  Networking: VPC + private/public subnets + single NAT gateway               │
│  Compute:    EKS cluster + managed node group + cluster autoscaler          │
│  Database:   RDS PostgreSQL (db.t3.large, private subnets)                  │
│  Cache:      ElastiCache Redis (cache.m6g.xlarge, private subnets)          │
│  Storage:    S3 bucket (VPC Gateway Endpoint — no public internet)          │
│  Add-ons:    ALB controller + EBS CSI driver + metrics server               │
│  Opt-in:     Network Firewall (FQDN-based egress filtering)                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Component → Storage Mapping

| Component   | Storage backend              | Access method                     |
|-------------|------------------------------|-----------------------------------|
| backend     | RDS PostgreSQL               | Private subnet, security group    |
| backend     | S3 bucket                    | IRSA + VPC Gateway Endpoint       |
| clickhouse  | EBS volume (GP3, EKS PVC)   | Local                             |
| redis       | ElastiCache or in-cluster    | Private subnet, security group    |
| LGP operator| RDS PostgreSQL (shared)      | Private subnet, security group    |

---

## Network Topology

```
Internet
    │
    ▼
AWS Application Load Balancer (ALB — port 80 or 443)
    │  TLS via ACM / Let's Encrypt (optional)
    ▼
EKS Cluster (private subnets)
  ├── kube-system namespace
  │     ├── aws-load-balancer-controller
  │     ├── cluster-autoscaler
  │     ├── ebs-csi-driver
  │     └── keda
  └── langsmith namespace
        ├── backend, frontend, playground, queue, clickhouse
        └── redis (in-cluster) OR ElastiCache ──► private subnet
              └── RDS PostgreSQL ──────────────► private subnet
                    └── S3 bucket ──────────────► VPC Gateway Endpoint (no public route)
```

### Egress path with Network Firewall (optional — `create_firewall = true`)

When Network Firewall is enabled, all outbound internet traffic from private subnets is
inspected before reaching the NAT gateway:

```
EKS pods / RDS / ElastiCache (private subnets)
    │  0.0.0.0/0 → firewall endpoint (private route table)
    ▼
AWS Network Firewall (firewall subnet, same AZ as NAT gateway)
    │  domain allowlist: TLS SNI + HTTP Host inspection
    │  ALLOWLIST: firewall_allowed_fqdns (default: beacon.langchain.com)
    │  DROP: all other established connections
    ▼
NAT Gateway (public subnet)
    │
    ▼
Internet
```

Internal traffic (pod-to-pod, pod-to-RDS, pod-to-ElastiCache) routes via the local VPC
route and never touches the firewall.

---

## IRSA (IAM Roles for Service Accounts)

IRSA is used instead of static credentials for S3 access:

1. An IAM Role is created with a trust policy scoped to the EKS cluster's OIDC issuer.
2. The role is granted `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the LangSmith bucket.
3. The Kubernetes Service Account in `langsmith` namespace is annotated with the role ARN.
4. Pods receive temporary credentials via the EKS token webhook — no static AWS keys required.

---

## Module Dependency Graph

```
vpc  ──►  firewall  (AWS Network Firewall, optional — create_firewall = true)
│
├──►  eks  ──►  k8s-bootstrap (cert-manager, KEDA, ESO)
│
├──►  postgres    (RDS, private subnets from VPC)
├──►  redis       (ElastiCache, private subnets from VPC)
├──►  storage     (S3 bucket + VPC Gateway Endpoint)
├──►  alb         (pre-provisioned ALB, public subnets)
├──►  dns         (Route 53 zone + ACM cert, optional)
├──►  cloudtrail  (audit logging, optional)
├──►  waf         (WAF ACL on ALB, optional)
└──►  bastion     (jump host for private EKS access, optional)
          all ──►  langsmith (root module)
```

### Opt-In Security Modules

Four modules are disabled by default and can be enabled in `terraform.tfvars`:

| Module | Variable | Default | Purpose |
|--------|----------|---------|---------|
| Network Firewall | `create_firewall` | `false` | FQDN-based egress filtering — drops all outbound traffic not in `firewall_allowed_fqdns`. Requires `create_vpc = true`. Cost: ~$0.395/hr/endpoint + $0.065/GB processed. |
| ALB access logs | `alb_access_logs_enabled` | `false` | Traffic analysis and compliance |
| CloudTrail | `create_cloudtrail` | `false` | API call logging (skip if org trail exists) |
| WAF | `create_waf` | `false` | WAFv2 Web ACL — OWASP Top 10, IP reputation, known bad inputs |

---

## Default Resource Sizes

| Resource         | Default size        | vCPU | Memory  |
|------------------|---------------------|------|---------|
| EKS node         | `m5.4xlarge`        | 16   | 64 GB   |
| RDS PostgreSQL   | `db.t3.large`       | 2    | 8 GB    |
| ElastiCache Redis| `cache.m6g.xlarge`  | 4    | 13.07 GB|
| RDS storage      | 10 GB               | —    | —       |

---

## DNS & TLS (Custom Domain)

Three paths for TLS, configured via `tls_certificate_source`:

| Mode | Behavior |
|------|----------|
| `none` | HTTP:80 only. No certificate. |
| `acm` | HTTPS:443 with HTTP→HTTPS redirect. ACM certificate required. |
| `letsencrypt` | HTTPS via cert-manager. HTTP:80 kept for ACME challenge. |

### Auto-provisioned DNS (recommended for new deployments)

When `langsmith_domain` is set (and `acm_certificate_arn` is empty), Terraform activates the `dns` module which creates:
- A Route 53 hosted zone for the domain
- An ACM certificate with DNS validation records
- A Route 53 alias record pointing the domain to the ALB

**Staged deploy pattern:** You can set `langsmith_domain` with `tls_certificate_source = "none"` first. Terraform creates the zone and cert but does not block on validation. Delegate NS records at your registrar, then flip to `tls_certificate_source = "acm"` in a later apply — Terraform blocks until the cert validates, then wires it into the ALB HTTPS listener.

### Bring-your-own certificate

Set `acm_certificate_arn` directly to skip the dns module entirely.

---

## Verification Commands

```bash
# EKS cluster status
aws eks describe-cluster --name <cluster-name> --query "cluster.status"

# Node health
kubectl get nodes -o wide

# ALB status
kubectl get ingress -n langsmith

# RDS status
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='<db-id>'].DBInstanceStatus"

# ElastiCache status
aws elasticache describe-replication-groups \
  --query "ReplicationGroups[?ReplicationGroupId=='<group-id>'].Status"

# S3 bucket from pod (via VPC endpoint)
kubectl run s3-test --rm -it --image=amazon/aws-cli -n langsmith -- \
  aws s3 ls s3://<bucket-name>
```
