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
│  Ingress:  AWS ALB | NGINX | Envoy Gateway | Istio  (see Ingress Options)    │
├──────────────────────────────────────────────────────────────────────────────┤
│  Pass 1 — AWS Infrastructure                                                 │
│                                                                              │
│  Networking: VPC + private/public subnets + single NAT gateway               │
│  Compute:    EKS cluster + managed node group + cluster autoscaler          │
│  Database:   RDS PostgreSQL (db.t3.large, private subnets)                  │
│  Cache:      ElastiCache Redis (cache.m6g.xlarge, private subnets)          │
│  Storage:    S3 bucket (VPC Gateway Endpoint — no public internet)          │
│  Add-ons:    ALB controller + EBS CSI driver + metrics server               │
│  Bootstrap:  k8s-bootstrap (KEDA, ESO, Envoy Gateway [opt-in]),            │
│              cert-manager (standalone, active when tls=letsencrypt)         │
│  Ingress:    ALB (default) or Envoy Gateway (opt-in, enable_envoy_gateway)  │
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

**Default (ALB ingress):**
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

**Envoy Gateway (opt-in, `enable_envoy_gateway = true`):**
```
Internet
    │
    ▼
AWS Network Load Balancer (NLB — ACM TLS termination at port 443)
    │
    ▼
envoy-gateway-system namespace
  └── Envoy proxy (GatewayClass: eg, Gateway: langsmith-gateway)
        │  HTTPRoute → langsmith-frontend:80
        ▼
langsmith namespace
  └── backend, frontend, playground, queue, clickhouse, ...

langsmith-agents namespace (optional — dataplane)
  └── langgraph-dataplane listener + operator + agent pods
        └── HTTPRoute attaches to shared langsmith-gateway (cross-namespace via allowedRoutes: All)
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

## Ingress Options

Four mutually exclusive ingress options are supported. The choice determines whether
split dataplane (agent pods in a separate namespace) is possible:

| Option | Variable | Split dataplane | Traffic path | When to use |
|---|---|---|---|---|
| **ALB (AWS LBC)** | *(default)* | No | `ALB → frontend NodePort` | Default. Single-namespace deployments, POC, simplest TLS via ACM. |
| **NGINX Ingress** | `enable_nginx_ingress = true` | No | `ALB → TGB → NGINX controller → frontend ClusterIP` | When NGINX is already the standard in your org. ALB TGB wires the pre-provisioned ALB target group to the NGINX pods. |
| **Envoy Gateway** | `enable_envoy_gateway = true` | Yes | `ALB → TGB → Envoy proxy pod:10080 → HTTPRoute → services` | Cross-namespace HTTPRoute routing. Recommended for split dataplane on new AWS deployments. |
| **Istio** | `enable_istio_gateway = true` | Yes | `ALB → TGB → istio-ingressgateway:80 → VirtualService → services` | For clusters with Istio already installed or when mTLS mesh is required. Istio 1.23+ binds port 80 directly via `NET_BIND_SERVICE`. |

### Split Dataplane — Why ALB Cannot Support It

Standard Kubernetes Ingress is namespace-scoped. The ALB controller can only route to
services within the same namespace as the Ingress resource. Agent pods in `langsmith-agents`
are invisible to an Ingress in `langsmith`.

Envoy Gateway and Istio both support cross-namespace routing via the Kubernetes Gateway API
(HTTPRoutes) and VirtualServices respectively.

### ALB + Envoy Gateway (chained pattern)

When a customer has an existing ALB with SSO (Okta/Cognito), WAF, and TLS configured,
Envoy Gateway is added behind it rather than replacing it:

```
Internet
    │
    ▼
ALB ← unchanged: WAF, SSO (Okta/Cognito OIDC), TLS, DNS
    │
    ▼  (ALB target group retargeted to Envoy NLB — only change)
Envoy Gateway NLB (internal-scheme, auto-provisioned by k8s-bootstrap)
    │
    ├── HTTPRoute → langsmith ns        (control plane)
    └── HTTPRoute → langsmith-agents ns (agent pods — split dataplane)
