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
│  Ingress:  AWS ALB → HTTPS 443 → LangSmith frontend/backend                 │
├──────────────────────────────────────────────────────────────────────────────┤
│  Pass 1 — AWS Infrastructure                                                 │
│                                                                              │
│  Networking: VPC + private/public subnets + single NAT gateway               │
│  Compute:    EKS cluster + managed node group + cluster autoscaler          │
│  Database:   RDS PostgreSQL (db.t3.large, private subnets)                  │
│  Cache:      ElastiCache Redis (cache.m5.large, private subnets)            │
│  Storage:    S3 bucket (VPC Gateway Endpoint — no public internet)          │
│  Add-ons:    ALB controller + EBS CSI driver + metrics server               │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Component → Storage Mapping

| Component   | Storage backend              | Access method                     |
|-------------|------------------------------|-----------------------------------|
| backend     | RDS PostgreSQL               | Private subnet, security group    |
| backend     | S3 bucket                    | IRSA + VPC Gateway Endpoint       |
| clickhouse  | EBS volume (GP3, GKE PVC)   | Local                             |
| redis       | ElastiCache or in-cluster    | Private subnet, security group    |
| LGP operator| RDS PostgreSQL (shared)      | Private subnet, security group    |

---

## Network Topology

```
Internet
    │
    ▼
AWS Application Load Balancer (ALB — port 443)
    │  TLS via ACM certificate
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

---

## IRSA (IAM Roles for Service Accounts)

IRSA is used instead of static credentials for S3 access:

1. An IAM Role is created with a trust policy scoped to the EKS cluster's OIDC issuer.
2. The role is granted `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on the LangSmith bucket.
3. The Kubernetes Service Account in `langsmith` namespace is annotated with the role ARN.
4. Pods receive temporary credentials via the EKS token webhook — no static AWS keys required.

---

## Module Dependency Graph

```
vpc  ──►  eks  ──►  k8s-bootstrap (cert-manager, KEDA, ALB controller)
│
├──►  postgres      (RDS, private subnets from VPC)
├──►  redis         (ElastiCache, private subnets from VPC)
├──►  s3            (bucket + VPC Gateway Endpoint)
├──►  alb           (pre-provisioned ALB — opt-in)
│     └──►  waf     (WAFv2 Web ACL attached to ALB — opt-in)
│     └──►  alb_access_logs  (S3 bucket for ALB access logs — opt-in)
└──►  cloudtrail    (CloudTrail trail + S3 bucket — opt-in)
          all ──►  langsmith (root module)
```

### Opt-In Security Modules

Three modules are disabled by default and can be enabled in `terraform.tfvars`:

| Module | Variable | Default | Purpose |
|--------|----------|---------|---------|
| ALB access logs | `alb_access_logs_enabled` | `false` | Traffic analysis and compliance |
| CloudTrail | `create_cloudtrail` | `false` | API call logging (skip if org trail exists) |
| WAF | `create_waf` | `false` | WAFv2 Web ACL — OWASP Top 10, IP reputation, known bad inputs |

---

## Default Resource Sizes

| Resource         | Default size        | vCPU | Memory  |
|------------------|---------------------|------|---------|
| EKS node         | `m5.xlarge`         | 4    | 16 GB   |
| RDS PostgreSQL   | `db.t3.large`       | 2    | 8 GB    |
| ElastiCache Redis| `cache.m5.large`    | 2    | 6.38 GB |
| RDS storage      | 10 GB               | —    | —       |

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