```

See `helm/values/examples/langsmith-values-ingress-envoy-gateway.yaml` for the Helm values
and `doc_use_cases/enable_split_dataplane_aws/` for the full split dataplane guide.

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
├──►  eks  ──►  k8s-bootstrap (KEDA, ESO, Envoy Gateway [opt-in])
│                └──►  cert-manager  (standalone module — Let's Encrypt DNS-01 via Route 53 IRSA)
│
├──►  postgres    (RDS, private subnets from VPC)
├──►  redis       (ElastiCache, private subnets from VPC)
├──►  storage     (S3 bucket + VPC Gateway Endpoint)
├──►  alb         (pre-provisioned ALB, public subnets)
│     └──►  alb_access_logs  (S3 bucket for ALB access logs — opt-in)
├──►  dns         (Route 53 zone + ACM cert, optional)
├──►  bastion     (jump host for private EKS access, optional)
├──►  cloudtrail  (audit logging, optional)
├──►  waf         (WAF ACL on ALB, optional)
└──►  firewall    (Network Firewall egress filter, optional)
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
| Network Firewall | `create_firewall` | `false` | AWS Network Firewall — FQDN-based egress filtering for private subnets. Intercepts outbound traffic between the private subnet route tables and the NAT gateway; allows only domains in `firewall_allowed_fqdns` (TLS SNI + HTTP Host). Requires `create_vpc = true`. Cost: ~$0.40/hr per endpoint + $0.065/GB processed. |

### cert-manager Module

`cert-manager` is a **standalone module** (was previously embedded inside `k8s-bootstrap`). It deploys cert-manager into the `cert-manager` namespace and provisions a `ClusterIssuer` for Let's Encrypt DNS-01 challenge resolution via Route 53 IRSA. It is enabled automatically when `tls_certificate_source = "letsencrypt"`.

| Module | When active | Purpose |
|--------|-------------|---------|
| `cert-manager` | `tls_certificate_source = "letsencrypt"` | Deploys cert-manager + ClusterIssuer for Let's Encrypt DNS-01 via Route 53 IRSA |

---

## Validated Behaviors & Known Constraints

Discovered during the gateway permutation test run (April 2026, all four modes validated).

| # | Area | Constraint / Fix |
|---|------|-----------------|
| 1 | **ACM wildcard SANs** | `langchain.com` root zone has `0 issue "amazon.com"` CAA but **not** `0 issuewild "amazon.com"`. Wildcard SANs (`*.subdomain.langchain.com`) always fail with `CAA_ERROR`. The `dns` module requests only the apex domain cert — no wildcard SAN. |
| 2 | **In-cluster Redis** | The LangSmith Helm chart deploys Redis **without** `requirepass`. The Terraform `k8s_bootstrap` module writes `redis://langsmith-redis:6379` (no password). Do not add an auth token unless you also configure the Helm chart Redis values. |
| 3 | **`name_prefix` length** | Maximum 15 characters (not 11). Names like `dz-nginx-tst` (12) are valid. |
| 4 | **Istio port** | Istio 1.23+ ingressgateway listens on port **80** directly via `NET_BIND_SERVICE` capability — not port `8080`. ALB TGB health check and SG rules must target port 80. |
| 5 | **NGINX TGB port** | NGINX ingress-nginx controller pods listen on port **80**. The TargetGroupBinding target type is `ip`. |
| 6 | **Envoy proxy port** | Envoy proxy pods listen on port **10080** (not 80) when running as non-root. The TGB `servicePort` must be `10080`. |
| 7 | **Destroy order** | Always run `terraform destroy` first and let Terraform handle namespace + Helm release lifecycle. Pre-deleting namespaces causes the `helm_release` Terraform resource to timeout (~5m) because Helm cannot uninstall cleanly into a terminating namespace. |
| 8 | **Stuck Terminating namespaces** | KEDA's stale `external.metrics.k8s.io/v1beta1` API group causes `NamespaceDeletionDiscoveryFailure`. Clear with: `kubectl get namespace $ns -o json \| python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \| kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -` |

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

| Mode | Behavior | Gateway |
|------|----------|---------|
| `none` | HTTP:80 only. No certificate. | Any |
| `acm` | HTTPS:443 with HTTP→HTTPS redirect. ACM certificate (auto-provisioned or BYO). | ALB, NGINX |
| `letsencrypt` | HTTPS via cert-manager + Let's Encrypt DNS-01 (Route 53 IRSA). | Istio, Envoy |

> **CAA constraint:** `langchain.com` has `0 issue "amazon.com"` but not `0 issuewild "amazon.com"`. ACM cannot issue wildcard certificates (`*.subdomain.langchain.com`) for subdomains of `langchain.com`. The `dns` module requests the apex domain only. Customers using their own domain are not affected.

### Why ACM vs cert-manager?

**ACM** certificates are non-exportable — AWS attaches them directly to the ALB. This makes ACM the right choice when TLS terminates at the ALB, but it cannot be used when TLS terminates inside the cluster (Istio Gateway, Envoy Gateway) because those gateways require the actual certificate material as a Kubernetes secret.

**cert-manager** (`tls_certificate_source = "letsencrypt"`) handles in-cluster TLS for Istio and Envoy. The `letsencrypt` value is the **reference implementation** — it deploys cert-manager with a Let's Encrypt ACME ClusterIssuer. In production, swap the ClusterIssuer for any cert-manager-compatible issuer:

| Issuer | When to use |
|--------|-------------|
| Let's Encrypt (default) | Public domain, internet access, free |
| **ACM Private CA** (`aws-privateca-issuer`) | AWS-native, air-gap friendly, private domains — ~$400/mo |
| **Venafi** (`cert-manager-venafi`) | Enterprise PKI, regulated environments |
| **HashiCorp Vault** (`cert-manager-vault`) | Self-hosted PKI |
| DigiCert / Sectigo / others | ACME or custom issuer plugins |

The Terraform module provisions the cert-manager IRSA role and Route 53 permissions. The ClusterIssuer manifest is the only thing that changes between issuers.

### Auto-provisioned DNS (recommended for new deployments)

When `langsmith_domain` is set (and `acm_certificate_arn` is empty), Terraform activates the `dns` module which creates:
- A Route 53 hosted zone for the domain
- An ACM certificate with DNS validation records
- A Route 53 alias record pointing the domain to the ALB

**Staged deploy pattern:** You can set `langsmith_domain` with `tls_certificate_source = "none"` first. Terraform creates the zone and cert but does not block on validation. Delegate NS records at your registrar, then flip to `tls_certificate_source = "acm"` in a later apply — Terraform blocks until the cert validates, then wires it into the ALB HTTPS listener.

### Bring-your-own certificate

Set `acm_certificate_arn` directly to skip the dns module entirely. For in-cluster gateways, create a Kubernetes TLS secret manually and reference it in the Gateway/VirtualService — no cert-manager required.

---

## Envoy Gateway (Gateway API Ingress)

Envoy Gateway is an opt-in alternative to the ALB ingress controller, enabled by setting `enable_envoy_gateway = true` in `terraform.tfvars`.

### What the k8s-bootstrap module creates

| Resource | Name | Namespace |
|----------|------|-----------|
| Helm release | `envoy-gateway` (chart: `gateway-helm` v1.3.0) | `envoy-gateway-system` |
| GatewayClass | `eg` | cluster-scoped |
| Gateway | `langsmith-gateway` | `langsmith` |

The GatewayClass is created explicitly (not via the certgen job) to ensure it persists across re-applies. The Gateway exposes listeners on port 80 (HTTP) and port 443 (HTTP, for ACM TLS termination at NLB) with `allowedRoutes.namespaces.from: All` — enabling HTTPRoutes from any namespace to attach.

### How traffic flows

```
Client
  │
  ▼ NLB (AWS NLB created by Envoy Gateway for the Gateway resource)
  │  ACM TLS termination at port 443 (annotated by deploy.sh)
  ▼
Envoy proxy pod (envoy-gateway-system namespace)
  │
  ▼ HTTPRoute (langsmith namespace) — created by LangSmith Helm chart when gateway.enabled: true
  │
  ▼ langsmith-frontend:80
```

### Multi-namespace dataplane support

Gateway API's `allowedRoutes: All` setting makes Envoy Gateway the recommended ingress for multi-namespace dataplane deployments. Each namespace running `langgraph-dataplane` can attach an HTTPRoute to the shared `langsmith-gateway` without modifying the Gateway resource.

Apply the dataplane RBAC manifest once per dataplane namespace to allow `langsmith-host-backend` to stream pod logs:

```bash
kubectl apply -f helm/values/dataplane-rbac.yaml
# Edit namespace: field if using a namespace other than langsmith-agents
```

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
