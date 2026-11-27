# LangSmith on AWS — Deployment Guide

Self-hosted LangSmith on Amazon EKS, managed with Terraform.

> **Deploy from a release tag, not `main`.** Check out the latest `v0.17.*` tag before deploying (don't hardcode a patch): `git fetch --tags && git checkout "$(git tag -l 'v0.17.*' --sort=-v:refname | head -1)"`. Tags pin the LangSmith chart line (`~0.17.0` = latest `0.17.x`, never `0.18`). See [Versioning and releases](../../README.md#versioning-and-releases).

---

## Overview

This directory contains the Terraform configuration to deploy LangSmith on AWS. Deployment is split into two passes:

| Pass | What | How | Time |
|------|------|-----|------|
| **Pass 1** | VPC, EKS cluster, RDS, ElastiCache, S3, ALB, IRSA, ESO | `make apply` | ~20–25 min |
| **Pass 2** | LangSmith Helm chart + ESO wiring | `make init-values` → `make deploy` | ~10 min |

A [Makefile](Makefile) wraps all commands — run `make help` to see available targets.

### Two deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|------|---------|-------|-----------|---------|
| **Dev** | RDS PostgreSQL (small instance) | ElastiCache Redis (small instance) | In-cluster pod | Demo / POC |
| **Production** | RDS PostgreSQL (private) | ElastiCache Redis (private) | In-cluster ClickHouse | Scalable / persistent |

> **As of LangSmith v0.18, blob storage is required.** The module creates the S3 bucket and points LangSmith at it.
>
> **In-cluster ClickHouse is recommended for production during the transition to SmithDB.** It runs as a single StatefulSet. Customers who prefer a managed ClickHouse lifecycle can use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

---

## Prerequisites

### Required tools

```bash
# AWS CLI v2
brew install awscli
aws --version

# Terraform (>= 1.11.0)
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version

# kubectl
brew install kubectl
kubectl version --client

# Helm (>= 3.12)
brew install helm
helm version

# eksctl (useful for debugging and kubeconfig management)
brew install eksctl
```

### Required AWS IAM permissions

The IAM user or role running Terraform needs `AdministratorAccess`, or `PowerUserAccess` plus `IAMFullAccess`. `PowerUserAccess` alone fails at the first IAM role the apply creates. For a custom policy, the IAM roles the deployment creates, and how to test access before the first apply, refer to [PERMISSIONS.md](PERMISSIONS.md).

### Authenticate

```bash
aws configure
# or:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-west-2

aws sts get-caller-identity
```

#### If your AWS account uses SSO (e.g. Okta-federated)

Federated SSO accounts do **not** issue long-lived access keys — `aws configure` won't work because you have nothing to paste. Use `aws configure sso` instead, which stores a pointer to your SSO portal (in `~/.aws/config`) and mints short-lived credentials on demand.

**One-time setup:**

```bash
aws configure sso
# SSO start URL:        <your AWS access portal URL, e.g. https://<org>.awsapps.com/start>
# SSO region:           us-east-1                    # or wherever Identity Center lives
# (browser opens → sign in via Okta → approve the CLI request)
# Pick account + permission set from the list shown
# Default client region: us-west-2
# Default output format: json
# Profile name:          langchain-aws               # any name you like
```

**Each session (creds expire ~1 hour):**

```bash
aws sso login --profile langchain-aws
export AWS_PROFILE=langchain-aws
aws sts get-caller-identity   # verify
```

After this, `terraform`, `kubectl`, `helm`, and all the `make` targets in this repo pick up the SSO credentials automatically via `AWS_PROFILE`.

**IAM permissions note:** the policies in [PERMISSIONS.md](PERMISSIONS.md) must be attached to the **SSO permission set** (or federated role) you assume — not to you directly. Ask your AWS admin which permission set to use and confirm it covers those policies. The LangChain training account's `AdministratorAccessTraining` permission set already does.

**Optional helper:** some sub-tooling in this repo (parallel test workers, scripts that assume a `[default]` block in `~/.aws/credentials`) doesn't honor `AWS_PROFILE`. For those, run `./infra/scripts/hydrate-creds.sh` after `aws sso login` to dump the temporary key/secret/session-token triple into `~/.aws/credentials [default]`. Re-run it whenever your SSO session expires.

```bash
# Auto-mode — pulls from the SSO profile in ~/.aws/config
AWS_SSO_PROFILE=langchain-aws ./infra/scripts/hydrate-creds.sh
```

---

## Repository Layout

```
aws/
├── Makefile                ← Task runner — run `make help` for all targets
├── infra/                  ← Pass 1: Terraform infrastructure
│   ├── main.tf             ← Root module — wires all sub-modules, IRSA + ESO setup
│   ├── variables.tf        ← All input variables with defaults
│   ├── locals.tf           ← Naming: {name_prefix}-{environment}-{resource}
│   ├── outputs.tf          ← Cluster, DB, Redis, S3, ALB, IAM outputs
│   ├── backend.tf          ← Remote state backend (configure before init)
│   ├── versions.tf         ← Required provider versions
│   ├── scripts/
│   │   ├── _common.sh          ← Shared helpers (tfvar parsing, colors)
│   │   ├── manage-ssm.sh       ← Interactive SSM parameter manager
│   │   ├── migrate-ssm.sh      ← Migrate SSM params from legacy paths
│   │   ├── preflight.sh        ← Pre-Terraform AWS permission checks
│   │   ├── quickstart.sh       ← Interactive setup wizard
│   │   ├── set-kubeconfig.sh   ← Update KUBECONFIG for EKS
│   │   ├── setup-env.sh        ← Create/manage secrets in SSM Parameter Store
│   │   └── status.sh           ← Deployment state checker
│   └── modules/
│       ├── vpc/            ← VPC, subnets, NAT gateway
│       ├── eks/            ← EKS cluster, managed node groups, IRSA role, GP3 storage class
│       ├── postgres/       ← RDS PostgreSQL, subnet group, security group, IAM auth
│       ├── redis/          ← ElastiCache Redis, subnet group, security group, auth token
│       ├── storage/        ← Platform S3 bucket, VPC Gateway Endpoint, bucket policy, TTL lifecycle (platform bucket only)
│       ├── alb/            ← Application Load Balancer, security group, ACM integration
│       ├── k8s-bootstrap/  ← Namespace, KEDA, cert-manager, ESO Helm release
│       ├── bastion/        ← EC2 bastion host for private cluster access (optional)
│       ├── cloudtrail/     ← CloudTrail trail to S3 (optional)
│       ├── waf/            ← WAFv2 Web ACL attached to ALB (optional)
│       └── firewall/       ← AWS Network Firewall, FQDN-based egress filtering (optional)
└── helm/                   ← Pass 2: script-driven Helm deploy
    ├── scripts/
    │   ├── deploy.sh               ← Helm deploy orchestrator (ESO wiring, values layering)
    │   ├── apply-eso.sh            ← Apply ESO ClusterSecretStore + ExternalSecret (standalone)
    │   ├── sso.sh                  ← Turn on SSO login after a working password install (make sso)
    │   ├── init-values.sh          ← Write the two values files from Terraform outputs
    │   ├── _values.sh              ← Merge, seal, and check the values files (same on every cloud)
    │   ├── test-values.sh          ← Render each feature against the chart (make test-values)
    │   ├── preflight-check.sh      ← Pre-deploy validation
    │   └── uninstall.sh            ← Helm uninstall + cleanup
    └── values/
        ├── examples/                                    ← Module sources (init-values.sh merges from here)
        │   ├── langsmith-values.yaml                    ← Base AWS values
        │   ├── langsmith-values-agent-deploys.yaml      ← Deployments feature
        │   ├── langsmith-values-fleet.yaml              ← Fleet and its required host-backend
        │   ├── langsmith-values-insights.yaml           ← Insights
        │   ├── langsmith-values-polly.yaml              ← LangSmith Chat (formerly Polly)
        │   ├── langsmith-values-engine.yaml             ← Engine (see ENGINE.md)
        │   ├── langsmith-values-sso.yaml                ← SSO login
        │   ├── langsmith-values-smithdb.yaml            ← SmithDB base
        │   ├── langsmith-values-ingress-envoy-gateway.yaml ← Envoy Gateway (Gateway API) reference
        │   ├── langsmith-values-dataplane.yaml          ← langgraph-dataplane chart (separate namespace)
        │   └── dataplane-rbac.yaml                      ← RBAC: host-backend read access to dataplane namespace
        ├── langsmith-values.yaml                        ← Base values (written by make init-values)
        ├── langsmith-values-overrides.yaml              ← Everything else, one file (written by make init-values)
        ├── langsmith-values-local.yaml                  ← Your own changes (optional, you write it)
        ├── langsmith-values-local.yaml.example          ← Template for the file above
        └── dataplane-rbac.yaml                          ← Active RBAC manifest (copy from examples/)
```

See [Helm values](#helm-values) for who writes each file and how to change a value.

---

## Configuration

Copy and populate the variables file:

```bash
cd terraform/aws/infra
cp terraform.tfvars.example terraform.tfvars  # if it exists
```

Minimum required variables:

```hcl
# Resource naming
name_prefix = "acme"       # your company/team prefix (max 11 chars)
environment = "prod"

# AWS region
region = "us-west-2"

# EKS
eks_cluster_version = "1.34"
eks_managed_node_groups = {
  default = {
    name           = "node-group-default"
    instance_types = ["m5.4xlarge"]
    min_size       = 3
    max_size       = 10
  }
}

# RDS PostgreSQL
postgres_password = "<strong-password>"   # or: export TF_VAR_postgres_password=...

# ElastiCache Redis
redis_auth_token = "<min-16-char-token>"  # or: export TF_VAR_redis_auth_token=...

# TLS — "acm" (default), "letsencrypt", or "none"
tls_certificate_source = "acm"
acm_certificate_arn    = "arn:aws:acm:us-west-2:<account-id>:certificate/<cert-id>"

# LangSmith domain (leave empty to use ALB DNS name)
langsmith_domain = "langsmith.<your-domain>"
```

### Route 53 hosted zone modes

When `langsmith_domain` is set and `acm_certificate_arn` is empty, Terraform
requests a DNS-validated ACM certificate and manages the DNS records for it.
The default, `dns_create_zone = true`, creates a public hosted zone exactly
matching `langsmith_domain`. Delegate the returned `dns_name_servers` from the
parent zone before enabling ACM-backed HTTPS.

To reuse an existing authoritative public Route 53 zone, pass the zone ID:

```hcl
langsmith_domain     = "langsmith.example.com"
dns_create_zone      = false
dns_existing_zone_id = "Z1ABCDEF123456"
```

The existing zone may be `langsmith.example.com` itself or a parent such as
`example.com`. Terraform writes the ACM validation CNAME and LangSmith ALB
alias record into that selected zone. The alias target continues to use the
ALB's canonical hosted zone ID. `dns_name_servers` is empty when a zone is
reused, and a private hosted zone cannot validate a public ACM certificate.

Reusing a zone does not import or manage the zone itself. If this stack already
created a dedicated zone, do not switch modes without separately planning the
DNS and Terraform state migration.

### Terraform state backend (recommended for production)

Configure `terraform/aws/infra/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket = "<your-terraform-state-bucket>"
    key    = "langsmith/aws/terraform.tfstate"
    region = "us-west-2"
  }
}
```

### Move an in-cluster PostgreSQL to RDS

From 0.18 the module always creates RDS, and `postgres_source = "in-cluster"` fails at
plan. Move the data before the first 0.18 apply. That apply points the
`langsmith-postgres` Secret at a new, empty RDS instance, and it removes the keys that
the in-cluster PostgreSQL pod needs to start again. Writes made after the dump are not
copied, so stop using LangSmith until the move is done. The commands use the default
namespace and release name, `langsmith`.

1. Dump the in-cluster database to your machine. The password stays inside the pod:

   ```bash
   kubectl exec -n langsmith langsmith-postgres-0 -c postgres -- \
     sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
     > langsmith.dump
   ```

2. Remove `postgres_source = "in-cluster"` from `infra/terraform.tfvars`, then run
   `make apply`. It creates the RDS instance.
3. Restore the dump before `make deploy`, which runs the LangSmith database migrations.
   RDS is reachable only from inside the VPC, so restore from a pod that reads the new
   connection URL from the Secret. Save this as `pg-restore.yaml`, with the image at
   your RDS engine version:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pg-restore
     namespace: langsmith
   spec:
     restartPolicy: Never
     containers:
       - name: pg-restore
         image: postgres:18
         command: ["sleep", "3600"]
         env:
           - name: DATABASE_URL
             valueFrom:
               secretKeyRef:
                 name: langsmith-postgres
                 key: connection_url
   ```

   Then copy the dump into the pod and restore it:

   ```bash
   kubectl apply -f pg-restore.yaml
   kubectl wait -n langsmith --for=condition=Ready pod/pg-restore --timeout=180s
   kubectl cp langsmith.dump langsmith/pg-restore:/tmp/langsmith.dump
   kubectl exec -n langsmith pg-restore -- \
     sh -c 'pg_restore --no-owner --no-privileges -d "$DATABASE_URL" /tmp/langsmith.dump'
   kubectl delete pod -n langsmith pg-restore
   ```

4. Run `make init-values` and `make deploy`. The deploy removes the in-cluster
   PostgreSQL StatefulSet and keeps its volume.
5. When LangSmith shows your organizations, projects, and datasets, delete the old
   volume. This cannot be undone, so keep `langsmith.dump` until you no longer need it:

   ```bash
   kubectl delete pvc -n langsmith data-langsmith-postgres-0
   ```

### Move an in-cluster Redis to ElastiCache

From 0.18 the module always creates ElastiCache, and `redis_source = "in-cluster"`
fails at plan. Redis holds LangSmith's queues and caches, so there is no data to copy.
But runs that LangSmith accepted and has not processed yet wait in the in-cluster
queue, and the first 0.18 apply points LangSmith at a new, empty ElastiCache instance.
Runs still in the old queue are not processed.

1. Stop sending traces, and wait until the last ones show in LangSmith.
2. Remove `redis_source = "in-cluster"` from `infra/terraform.tfvars`, then run
   `make apply`. It creates the ElastiCache instance.
3. Run `make init-values` and `make deploy`. The deploy removes the in-cluster Redis.

### Move Fleet, Chat or Insights data to RDS

From 0.18 Fleet, LangSmith Chat and Insights always use their own database on the
shared RDS instance (`langsmith_fleet`, `langsmith_polly`, `langsmith_insights`) and
their own DB index on the shared ElastiCache (1, 2 and 3). Engine uses the Insights
storage. `fleet_storage`, `polly_storage` or `insights_storage = "in-cluster"` fails
at plan while that add-on is on (for `insights_storage`, Insights or Engine).
`enable_standalone_polly` and `enable_standalone_insights` always fail at plan, and
`make deploy` stops on them too: replace them with `enable_polly = true`,
`polly_storage = "external"`, `enable_insights = true` and
`insights_storage = "external"`.

The first 0.18 deploy points each feature at its new, empty database, so move the data
before it. The steps use Chat (`polly`); for Fleet or Insights, put `fleet` or
`insights` in its place. Redis holds only each feature's job queue, so there is no data
to copy there. But writes made after the dump are not copied, and jobs still in the
in-cluster queue are not run, so stop using the feature until the move is done.

1. Dump the in-cluster database to your machine:

   ```bash
   kubectl exec -n langsmith langsmith-standalone-polly-postgres-0 -c postgres -- \
     sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
     > polly.dump
   ```

2. Set `polly_storage = "external"` in `infra/terraform.tfvars`, then run `make apply`.
   It creates the `langsmith_polly` database and the `langsmith-polly-postgres` Secret.
   `make deploy` stops on a release that keeps the feature in the cluster until this
   line says `external`. It also stops when the line is missing, because 0.17 read an
   unset `polly_storage` or `insights_storage` as `in-cluster`.
3. Restore the dump with the `pg-restore.yaml` pod from
   [Move an in-cluster PostgreSQL to RDS](#move-an-in-cluster-postgresql-to-rds), with
   the Secret `name: langsmith-polly-postgres` and `key: postgres_connection_url`.
4. Run `make init-values` and `make deploy`. The deploy removes the in-cluster
   StatefulSets and keeps their volumes.
5. When the feature shows its data, delete the old volumes. This cannot be undone:

   ```bash
   kubectl delete pvc -n langsmith data-langsmith-standalone-polly-postgres-0 data-langsmith-standalone-polly-redis-0
   ```

---

## Pod networking

By default each pod gets an IP address from its node's subnet, so the private
subnets must hold an address for every pod as well as every node. To move pods
onto dedicated pod subnets instead (VPC CNI custom networking), set:

```hcl
eks_network_mode = "custom-networking"
eks_pod_cidr     = "100.64.0.0/16"   # default; create_vpc = true only
```

With `create_vpc = true`, Terraform adds `eks_pod_cidr` to the VPC as a
secondary CIDR and splits it into one pod subnet per AZ (a /18 each from the
default /16). The pod subnets carry only local routes. Traffic from a pod to a
destination outside the VPC leaves with the node's IP address through the
private subnet's NAT route.

With `create_vpc = false`, create the pod subnets yourself and pass their IDs:

```hcl
eks_network_mode   = "custom-networking"
eks_pod_subnet_ids = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]
```

Supply one pod subnet per AZ in `vpc_id`, covering every AZ that
`private_subnets` and `public_subnets` are in. The plan fails if two pod
subnets share an AZ, a pod subnet is in another VPC, or a cluster AZ has no
pod subnet.

Pod IPs stay routable VPC addresses, so the ALB still targets pods directly.
Terraform adds the pod CIDRs to the ingress rules on the RDS and ElastiCache
security groups and to the ALB's ingress and egress rules, so in-cluster
callers still reach an ALB restricted by `alb_allowed_cidr_blocks`. It configures the `vpc-cni`
add-on with one ENIConfig per AZ and holds node group creation for two minutes
after the cluster is active, so the add-on is configured before the first
nodes join. It merges any `eks_addons["vpc-cni"]` configuration you supply
into that add-on.

Choose the mode at cluster creation. Switching an existing cluster changes the
add-on configuration only: nodes that joined before the switch keep their pod
IPs in the node subnets until you replace them. If the cluster already sets
`eks_addons["vpc-cni"]`, move that add-on's state before the first apply in
the new mode, or the apply tries to create a second `vpc-cni` add-on next to
the existing one:

```bash
terraform state mv \
  'module.eks.module.eks_blueprints_addons.aws_eks_addon.this["vpc-cni"]' \
  'module.eks.module.eks.aws_eks_addon.before_compute["vpc-cni"]'
```

Switching back to `node-subnet` does not turn custom networking off. Terraform
removes the add-on with `preserve = true`, so the CNI keeps its custom
networking settings. Treat the mode as fixed for the life of the cluster.

---

## Bring your own security groups

By default, every module that needs one creates a dedicated security group: ALB,
bastion, RDS PostgreSQL, ElastiCache Redis, and (when `enable_smithdb = true`) the
SmithDB metastore RDS instance. If your network team requires a pre-approved
security group instead, for example one that already carries a compliance tag
set or a mandated egress policy, supply its ID and Terraform skips creating its
own:

```hcl
alb_existing_security_group_id               = "sg-0123456789abcdef0"
bastion_existing_security_group_id           = "sg-0123456789abcdef1"
postgres_existing_security_group_id          = "sg-0123456789abcdef2"
redis_existing_security_group_id             = "sg-0123456789abcdef3"
smithdb_metastore_existing_security_group_id = "sg-0123456789abcdef4"
```

Each is independent: supply one, some, or all of them. Leave a variable unset
(the default) and that component keeps creating its own security group as before.

### Attach-only: Terraform does not manage rules on a supplied group

For every component above, a supplied security group is **attach-only**. Terraform
associates it with the resource but never writes an ingress or egress rule onto
it. The group must already allow what that component needs before you apply.
With `eks_network_mode = "custom-networking"`, every "VPC CIDR" rule in the
table also needs the pod CIDRs (`eks_pod_cidr`, or the CIDRs of
`eks_pod_subnet_ids`):

| Component | Your security group must allow |
|-----------|-------------------------------|
| ALB | Inbound tcp/80, and tcp/443 unless `tls_certificate_source = "none"`, from `alb_allowed_cidr_blocks` and, with custom networking, the pod CIDRs. Outbound to the VPC CIDR (to reach EKS pod IPs, target-type: ip) |
| Bastion | Outbound to `0.0.0.0/0` (SSM agent, package installs, kubectl/helm/aws-cli). If you also set `bastion_enable_ssh = true`, inbound tcp/22 from `bastion_ssh_allowed_cidrs`; Terraform will **not** add this rule for a supplied group, so add it yourself first |
| Postgres (RDS) | Inbound tcp/5432 from within the VPC CIDR. Outbound within the VPC CIDR. With `sandbox_runtime_source = "external"`, admit the LangSmith node security group (and the bastion's) instead of the VPC CIDR, which also contains the sandbox nodes |
| Redis (ElastiCache) | Inbound tcp/6379 from within the VPC CIDR. Outbound within the VPC CIDR. With an external sandbox runtime, the same narrowing as Postgres |
| SmithDB metastore (RDS) | See below. This one component can have its ingress rule managed by Terraform |

### The one exception: SmithDB's metastore security group

The SmithDB metastore's required ingress rule allows tcp/5432 from the **EKS node
security group**, an ID that doesn't exist until the `eks` module creates it in
the same `apply`. You can't look that ID up and pre-provision the rule yourself
before running Terraform. So this one case has an opt-in escape hatch:

```hcl
smithdb_metastore_existing_security_group_id           = "sg-0123456789abcdef4"
smithdb_metastore_manage_existing_security_group_rules = true   # default: false
```

Leave `smithdb_metastore_manage_existing_security_group_rules` at its default (`false`) and the supplied group is attach-only, same as everywhere else, but then you're responsible for adding tcp/5432 ingress from the EKS node security group yourself (`module.eks.node_security_group_id` after a first apply, or from the EKS console) before SmithDB pods can reach the metastore.
Set it to `true` and Terraform adds that ingress rule to your security group.
`terraform destroy` removes the rule.
Manual teardown without Terraform state leaves the rule in place; see [Teardown](#teardown) / `TEARDOWN.md` for removal instructions.

Before 0.18 these two settings were `smithdb_existing_metastore_security_group_id` and `smithdb_manage_byo_security_group_rules`.
The old names fail at plan, so rename them in `infra/terraform.tfvars` before the first 0.18 apply.

### What Terraform does not check

Unlike the [Azure bring-your-own-VNet path](../azure/README.md#bring-your-own-vnet),
plan-time validation here is minimal: Terraform does not verify that a supplied
security group ID exists, belongs to the target VPC, or actually permits the
traffic in the table above. A typo or a group with the wrong rules fails at
`apply` (wrong VPC) or shows up later as a connectivity failure (missing rule),
not as a clear plan-time error. Double-check the ID and its rules before applying.

---

## Pass 1 — Infrastructure

Provisions: VPC, EKS cluster, RDS PostgreSQL, ElastiCache Redis, S3 bucket + VPC endpoint, ALB, IRSA role, ESO IRSA role, SSM secrets.

```bash
cd terraform/aws

# Generate terraform.tfvars interactively (re-run safe — Enter accepts current values):
make quickstart

# Create and populate secrets in SSM Parameter Store
# (must be sourced — Make can't do this; run `make setup-env` for the exact command)
source infra/scripts/setup-env.sh

# Check secret status and confirm TF_VAR_* are exported
make secrets

# Deploy infrastructure
make init
make plan
make apply
```

> **Duration:** ~20–25 minutes. EKS cluster creation takes 12–15 minutes. RDS takes additional 5–8 minutes. Do not interrupt.

### After apply — get cluster credentials

```bash
make kubeconfig

kubectl get nodes
kubectl get ns
kubectl get pods -n kube-system
```

### Optional dedicated sandbox cluster

`enable_sandboxes = true` uses the main EKS cluster by default. To isolate the privileged Firecracker runtime, select the dedicated-cluster topology:

```hcl
enable_sandboxes        = true
sandbox_runtime_source = "external"
sandbox_namespace       = "langsmith-sandbox"

langsmith_helm_chart_version = "0.18.0" # exact, 0.18 or later
```

An external sandbox runtime needs chart 0.18 or later, pinned to one exact version: the default 0.17 line has no separate-cluster support, and the runtime chart is paired with that exact chart (see [Versions](#versions)). `terraform plan` and `make deploy` both reject anything else.

Terraform then creates a second EKS cluster in the same VPC and private subnets, with only the KVM-capable sandbox node group. Around it, Terraform creates:

- an IRSA role that trusts exactly one ServiceAccount, `system:serviceaccount:<sandbox_namespace>:<sandbox_service_account_name>`, with S3 access to the JuiceFS prefix of the trace bucket and nothing else: `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` and `s3:AbortMultipartUpload` on `<bucket>/<sandbox_juicefs_name>/*`, and `s3:ListBucket` for that prefix only;
- the network rules below;
- two write-only Secrets in the sandbox namespace: the runtime Secret and the JuiceFS config (volume name, metadata URL, bucket).

The S3 bucket and the dedicated `noeviction` ElastiCache metadata store remain shared infrastructure in the VPC.

#### Network

- **TCP 19190 into the sandbox nodes** comes from two sources only, both named by security group: the LangSmith cluster's node security group (where `platform-backend` and `ingest-queue` run; pod ENIs carry the same group, with custom networking too) and the sandbox nodes themselves, which forward ingress requests, dial sandbox links and send live-migration streams to each other on that port. Nothing else opens 19190.
- **That hop is plain HTTP** and carries sandbox commands, files and credentials. This example keeps it inside the VPC. If the two clusters are in different networks, or the traffic would leave a network you trust, enable the runtime chart's host ingress with TLS (`sandboxHost.ingress` in `langsmith-sandbox`) and set its `https://` origin as `sandboxes.external.hostIngressEndpoint` in the LangSmith values instead of widening 19190.
- **Sandbox nodes reach the LangSmith API** at the runtime chart's `config.endpoint` (`<config.hostname>[/<basePath>]/api`) through the ALB. With `alb_scheme = "internal"` Terraform adds an ALB rule for the sandbox node security group. With an internet-facing ALB the call leaves through the NAT gateway, so a narrowed `alb_allowed_cidr_blocks` must admit the NAT address (see `sandbox_alb_allow_nat_egress` in `terraform.tfvars.example`); `terraform plan` fails otherwise. With `alb_existing_security_group_id`, Terraform writes no rules on your group: allow the `sandbox_node_security_group_id` output on the ALB's ports yourself. With `create_firewall = true`, `langsmith_domain` is added to the allowed FQDNs.
- **Sandbox nodes reach Redis and S3** inside the VPC: the JuiceFS Redis admits the VPC CIDR, and S3 goes through the VPC gateway endpoint.
- **Sandbox nodes cannot reach the LangSmith Postgres or Redis.** The sandbox nodes share the private subnets, so in this mode the RDS and ElastiCache security groups admit the LangSmith node security group (which pod ENIs carry, with custom networking too) and the bastion's, not the VPC CIDR. Other clients in the VPC lose access to those databases in this mode. If one needs them, supply your own groups with `postgres_existing_security_group_id` and `redis_existing_security_group_id`; Terraform writes no rules on those, so keep the sandbox nodes out of them.

#### Secrets

The runtime Secret (`sandbox_runtime_secret_name`, default `langsmith-sandbox-runtime`) holds exactly two keys, the `langsmith-sandbox` chart's defaults. Never copy the whole `langsmith-config` Secret into the sandbox cluster.

| Key | Value |
|-----|-------|
| `sandbox_service_auth_secret` | A dedicated sandbox service-auth secret, identical to `sandbox_service_auth_secret` in `langsmith-config`. It is never the API key salt: `api_key_salt` also signs LangSmith's own service calls, and the sandbox cluster runs untrusted code. |
| `sandbox_callback_signing_jwk` | The callback-signing JWK, identical to the one in `langsmith-config`. |

With `sandbox_runtime_source = "external"`, `setup-env.sh` generates the service-auth secret (64 hex characters) into the SSM parameter `sandbox-service-auth-secret`, `apply-eso.sh` syncs it into `langsmith-config` as `sandbox_service_auth_secret`, and `init-values.sh` sets `sandboxes.serviceAuth.secretKey: sandbox_service_auth_secret` in the LangSmith values. The in-cluster runtime creates none of this and keeps the chart default, `api_key_salt`.

Terraform writes both runtime keys from `TF_VAR_sandbox_service_auth_secret` and `TF_VAR_sandbox_callback_signing_jwk` (exported by `source infra/scripts/setup-env.sh`) as write-only values, so neither is stored in state. `terraform plan` fails if the service-auth secret is missing, shorter than 32 characters, or equal to the API key salt.

Write-only values reach the cluster only when `sandbox_runtime_secret_revision` changes, so after changing either value, increment it and re-apply. Both releases read these values only at startup, so a new value takes effect when the LangSmith pods and `sandbox-host` restart on it together; sandboxes fail while the two sides disagree.

A sandbox cluster applied with an earlier version of this module holds the API key salt under `sandbox_service_auth_secret`. To move it to the dedicated secret: run `source infra/scripts/setup-env.sh` (it creates the SSM parameter), increment `sandbox_runtime_secret_revision`, run `make apply`, `make init-values` and `make deploy`, then restart `sandbox-host` in the sandbox cluster:

```bash
kubectl --kubeconfig ~/.kube/langsmith-<sandbox cluster name> -n <sandbox_namespace> \
  rollout restart deployment -l app=sandbox-host
```

`make deploy` restarts the LangSmith pods because their service-auth key changes, but `sandbox-host` picks up the rewritten Secret only when it restarts.

#### Versions

Each LangSmith install runs the `langsmith-sandbox` chart whose appVersion equals the `langsmith` chart's. `make deploy` reads the appVersion of the pinned `langsmith` chart, installs the newest `langsmith-sandbox` chart with the same appVersion, and leaves `images.sandboxHostImage.tag` empty so the image follows that appVersion. If no runtime chart matches, it stops before changing either release. To check by hand:

```bash
APP=$(helm show chart langchain/langsmith --version 0.18.0 | awk '/^appVersion:/{print $2}' | tr -d '"')
helm search repo langchain/langsmith-sandbox --versions --devel -o json \
  | jq -r --arg a "$APP" '[.[] | select(.app_version == $a)][0].version // error("no langsmith-sandbox chart for appVersion \($a)")'
```

#### One runtime per install

Run exactly one `langsmith-sandbox` release per LangSmith install, and only while the LangSmith release uses `sandboxes.external.enabled: true`. LangSmith accepts host reports from one runtime at a time and refuses any other: a refused runtime's hosts never join, and its elected `sandbox-host` pod turns not ready. Do not install the runtime chart by hand next to the one `make deploy` manages, and do not point a second LangSmith install at this sandbox cluster.

To move an existing install from the in-cluster runtime, change `sandbox_runtime_source`, run `source infra/scripts/setup-env.sh` again (it creates the dedicated service-auth secret), then run `make apply`, `make init-values` and `make deploy`. `make apply` creates the sandbox cluster and removes the in-cluster sandbox node group. `make deploy` copies the in-cluster runtime's proxy CA (`smithbox-proxy-ca`) into the sandbox namespace, so Sandboxes that resume from saved memory keep their auth proxy credential injection; then it switches the LangSmith release to `sandboxes.external.enabled` (removing the embedded runtime) and to the dedicated service-auth secret, and installs the runtime chart against the same JuiceFS metadata store and bucket, so both sides start on the new secret together. LangSmith accepts the new runtime about 6 minutes after the embedded hosts stop reporting, so its host can stay not ready until then. Running sandboxes stop during the move and start again on the new hosts when used.

To move back to the in-cluster runtime, or turn Sandboxes off: this direction is not tested end to end yet. Before you change `sandbox_runtime_source` or `enable_sandboxes`, remove the three objects Terraform keeps in the sandbox cluster from state. They go when the cluster is deleted:

```bash
terraform -chdir=infra state rm 'kubernetes_secret_v1.sandbox_runtime[0]' 'kubernetes_secret_v1.sandbox_juicefs_config[0]' 'kubernetes_namespace_v1.sandbox[0]'
```

Without this, plan fails reaching `no-sandbox-cluster.invalid`. Once the sandbox cluster leaves the configuration, its Kubernetes provider points there, so it never falls back to your kubeconfig, where the in-cluster runtime's namespace has the same name.

#### Install, upgrade and uninstall order

- **Install:** `make apply`, then `make init-values`, then `make deploy`. `make init-values` writes both the LangSmith values and `helm/values/langsmith-sandbox-values-overrides.yaml`; `make deploy` installs `langsmith` first, then `langsmith-sandbox` in the sandbox cluster, and waits for `sandbox-host`.
- **Upgrade:** change `langsmith_helm_chart_version` and run `make deploy`. It upgrades `langsmith` first and the runtime right after, to the matching chart. If you upgrade with other tools, keep that order and upgrade the runtime within days.
- **Uninstall:** `make uninstall` removes the `langsmith-sandbox` release from the sandbox cluster first, then the LangSmith release; then empty the trace bucket, which also holds the JuiceFS data, and run `make destroy` ([TEARDOWN.md](TEARDOWN.md), A5). Without Terraform outputs, uninstall the runtime release from the sandbox cluster yourself before running `make uninstall`.
- **Status:** `make status` also checks the sandbox cluster: the `langsmith-sandbox` release, that its appVersion matches the `langsmith` release, and the runtime pods.

`make deploy`, `make uninstall` and `make status` reach the sandbox cluster through their own kubeconfig file, `~/.kube/langsmith-<sandbox cluster name>`, so your current context is unchanged.

The sandbox IRSA role trusts exactly one ServiceAccount, named by `sandbox_service_account_name` (default `sandbox-host`). `init-values.sh` writes the same name into `sandboxHost.serviceAccount.name` and the role into `workloadIdentity.aws.roleArn` in the generated values, so the two always agree. Renaming the ServiceAccount only in the values file breaks IRSA and leaves `sandbox-host` unable to reach the bucket — change the tfvar and re-run `make init-values` instead.

---

## Pass 2 — LangSmith Application

### Fast Path — Single Command Deploy

If `source infra/scripts/setup-env.sh` and `make quickstart` have already been run, you can chain all of Pass 1 and Pass 2 in one command:

```bash
# Interactive (prompts for terraform apply confirmation)
make quickdeploy

# Non-interactive (auto-approves terraform apply)
make quickdeploy-auto
```

`make quickdeploy` gates on secrets being loaded and `terraform.tfvars` existing, then runs: `terraform apply` → `kubeconfig` → `init-values` → `helm deploy` in sequence. If any step fails it exits with instructions to retry that step individually.

```bash
cd terraform/aws

make init-values       # reads admin email and addons from Terraform
make deploy            # deploy LangSmith via Helm (includes ESO wiring)
```

`init-values.sh` reads the `enable_*` flags from `terraform.tfvars` and the Terraform outputs, then writes `helm/values/langsmith-values.yaml` and `helm/values/langsmith-values-overrides.yaml`. Each run writes both files again; your own changes go in `helm/values/langsmith-values-local.yaml` (see [Helm values](#helm-values)).

Every install runs one sizing, the scale guide's medium reads, medium writes pattern: the base values run the frontend at 2 replicas, the backend on an HPA from 8 to 16, and KEDA for `queue`, `ingest-queue`, and the SmithDB compaction worker. Requests stay at the chart's defaults. Cluster Autoscaler adds LangSmith nodes up to the node group's `max_size`, and on `m6a.2xlarge` nodes the sizing needs up to 8 at maximum replicas. See [SIZING.md](helm/values/examples/SIZING.md) to size beyond it, or to move from a 0.17 `sizing_profile`.

---

## Helm values

`make deploy` applies two values files, and nothing else except the sandbox-host image tag. AWS, Azure, and GCP use the same two file names.

| File in `helm/values/` | Written by | Holds |
| --- | --- | --- |
| `langsmith-values.yaml` | `make init-values`, on every run | A copy of `examples/langsmith-values.yaml`: the base AWS values and the one sizing |
| `langsmith-values-overrides.yaml` | `make init-values`, on every run | Everything else, merged into one file: the Terraform outputs, each enabled feature, SSO, SmithDB, and your local file |
| `langsmith-values-local.yaml` | You. No script writes it | Your own changes. Optional. Start from `langsmith-values-local.yaml.example` |

The values files hold no secrets. ESO syncs the secrets from SSM into the `langsmith-config` Secret, and the chart reads them from it.

### Change a value

1) Put the change in `helm/values/langsmith-values-local.yaml`. `make init-values` merges this file last, so a key in it wins over every other source.
2) Run `make init-values`, then `make deploy`.

Do not edit the two generated files. Line 1 of each holds a sha256 of the rest of the file, so `make init-values` and `make deploy` find a hand edit. `make init-values` then prints the edit and writes nothing.

Some values come from `terraform.tfvars`, and `make init-values` sets them after every file, so the local file cannot change them: `polly.enabled`, `insights.enabled`, `hostBackend.enabled` while Fleet is on, the storage of Fleet, Chat, and Insights, and the SmithDB tier and caches. Change the `enable_*` flags and the SmithDB inputs in `terraform.tfvars` instead. The header of `langsmith-values-overrides.yaml` lists these settings, the sources in merge order, and the inputs of the file.

### What `make deploy` checks

Before it touches the cluster, `make deploy` stops when:

- a values file is missing, or was edited after `make init-values` wrote it;
- `terraform.tfvars`, an example file, a module script, or the local file changed after `make init-values` wrote the overrides file;
- the gateway mode or SmithDB, as Terraform applied them, differ from the file;
- a values file from the 0.17 layout is still in `helm/values` (see [Move from the 0.17 values layout](#move-from-the-017-values-layout)).

Each message names the fix. In most cases it is `make init-values`.

### Use the rendered files in your own CI/CD

The two files are complete Helm values. A pipeline can apply them without `deploy.sh`:

1) Run `make init-values` in the pipeline, after `terraform apply`, so the files match the Terraform state. It needs `helm`, `terraform`, and read access to the state.
2) Keep the two files as build artifacts. Do not commit them to this repository: `.gitignore` excludes them.
3) Apply them with the chart version that `deploy.sh` pins:

```bash
helm upgrade --install langsmith langchain/langsmith \
  --namespace langsmith --version <chart-version> \
  -f helm/values/langsmith-values.yaml \
  -f helm/values/langsmith-values-overrides.yaml \
  --set-string images.sandboxHostImage.tag=<chart-appVersion>   # only with enable_sandboxes = true
```

`deploy.sh` also does work that the values do not hold: it applies the ESO `ExternalSecret` (`make apply-eso`), checks the SSO and storage cutovers, and refreshes the hostname from the ALB. A pipeline that skips `deploy.sh` must do those steps, or run `make apply-eso` first. With Helm 4, add `--server-side=false` (see [`make deploy`](#make-deploy), Step 8).

### Move from the 0.17 values layout

The 0.17 layout kept one file per feature in `helm/values`. From 0.18, `make init-values` and `make deploy` stop while one of those files is still there, because a deploy no longer applies them. The message lists each file and marks it:

| Mark | Meaning |
| --- | --- |
| `same as examples/<file>` | The file holds no change of yours. |
| `differs from examples/<file>` | The file can hold your changes. |
| `no example of this name` | The file can hold your changes, for example a 0.17 sizing profile. |
| `written by make init-values on 0.17` | The 0.17 overrides file. Check it for changes you made by hand. |

1) For each file marked `differs`, `no example`, or `written by make init-values on 0.17`, compare it with its example, for example `diff -u helm/values/examples/langsmith-values-fleet.yaml helm/values/langsmith-values-fleet.yaml`.
2) Copy each change you made into `helm/values/langsmith-values-local.yaml`. Do not copy values that `make init-values` writes from Terraform, such as the hostname, the IRSA roles, and the bucket names. For a 0.17 `langsmith-values-sizing-*.yaml`, see [SIZING.md](helm/values/examples/SIZING.md), "Moving from a 0.17 sizing profile".
3) Move the old files out of `helm/values`. The message prints the command, for example:

```bash
mkdir -p ~/langsmith-values-0.17
(cd helm/values && mv langsmith-values-fleet.yaml langsmith-values-sizing-production.yaml ~/langsmith-values-0.17/)
```

4) Run `make init-values`. To confirm the result, render the chart with the old files and with the new ones, and compare:

```bash
helm template langsmith langchain/langsmith --version <chart-version> \
  -f ~/langsmith-values-0.17/<base> -f ~/langsmith-values-0.17/<overrides> -f ~/langsmith-values-0.17/<feature> > /tmp/old.yaml
helm template langsmith langchain/langsmith --version <chart-version> \
  -f helm/values/langsmith-values.yaml -f helm/values/langsmith-values-overrides.yaml > /tmp/new.yaml
diff /tmp/old.yaml /tmp/new.yaml
```

5) Run `make deploy`.

---

## Envoy Gateway (Gateway API)

Envoy Gateway is the default ingress mode, both in Terraform and in `make quickstart` for new deployments. When rerun, quickstart keeps your existing ingress selection. Set `enable_envoy_gateway = false` to fall back to a standard ALB-backed Kubernetes Ingress.

`enable_envoy_gateway` is unset by default and derived rather than hardcoded to `true`:

| `terraform.tfvars` | Result |
| --- | --- |
| No gateway flags at all | Envoy Gateway |
| `enable_istio_gateway = true` | That controller, Envoy stays off |
| `enable_envoy_gateway` set explicitly | Your value always wins |

Enabling two controllers is rejected at plan time by a precondition in `infra/main.tf`, because all gateway modes share a single ALB target group and only one port can be health-checked on it.

When enabled, the `k8s-bootstrap` module:
1. Installs the Envoy Gateway Helm chart (`envoyproxy/gateway-helm` v1.3.0) in the `envoy-gateway-system` namespace.
2. Creates a `GatewayClass` named `eg` and a `Gateway` named `langsmith-gateway` in the `langsmith` namespace.

The LangSmith Helm chart then creates an `HTTPRoute` (not an `Ingress`) pointing to `langsmith-frontend`.

### Why Envoy Gateway?

- Required for multi-namespace dataplane deployments — HTTPRoutes in different namespaces can attach to a shared Gateway using `ReferenceGrants`, without modifying the shared Gateway resource.
- Envoy Gateway is the recommended ingress for environments running the `langgraph-dataplane` chart in a separate namespace.

### Enable

```hcl
# infra/terraform.tfvars
enable_envoy_gateway = true
```

Then apply and deploy:

```bash
source infra/scripts/setup-env.sh
make apply

# init-values.sh writes the Gateway values (ingress off, gateway on)
make init-values
make deploy
```

### TLS with ACM

Set `tls_certificate_source = "acm"` and `acm_certificate_arn` in `terraform.tfvars`. The `deploy.sh` script annotates the Envoy Gateway NLB service with the ACM certificate ARN automatically. TLS is terminated at the NLB — Envoy sees plain HTTP internally.

Traffic flow:
```
Client → NLB:443 (ACM TLS termination) → Envoy proxy:80 → HTTPRoute → langsmith-frontend:80
```

### Dataplane RBAC

When running the `langgraph-dataplane` chart in a separate namespace (e.g. `langsmith-agents`), apply the RBAC manifest once per dataplane namespace to allow `langsmith-host-backend` to read pods and logs:

```bash
kubectl apply -f helm/values/dataplane-rbac.yaml
```

The manifest grants the `langsmith-host-backend` ServiceAccount (in the `langsmith` namespace) read access to pods, pod logs, deployments, and ReplicaSets in the `langsmith-agents` namespace. Without this, agent run logs will not stream in the LangSmith UI.

### Moving off NGINX ingress

0.18 removed `enable_nginx_ingress`. Four checks stop an upgrade that would delete a running NGINX controller, or route traffic away from it, and leave LangSmith unreachable:

- `enable_nginx_ingress = true` in `terraform.tfvars` fails at plan, however Terraform runs. The `false` that earlier QuickStart runs wrote still plans.
- `make apply` and `make quickdeploy` refuse while the Terraform state still holds the NGINX controller, even when `terraform.tfvars` no longer mentions it (`infra/scripts/upgrade-guard.sh`).
- `make init-values` and `make deploy` stop while the last apply still ran NGINX, so the Helm steps cannot write or apply routing for a mode Terraform has not built.
- `make quickstart` in update mode stops on a `terraform.tfvars` that sets `enable_nginx_ingress = true`, instead of preselecting ALB.

To move off NGINX, keep the previous release and switch there: choose Envoy Gateway, Istio, or ALB, then run `make apply`, `make init-values`, and `make deploy` back to back. LangSmith is unreachable from the apply until the deploy finishes. Envoy Gateway and Istio keep the Terraform ALB and its hostname. ALB mode moves traffic to an ALB that the AWS Load Balancer Controller owns, so point DNS at its hostname. Upgrade after the deploy finishes.

---

## Private Cluster with Bastion Host

For customers who require a fully private EKS cluster (`enable_public_eks_cluster = false`), the EKS API endpoint is only reachable from within the VPC. A bastion host provides the access point.

### How it works

1. **First run from your workstation** — Deploy infrastructure with `create_bastion = true` and `enable_public_eks_cluster = true` (temporarily). This creates the bastion alongside everything else.
2. **Switch to private** — Set `enable_public_eks_cluster = false` and re-apply. The EKS API endpoint becomes private-only.
3. **All future work happens on the bastion** — SSM into the bastion, clone the repo, copy your `terraform.tfvars` and secrets, and run Pass 1/2 from there.

### Setup

```hcl
# terraform.tfvars
enable_public_eks_cluster = false   # private API endpoint
create_bastion            = true    # bastion for access

# Optional SSH (SSM is the default — no key needed):
# bastion_key_name          = "my-keypair"
# bastion_enable_ssh        = true
# bastion_ssh_allowed_cidrs = ["203.0.113.0/24"]
```

### Connect via SSM Session Manager

```bash
# After terraform apply, the SSM command is in the outputs:
terraform output bastion_ssm_command

# Or connect directly:
aws ssm start-session --target <instance-id> --region us-west-2
```

> **Prerequisite:** Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for the AWS CLI.

### Working from the bastion

The bastion comes pre-installed with kubectl, helm, terraform, git, and jq. Kubeconfig is pre-configured for the EKS cluster.

```bash
# After SSM-ing in:
kubectl get nodes                        # verify cluster access
git clone <your-repo-url>                # get the deployment code
cd ps-control-plane/terraform/aws

# Copy your terraform.tfvars and secrets, then run normally:
source infra/scripts/setup-env.sh
make plan
make apply
make deploy
```

### Important notes

- The bastion's IAM role has `AmazonSSMManagedInstanceCore` attached, plus an inline policy that allows `eks:DescribeCluster` and `eks:ListClusters`. Add additional policies if you need the bastion to manage other AWS resources.
- The bastion lives in a **public subnet** (for SSM agent connectivity). It does not need a public IP if your VPC has VPC endpoints for SSM (`ssm`, `ssmmessages`, `ec2messages`).
- When the EKS API is private, `terraform plan/apply` targeting EKS resources **must** be run from within the VPC (i.e., the bastion). Running from your laptop will timeout.

---

### Verify and get endpoint

```bash
kubectl get pods -n langsmith
kubectl get ingress -n langsmith
```

---

## Command Glossary

All commands are run from `terraform/aws/`. Run `make help` for a quick summary.

---

### `make quickstart`

**When to use:** First time setting up a new deployment, or any time you want to update `terraform.tfvars`. During updates, the wizard keeps the existing name prefix, environment, and AWS region unchanged because they identify the deployment and its SSM secrets. It also keeps the custom domain unchanged because changing it requires a guided DNS and certificate migration. Other prompts pre-select their current values.

Runs `infra/scripts/quickstart.sh` — an interactive wizard that asks you questions (name prefix, region, TLS method, external vs in-cluster services, add-ons) and writes a ready-to-use `infra/terraform.tfvars` file. Each menu marks the current or default option and accepts Enter to confirm it, so re-runs are fast. Saves you from editing the example file by hand.

```bash
make quickstart
```

---

### `make setup-env`

**When to use:** Before `make plan` or `make apply` on a fresh shell.

Prints the `source` command you need to run. It cannot export environment variables itself because `make` runs each target in a subshell — variables set there die when the shell exits. You must source the script directly:

```bash
source infra/scripts/setup-env.sh
```

**What `setup-env.sh` actually does:**

Builds the SSM path prefix from `terraform.tfvars`: `/langsmith/{name_prefix}-{environment}/`

For each secret it follows this priority order:

1. SSM Parameter Store — read and decrypt it; a read error stops setup
2. Exported shell value (`TF_VAR_*` or `LANGSMITH_*`) — import it only if SSM confirms the parameter is missing
3. No value in any source — generate it where supported, otherwise prompt
4. No terminal (CI) and an input is still required — stop with instructions to supply it

SSM is the persistent credential store. Setup exports each resolved credential to the shell without creating or refreshing local password backup files. Existing SSM values replace shell values. Legacy local password files are never read or updated and are left untouched. If SSM is missing a credential and its legacy backup path exists, setup stops before generating or saving a replacement. Import the existing credential into SSM with `infra/scripts/manage-ssm.sh`, then rerun setup. Once verified in SSM, legacy files can be deleted. Setup never overwrites an existing SSM parameter. Use `infra/scripts/manage-ssm.sh` for intentional SSM changes.

**Changed setup requirements:** SSM read/decryption access is required even when the shell already contains credentials. SSM write failures, empty credentials, and concurrent parameter creation stop setup. Existing SSM names, shell variables, and generation methods are unchanged. Terraform state, generated Helm files, and private temporary files can still contain credentials; this change removes separate setup password backups, not every local copy.

**SSM parameters it manages (`/langsmith/{name_prefix}-{environment}/`):**

| SSM key | How it's set | Notes |
|---|---|---|
| `postgres-password` | Auto-generated (`openssl rand -hex 32`) | RDS master password. Hex avoids RDS-forbidden `/ @ " ' space`. An initial value can come from `TF_VAR_postgres_password` when SSM is missing. |
| `redis-auth-token` | Auto-generated (`openssl rand -hex 32`) | ElastiCache requires hex, not base64 |
| `sandbox-juicefs-redis-auth-token` | Auto-generated (`openssl rand -hex 32`) | Created only when Sandboxes are enabled |
| `sandbox-callback-signing-jwk` | Auto-generated (Ed25519 private JWK) | Created only when Sandboxes are enabled |
| `langsmith-api-key-salt` | Auto-generated (`openssl rand -base64 32`) | **Never change** — invalidates all API keys |
| `langsmith-jwt-secret` | Auto-generated (`openssl rand -base64 32`) | **Never change** — invalidates all sessions |
| `langsmith-license-key` | You enter it | From your LangChain account |
| `langsmith-admin-password` | You enter it | Min 12 chars; must include a lowercase letter, an uppercase letter, and a symbol (`!#$%()+,-./:?@[\]^_{~}`) |
| `deployments-encryption-key` | Auto-generated (Fernet key) | For Deployments/LangGraph Platform feature |
| `agent-builder-encryption-key` | Auto-generated (Fernet key) | For Fleet; historical key name retained for compatibility |
| `insights-encryption-key` | Auto-generated (Fernet key) | For Insights feature |
| `polly-encryption-key` | Auto-generated (Fernet key) | For LangSmith Chat (formerly Polly) |
| `engine-encryption-key` | Auto-generated (Fernet key) | For Engine. Keep it stable. See [ENGINE.md](ENGINE.md) |
| `engine-usage-signing-secret` | Auto-generated (`openssl rand -hex 32`) | For Engine usage reports. Keep it stable |
| `sandbox-service-auth-secret` | Auto-generated (`openssl rand -hex 32`), only with `sandbox_runtime_source = "external"` | Signs calls between LangSmith and the separate sandbox cluster in place of the API key salt. Keep it stable; see [Secrets](#secrets) |

Fernet keys are: `openssl rand -base64 32 | tr "+/" "-_"` (URL-safe base64, as required by the LangGraph platform).

After running, you'll see a summary of all values (masked) and the SSM prefix. Terraform then reads the secrets as `TF_VAR_*` variables during `plan` / `apply`.

If an apply updates `langsmith-postgres` or the Fleet/Polly/Insights Postgres secrets (for example after password URL-encoding), restart every deployment in the Helm release so its pods load the new `connection_url`:

```bash
kubectl rollout restart deployment -n langsmith -l "app.kubernetes.io/instance=langsmith"
```

Running `./helm/scripts/deploy.sh` alone is not enough because it explicitly restarts only the frontend. Terraform recreates a failed `langsmith-standalone-*-db-init` Job when the encoded admin URL changes. The Job skips `CREATE DATABASE` when the database already exists.

> **Why SSM?** Secrets are never in git or `.tfvars`. ESO reads them from SSM at runtime and syncs them into the `langsmith-config` Kubernetes Secret that the Helm chart mounts.

---

### `make init`

**When to use:** First time, or after adding/upgrading a Terraform provider or module.

Runs `terraform -chdir=infra init`. Downloads all required providers (`hashicorp/aws`, `hashicorp/kubernetes`, `hashicorp/helm`, etc.) and modules (the EKS Blueprints module, VPC module, etc.) into `infra/.terraform/`. Configures the state backend defined in `backend.tf`.

Safe to re-run at any time — it's idempotent.

---

### `make plan`

**When to use:** Before every `make apply` to review what will change.

Runs `terraform -chdir=infra plan`. Compares your `.tf` files + `terraform.tfvars` + `TF_VAR_*` env vars against the current Terraform state file. Shows a diff: what will be created, changed, or destroyed.

**Nothing is created or modified.** The plan output is the single most important thing to review before applying — especially `destroy` actions.

> Requires `TF_VAR_postgres_password`, `TF_VAR_redis_auth_token`, and other secrets to be set in the environment (via `source infra/scripts/setup-env.sh`).

---

### `make apply`

**When to use:** To provision or update infrastructure.

Runs `terraform -chdir=infra apply`. Executes the plan — prompts for confirmation (`yes`) before making changes. Provisions resources in dependency order:

```
VPC + Subnets
  → Security Groups
  → EKS Cluster (~12 min)
    → Node Groups
    → k8s-bootstrap (KEDA, cert-manager, ESO, namespace, IRSA service accounts)
  → RDS PostgreSQL (~8 min, parallel with EKS)
  → ElastiCache Redis (parallel with EKS)
  → S3 Bucket + VPC Endpoint
  → ALB + Listeners
  → SSM Parameters
```

Resources with no dependencies are created in parallel. Total time: **~20–25 minutes**.

After apply, all outputs (cluster name, ALB DNS, S3 bucket, IRSA role ARN) are printed and stored in Terraform state. `init-values.sh` reads these outputs automatically.

---

### `make kubeconfig`

**When to use:** After `make apply` to configure `kubectl`, or when switching between deployments.

Prints the command to source `infra/scripts/set-kubeconfig.sh`, which writes the cluster credentials to `~/.kube/langsmith-<cluster>` and exports `KUBECONFIG` in your shell. `~/.kube/config` is left alone. Make runs in a subshell, so it can't export the variable for you.

```bash
source infra/scripts/set-kubeconfig.sh
kubectl get nodes   # verify
```

---

### `make ssm`

**When to use:** To view, update, or rotate secrets after the initial deployment.

Runs `infra/scripts/manage-ssm.sh` — a full-featured SSM secret manager for the deployment. Run it without arguments for an interactive menu, or pass a subcommand directly.

```bash
make ssm                                                # interactive menu
./infra/scripts/manage-ssm.sh list                     # show all params + last-modified date
./infra/scripts/manage-ssm.sh get langsmith-license-key
./infra/scripts/manage-ssm.sh set langsmith-admin-password 'NewP@ss!'
./infra/scripts/manage-ssm.sh validate                 # check all required params exist
./infra/scripts/manage-ssm.sh diff                     # compare SSM vs K8s secret (detects drift)
./infra/scripts/manage-ssm.sh delete <key>
```

**Subcommands:**

| Subcommand | What it does |
|---|---|
| `list` | Shows all parameters under the prefix with last-modified timestamps |
| `get <key>` | Decrypts and prints a single parameter value |
| `set <key> <value>` | Updates a parameter — validates format (e.g. admin password must contain a symbol); warns on stable secrets (`api-key-salt`, `jwt-secret`) |
| `validate` | Checks all required params exist and are non-empty; reports optional params |
| `diff` | Compares SSM values vs what's in the live `langsmith-config` K8s Secret — shows mismatches and how to force an ESO resync |
| `delete <key>` | Removes a parameter — requires double confirmation for stable secrets |

> After updating a secret with `set`, ESO syncs it to Kubernetes within 1 hour. To force an immediate sync:
> ```bash
> kubectl annotate externalsecret langsmith-config -n langsmith force-sync=$(date +%s) --overwrite
> ```

---

### `make init-values`

**When to use:** After `make apply`, or any time you change `terraform.tfvars` settings (addons, domain).

Runs `helm/scripts/init-values.sh`. This script is the bridge between Pass 1 and Pass 2:

1. Reads settings from `infra/terraform.tfvars` (`name_prefix`, `tls_certificate_source`, `enable_*` flags, `langsmith_domain`)
2. Reads live outputs from Terraform state (`bucket_name`, `langsmith_irsa_role_arn`, `alb_dns_name`, `acm_certificate_arn`, and the SmithDB and sandbox outputs)
3. Copies `helm/values/examples/langsmith-values.yaml` to `helm/values/langsmith-values.yaml`
4. Merges into `helm/values/langsmith-values-overrides.yaml`, in this order: the values from the Terraform outputs (hostname, IRSA role ARNs, S3 bucket, ACM cert ARN), then the example of each enabled feature, then SSO and SmithDB, then `langsmith-values-local.yaml`:
   - `enable_deployments = true` → `langsmith-values-agent-deploys.yaml`
   - `enable_engine = true` → `langsmith-values-engine.yaml`, and the Engine IRSA role annotation
   - `enable_insights = true` → `langsmith-values-insights.yaml`
   - `enable_polly = true` → `langsmith-values-polly.yaml`
   - `enable_fleet = true` → `langsmith-values-fleet.yaml`
   - `enable_sso_oidc = true` → `langsmith-values-sso.yaml`
   - `enable_smithdb = true` → `langsmith-values-smithdb.yaml`, and the SmithDB bucket, role, and cache from Terraform

Re-running is safe: each run writes both files again from the same inputs, and keeps your admin email. When a generated file was edited by hand, the run stops, prints the edit, and writes nothing. See [Helm values](#helm-values).

---

### `make deploy`

**When to use:** To deploy or upgrade LangSmith after `make init-values`.

Runs `helm/scripts/deploy.sh`. This is the main Helm orchestration script. Here is the exact sequence:

**Step 1 — Kubeconfig.** Reads `cluster_name` from `terraform output` and runs `aws eks update-kubeconfig` into `~/.kube/langsmith-<cluster>`, the file `set-kubeconfig.sh` writes. `~/.kube/config` is left alone; the script prints the `export KUBECONFIG=...` line for your shell when it finishes.

**Step 2 — Preflight checks** (`preflight-check.sh`). Confirms `aws`, `kubectl`, `helm`, `terraform` are installed; validates AWS credentials with `aws sts get-caller-identity`; verifies `kubectl` can reach the cluster; adds the `langchain` Helm repo if missing.

**Step 3 — ESO sync** (`apply-eso.sh`). Applies the `ClusterSecretStore` (points ESO at SSM in your region) and the `ExternalSecret` (defines which SSM paths map to which K8s secret keys). Dynamically includes optional encryption keys only if they already exist in SSM — so addon keys are only synced when the addon is enabled. Waits 60s for the sync to complete.

**Step 4 — Read feature flags.** Reads the `enable_*` flags from `terraform.tfvars`. Fleet enables host-backend directly; it does not require the listener, operator, or full LangSmith Deployments. Fleet, LangSmith Chat and Insights keep their data on the shared RDS and ElastiCache.

**Step 5 — Check the values files.** Applies exactly two files:
```
-f langsmith-values.yaml             (the base values)
-f langsmith-values-overrides.yaml   (everything else, merged by make init-values)
```
Before that, it stops when a file is missing or was edited by hand, when an input of the overrides file changed after `make init-values`, or while a 0.17 values file is left in `helm/values`. See [What `make deploy` checks](#what-make-deploy-checks).

**Step 6 — Pre-deploy hostname check.** If the ingress already exists and `langsmith_domain` is not set, compares `config.hostname` in the overrides file against the live ALB hostname. Auto-updates it if stale (prevents agent deployments getting stuck in `DEPLOYING` state with the wrong endpoint URL).

**Step 7 — Broken release recovery.** Checks the current Helm release status. If `pending-upgrade` (left by a Ctrl+C'd upgrade), rolls back automatically. If `failed` (common after a first deploy timeout), logs a warning and proceeds — Helm upgrade works fine on a failed release.

**Step 8 — Helm upgrade.** Runs `helm upgrade --install`, adding `--server-side=false` only when the installed Helm is 4.x. Server-side apply is a Helm 4 feature and its default for a fresh install, and it conflicts with the AWS Load Balancer Controller over ownership of `ingress.spec.rules`, so the deploy asks for client-side apply. Helm 3 has no such flag and applies client-side regardless, so the flag is omitted there. Does **not** use `--wait` because the chart's post-install hooks and the operator's agent pods can take 10+ minutes to settle on new nodes.

**Step 9 — Core readiness.** Polls each core deployment with `kubectl rollout status --timeout=5m`:
- `langsmith-frontend`, `langsmith-backend`, `langsmith-platform-backend`, `langsmith-ingest-queue`, `langsmith-queue`
- Plus `langsmith-host-backend` if Fleet or Deployments is enabled
- Plus `langsmith-listener` and `langsmith-operator` if Deployments is enabled

**Step 10 — IRSA annotation for `langsmith-ksa`.** The `langsmith-ksa` service account is created by the operator at runtime (not part of the Helm release). It's used by all operator-spawned agent deployment pods. After every deploy, `deploy.sh` ensures this SA exists and carries the IRSA role ARN annotation — without it, new agent pod revisions can't access S3/SSM and stay unschedulable.

**Step 11 — Frontend restart.** Restarts the frontend deployment to pick up the latest ConfigMap. Then prints the ALB hostname and port-forward instructions.

---

### `make apply-eso`

**When to use:** When SSM secrets change but you don't need to redeploy Helm.

Runs `helm/scripts/apply-eso.sh`. Re-applies just the ESO `ClusterSecretStore` and `ExternalSecret` resources and waits for the sync to complete (60s timeout). Useful for rotating credentials (license key, admin password) without triggering a full Helm upgrade.

**What it creates/updates in Kubernetes:**

1. `ClusterSecretStore langsmith-ssm` — a cluster-wide ESO provider pointing at AWS SSM Parameter Store in your region. Uses the IRSA role on the ESO pod for authentication.

2. `ExternalSecret langsmith-config` (in the langsmith namespace) — maps SSM paths to K8s secret keys:

   | SSM path | K8s secret key |
   |---|---|
   | `.../langsmith-license-key` | `langsmith_license_key` |
   | `.../langsmith-api-key-salt` | `api_key_salt` |
   | `.../langsmith-jwt-secret` | `jwt_secret` |
   | `.../langsmith-admin-password` | `initial_org_admin_password` |
   | `.../sandbox-callback-signing-jwk` | `sandbox_callback_signing_jwk` *(only with `enable_sandboxes = true`)* |
   | `.../sandbox-service-auth-secret` | `sandbox_service_auth_secret` *(only with `sandbox_runtime_source = "external"`)* |
   | `.../agent-builder-encryption-key` | `agent_builder_encryption_key` *(only if key exists in SSM)* |
   | `.../insights-encryption-key` | `insights_encryption_key` *(only if key exists in SSM)* |
   | `.../deployments-encryption-key` | `deployments_encryption_key` *(only if key exists in SSM)* |
   | `.../polly-encryption-key` | `polly_encryption_key` *(only if key exists in SSM)* |
   | `.../engine-encryption-key` | `engine_encryption_key` *(only if key exists in SSM)* |
   | `.../engine-usage-signing-secret` | `engine_usage_signing_secret` *(only if key exists in SSM)* |
   | `.../engine-encryption-key-previous` | `engine_encryption_key_previous` *(only if key exists in SSM; Engine key rotation, see [ENGINE.md](ENGINE.md#keys))* |

The optional keys are dynamically included — `apply-eso.sh` probes SSM for each one and only adds it to the ExternalSecret if it exists. This prevents ESO from failing to sync because a disabled addon's key isn't in SSM yet.

---

### `make sso`

**When to use:** Once the install works with password login and the org admin can log in, to switch to SSO through any OIDC provider (Entra ID, Okta, Auth0, Google Workspace, etc.).

**One-way:** LangSmith does not support moving a self-hosted install from SSO back to password login.

Runs `helm/scripts/sso.sh`. It stops with a clear message at the first check that fails, and changes `terraform.tfvars` only after all checks pass:

1. Reads `name_prefix`, `environment`, and `region`, and requires the deployed hostname in `langsmith-values-overrides.yaml` to use HTTPS; LangSmith SSO only works over HTTPS.
2. Checks AWS credentials, points kubectl at this deployment's cluster (as `deploy.sh` does), and checks the Helm release is deployed.
3. Asks you to confirm the org admin can log in, and that the same email exists in your identity provider.
4. Prints the redirect URI to register in your identity provider: `https://<host>/api/v1/oauth/custom-oidc/callback`.
5. Checks SSM for `oauth-client-id`, `oauth-client-secret`, and `oauth-issuer-url`, and asks for any that are missing (the secret is typed hidden).
6. Checks the issuer URL serves an OIDC discovery document.
7. Runs `apply-eso.sh` and checks `langsmith-config` has the three OIDC keys.
8. Sets `enable_sso_oidc = true` in `terraform.tfvars`, changing only that line.
9. Runs `make init-values`, which merges `langsmith-values-sso.yaml` into `langsmith-values-overrides.yaml` and keeps `langsmith-values-local.yaml`, then asks before running `make deploy`.

`deploy.sh` stops if SSO is already on in the cluster but `enable_sso_oidc` is not true, rather than deploying with password login.

---

### `make status`

**When to use:** At any point to check where you are in the deployment process.

Runs `infra/scripts/status.sh`. Works through 10 checks in sequence and tells you exactly what to run next. The first failing check sets the "Next Step" recommendation at the end.

```bash
make status          # full check
make status-quick    # skip SSM + K8s queries (faster, for quick credential checks)
```

**The 9 sections it checks:**

| # | Check | What it looks at |
|---|---|---|
| 1 | **terraform.tfvars** | File exists; `name_prefix`, `environment`, `region` are filled in |
| 2 | **Environment Variables** | All `TF_VAR_*` and `LANGSMITH_*` secrets are exported in your shell |
| 3 | **AWS Credentials** | `aws sts get-caller-identity` succeeds — prints account ID and ARN |
| 4 | **SSM Parameters** | All 6 required params exist; shows which optional addon keys are present |
| 5 | **Terraform Infra** | `terraform output` returns outputs — confirms `apply` has run; prints cluster name, ALB, bucket, IRSA role |
| 6 | **Kubeconfig** | `kubectl` context matches the cluster name; can reach the API server |
| 7 | **Helm Values** | both values files exist and are not edited by hand; no input changed since `make init-values`; no 0.17 values file is left; hostname is populated |
| 8 | **Kubernetes Resources** | Namespace exists; ESO `ClusterSecretStore` and `ExternalSecret` are deployed and synced; `langsmith-config` secret exists |
| 9 | **Helm Release** | Release status (`deployed`, `failed`, `pending-upgrade`); pod count |

---

### `make uninstall`

**When to use:** To remove the LangSmith Helm release (keeps infrastructure intact).

Runs `helm/scripts/uninstall.sh`. Uninstalls the `langsmith` Helm release and cleans up associated Kubernetes resources (ESO objects, service accounts). Does **not** destroy Terraform infrastructure (VPC, EKS, RDS, Redis, S3).

---

### `make deploy-all`

**When to use:** Single-command full deploy (infra already initialized).

Runs: `make apply` → `make init-values` → `make deploy` in sequence. Convenient for `terraform apply` + immediate Helm upgrade in one shot.

---

### `make quickdeploy`

**When to use:** Fastest path from a freshly sourced shell to a running LangSmith deployment.

Runs `infra/scripts/quickdeploy.sh`. Before doing anything it gates on two prerequisites:

1. `TF_VAR_langsmith_api_key_salt` is exported — confirms `source infra/scripts/setup-env.sh` has been run.
2. `infra/terraform.tfvars` exists — confirms `make quickstart` has been run.

If either gate fails it prints the exact command to fix and exits. If terraform is not yet initialized (`.terraform/` missing), it runs `terraform init` automatically.

Then chains 5 steps: `terraform apply` → `kubeconfig` → `init-values` → `helm deploy` → success banner with LangSmith URL.

Each step is individually fenced — if any step fails, the error message tells you exactly which `make` target to retry.

```bash
# Interactive (prompts for terraform apply confirmation)
make quickdeploy

# Non-interactive (auto-approves terraform apply — use in automation)
make quickdeploy-auto
```

---

### `make secrets`

**When to use:** To check the status of all SSM secrets and confirm `TF_VAR_*` vars are exported before running `make plan` or `make apply`.

Runs `infra/scripts/secrets-status.sh`. Queries SSM Parameter Store for each required parameter and prints a table showing `✓ SET` or `✗ MISSING` per entry. Then checks whether `TF_VAR_*` vars are exported in the current shell. Finally prints actionable next steps — either "run `source infra/scripts/setup-env.sh`" or "ready to run `make plan`".

```bash
make secrets          # standard output
make secrets          # re-run after sourcing setup-env.sh to confirm all green
```

Does not modify anything — read-only status check.

---

### `make secrets-list`

**When to use:** To see a raw list of all SSM parameter paths under your deployment prefix, with last-modified timestamps.

Runs `infra/scripts/manage-ssm.sh list`. Useful for confirming which parameters exist and when they were last rotated. For full CRUD operations use `make ssm` (interactive menu).

---

### `make preflight-post`

**When to use:** After `make apply` completes, before running `make init-values` or `make deploy`.

Runs `infra/scripts/preflight.sh --post-infra`. Checks:
- `kubectl` context is set and the cluster API is reachable
- All required SSM parameters exist in Parameter Store
- `helm/values/` directory contains the required values files
- TLS configuration is present (ACM ARN or Let's Encrypt email, depending on `tls_certificate_source`)

Useful as a sanity gate before Pass 2, especially when handing off to a colleague or running in a pipeline.

```bash
make apply
make preflight-post   # verify all post-infra conditions before proceeding
make init-values
make deploy
```

---

### `make preflight-ssm`

**When to use:** After `make setup-env` (or `source infra/scripts/setup-env.sh`) to quickly confirm all SSM parameters are populated before running `make plan`.

Runs `infra/scripts/preflight.sh --ssm-only`. Narrower scope than `make preflight-post` — checks SSM only, does not verify cluster access or values files.

```bash
source infra/scripts/setup-env.sh
make preflight-ssm    # confirm all params are in SSM before plan
make plan
```

---

## Supporting Scripts

These scripts are not exposed as `make` targets but are used internally by the scripts above.

### `infra/scripts/_common.sh`

Shared library sourced by scripts that need its shared helpers. Provides:
- `_parse_tfvar <key>` — extracts a value from `terraform.tfvars` using sed
- `_tfvar_is_true <key>` — returns 0 if a variable is set to `true` in tfvars
- `INFRA_DIR` — absolute path to `infra/`, resolved from the sourcing script's location
- Terminal color helpers: `_green`, `_red`, `_yellow`, `_bold`
- Status output helpers: `pass`, `fail`, `warn`, `skip`, `info`, `action`, `header` (used by `status.sh`)

### `infra/scripts/migrate-ssm.sh`

One-time operational script for moving SSM parameters from a legacy path to the standard path (`/langsmith/{name_prefix}-{environment}/`). Use this when an older deployment wrote secrets under a different prefix (for example, from the deprecated `modules/secrets` module).

```bash
# Dry run — show what would be copied without making changes
./infra/scripts/migrate-ssm.sh --old-prefix /old-prefix --dry-run

# Copy all params to the standard path
./infra/scripts/migrate-ssm.sh --old-prefix /old-prefix

# Copy and delete old params in one step
./infra/scripts/migrate-ssm.sh --old-prefix /old-prefix --delete-old
```

Reads `name_prefix`, `environment`, and `region` from `terraform.tfvars` to determine the target prefix. Skips params that already exist at the target with the same value; warns if the target has a different value (never overwrites silently). After a successful copy, prints the `kubectl annotate` command to force an immediate ESO resync.

To find the old prefix if you are not sure what it is:

```bash
aws ssm get-parameters-by-path --path / --recursive \
  --query 'Parameters[].Name' --output table | grep -i langsmith
```

### `helm/scripts/preflight-check.sh`

Called at the start of every `deploy.sh` run. Checks:
1. Required binaries exist: `aws`, `kubectl`, `helm`, `terraform`
2. AWS credentials work: `aws sts get-caller-identity`
3. Cluster is reachable: `kubectl cluster-info --request-timeout=5s`
4. `langchain` Helm repo is registered (adds it if missing, then updates)

Exits non-zero on any failure so `deploy.sh` aborts before touching the cluster.

### `infra/scripts/set-kubeconfig.sh`

Sourced, as `make kubeconfig` prints. Builds the cluster name from `name_prefix` and `environment` in `terraform.tfvars` and runs:
```bash
aws eks update-kubeconfig --name <cluster_name> --region <region> \
  --alias <cluster_name> --kubeconfig ~/.kube/langsmith-<cluster_name>
export KUBECONFIG=~/.kube/langsmith-<cluster_name>
```

---

## Variable Reference

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `name_prefix` | — | yes | Prefix for all resource names (1–11 chars, lowercase) |
| `environment` | `dev` | no | Environment: dev, staging, prod, test, uat |
| `region` | `us-west-2` | no | AWS region for all resources |
| `create_vpc` | `true` | no | Create a new VPC (set false to use existing) |
| `vpc_id` | `null` | when !create_vpc | Existing VPC ID |
| `private_subnets` | `[]` | when !create_vpc | Existing private subnet IDs |
| `public_subnets` | `[]` | when !create_vpc | Existing public subnet IDs |
| `vpc_cidr_block` | `null` | when !create_vpc | Existing VPC CIDR block |
| `enable_public_eks_cluster` | `true` | no | Enable public EKS API endpoint |
| `eks_public_access_cidrs` | `["0.0.0.0/0"]` | no | CIDRs allowed to reach the public EKS API endpoint |
| `eks_cluster_version` | `1.34` | no | EKS Kubernetes version |
| `eks_managed_node_group_defaults` | `{ami_type: AL2023}` | no | Default config for managed node groups |
| `eks_managed_node_groups` | `{default: m5.4xlarge}` | no | Managed node group definitions |
| `eks_network_mode` | `node-subnet` | no | `node-subnet` or `custom-networking` (pods on dedicated pod subnets). See [pod networking](#pod-networking) |
| `eks_pod_cidr` | `100.64.0.0/16` | no | Secondary VPC CIDR split into the pod subnets (custom networking with `create_vpc = true`) |
| `eks_pod_subnet_ids` | `[]` | when custom networking and !create_vpc | Existing pod subnet IDs, one per cluster AZ |
| `create_gp3_storage_class` | `true` | no | Create and set gp3 as default StorageClass |
| `eks_cluster_enabled_log_types` | `["api", "audit", ...]` | no | EKS control plane log types (CloudWatch) |
| `eks_addons` | `{}` | no | EKS managed add-on configurations |
| `create_langsmith_irsa_role` | `true` | no | Create IRSA role for LangSmith pods (S3 access) |
| `enable_sandboxes` | `false` | no | Provision sandbox-host nodes, dedicated JuiceFS Redis, and sandbox storage access |
| `sandbox_runtime_source` | `in-cluster` | no | `in-cluster` runs sandbox-host in the main EKS cluster; `external` creates a dedicated sandbox EKS cluster |
| `sandbox_namespace` | `langsmith-sandbox` | separate cluster | Namespace for the standalone sandbox runtime |
| `sandbox_service_account_name` | `sandbox-host` | no | ServiceAccount trusted by the sandbox IRSA role. `init-values.sh` writes it into `sandboxHost.serviceAccount.name`, so change it here rather than in the values file |
| `sandbox_runtime_secret_revision` | `1` | no | Increment to rewrite the write-only runtime Secret in the sandbox cluster |
| `sandbox_alb_allow_nat_egress` | `false` | no | Separate cluster with an internet-facing ALB: append the NAT gateway addresses to the ALB allowlist. Admits everything behind the NAT, sandboxes included; prefer an internal ALB |
| `sandbox_host_node_count` | `1` | when enabled | Fixed number of KVM-capable sandbox nodes |
| `sandbox_host_instance_types` | `["m5d.metal"]` | when enabled | KVM-capable EC2 instance types for sandbox-host |
| `langsmith_helm_chart_version` | `""` | separate cluster | Exact 0.17.x or 0.18.x chart version; empty deploys the latest 0.17.x. An external sandbox runtime requires an exact version on 0.18 or later |
| `postgres_source` | `external` | no | Only `external` (RDS) from 0.18; `in-cluster` fails at plan. See [Move an in-cluster PostgreSQL to RDS](#move-an-in-cluster-postgresql-to-rds) |
| `postgres_instance_type` | `db.t3.large` | no | RDS instance class |
| `postgres_storage_gb` | `10` | no | Initial RDS storage in GB |
| `postgres_max_storage_gb` | `100` | no | Maximum RDS storage in GB (autoscaling) |
| `postgres_username` | `langsmith` | no | RDS database username |
| `postgres_engine_version` | `18` | no | PostgreSQL engine version for RDS |
| `postgres_password` | `""` | when external | RDS password — use `TF_VAR_postgres_password` |
| `postgres_iam_database_authentication_enabled` | `true` | no | Enable IAM database authentication on RDS |
| `postgres_deletion_protection` | `true` | no | Enable deletion protection on RDS |
| `postgres_skip_final_snapshot` | `false` | no | Skip the final RDS snapshot during deletion; use `true` for disposable dev/test environments |
| `postgres_backup_retention_period` | `7` | no | Days to retain automated RDS backups (0 = disabled) |
| `postgres_existing_security_group_id` | `null` | no | Attach an existing SG to RDS instead of creating one. See [bring your own security groups](#bring-your-own-security-groups) |
| `redis_source` | `external` | no | Only `external` (ElastiCache, OSS mode) from 0.18; `in-cluster` fails at plan. See [Move an in-cluster Redis to ElastiCache](#move-an-in-cluster-redis-to-elasticache) |
| `redis_instance_type` | `cache.m6g.xlarge` | no | ElastiCache node type |
| `redis_auth_token` | `""` | when external | ElastiCache auth token (min 16 chars) — use `TF_VAR_redis_auth_token` |
| `redis_existing_security_group_id` | `null` | no | Attach an existing SG to ElastiCache instead of creating one. See [bring your own security groups](#bring-your-own-security-groups) |
| `s3_ttl_enabled` | `true` | no | Enable S3 lifecycle rules on the platform bucket for trace TTL (`ttl_s/`, `ttl_l/`) and the 1-day expiry of redaction raw values (`ttl_1d/`). When `false`, no lifecycle configuration is created: manage all rules yourself, including `ttl_1d/`. The SmithDB bucket never gets lifecycle rules. See [SMITHDB.md](SMITHDB.md#blob-storage) |
| `s3_ttl_short_days` | `14` | no | TTL for `ttl_s/` prefix in days |
| `s3_ttl_long_days` | `400` | no | TTL for `ttl_l/` prefix in days |
| `s3_kms_key_arn` | `""` | no | KMS CMK ARN for S3 encryption (empty = SSE-S3) |
| `s3_versioning_enabled` | `false` | no | Enable S3 bucket versioning |
| `tls_certificate_source` | `acm` | no | `acm`, `letsencrypt`, or `none` |
| `acm_certificate_arn` | `""` | when acm | ACM certificate ARN |
| `letsencrypt_email` | `""` | when letsencrypt | Email for Let's Encrypt |
| `langsmith_domain` | `""` | no | Custom hostname; activates managed DNS/ACM when no certificate ARN is supplied |
| `dns_create_zone` | `true` | no | Create a dedicated public Route 53 zone exactly matching `langsmith_domain` |
| `dns_existing_zone_id` | `""` | when reusing DNS | Existing public parent or same-name Route 53 zone ID |
| `dns_include_wildcard_san` | `false` | no | Add `*.langsmith_domain` to the managed ACM certificate |
| `langsmith_namespace` | `langsmith` | no | Kubernetes namespace for LangSmith |
| `clickhouse_source` | `in-cluster` | no | `in-cluster` or `external` |
| `alb_scheme` | `internet-facing` | no | ALB scheme: `internet-facing` or `internal` |
| `alb_access_logs_enabled` | `false` | no | Enable ALB access logging to S3 |
| `alb_existing_security_group_id` | `null` | no | Attach an existing SG to the ALB instead of creating one. See [bring your own security groups](#bring-your-own-security-groups) |
| `create_bastion` | `false` | no | Create EC2 bastion host for private cluster access (SSM or SSH) |
| `bastion_instance_type` | `t3.micro` | no | EC2 instance type for bastion |
| `bastion_key_name` | `null` | no | EC2 key pair for SSH (empty = SSM only) |
| `bastion_enable_ssh` | `false` | no | Open port 22 on bastion security group |
| `bastion_ssh_allowed_cidrs` | `[]` | no | CIDRs allowed to SSH to bastion |
| `bastion_root_volume_size_gb` | `20` | no | Root EBS volume size for bastion |
| `bastion_existing_security_group_id` | `null` | no | Attach an existing SG to the bastion instead of creating one. See [bring your own security groups](#bring-your-own-security-groups) |
| `create_cloudtrail` | `false` | no | Create CloudTrail trail for AWS API audit |
| `cloudtrail_multi_region` | `true` | no | Record API calls across all regions |
| `cloudtrail_log_retention_days` | `365` | no | Days to retain CloudTrail logs |
| `create_waf` | `false` | no | Attach WAFv2 Web ACL to ALB |
| `create_firewall` | `false` | no | Deploy AWS Network Firewall for FQDN-based egress filtering. Requires `create_vpc = true`. Cost: ~$0.395/hr/endpoint + $0.065/GB. |
| `firewall_allowed_fqdns` | `["beacon.langchain.com"]` | no | Domains allowed for outbound internet traffic when `create_firewall = true`. Matched against TLS SNI (HTTPS) and HTTP Host header. All other destinations are dropped. |
| `firewall_subnet_cidr` | `"10.0.64.0/21"` | no | CIDR for the firewall subnet. Must not overlap with private (10.0.0.0/21–10.0.32.0/21) or public (10.0.40.0/21–10.0.56.0/21) subnets. |
| `enable_deployments` | `false` | no | Enable LangSmith Deployments (listener, operator, host-backend) |
| `enable_fleet` | `false` | no | Enable Fleet and its required host-backend; full LangSmith Deployments is optional |
| `enable_insights` | `false` | no | Enable AI-powered trace analysis |
| `enable_polly` | `false` | no | Enable LangSmith Chat (formerly Polly); does not require `enable_deployments` |
| `enable_usage_telemetry` | `false` | no | Enable extended usage telemetry reporting |
| `enable_engine` | `false` | no | Enable Engine (chart 0.17+). Requires `enable_sandboxes`. Creates the Engine IRSA role with Amazon Bedrock Mantle access. See [ENGINE.md](ENGINE.md) |
| `engine_bedrock_policy_arn` | `""` | no | IAM policy for the Engine role. Empty uses the AWS managed policy `AmazonBedrockMantleInferenceAccess` in the current partition |
| `engine_sandbox_tenant_id` | `""` | when the shared organization has more than one workspace | Workspace ID that owns Engine's sandboxes |
| `engine_intelligence_base_url` | `""` | no | Empty keeps the chart default (usage reporting only). `https://beacon.aws.langchain.com/intelligence` runs Engine's models on LangSmith Intelligence |
| `enable_smithdb` | `true` | no | Provision SmithDB PostgreSQL, S3 (no TTL rules on it; compaction handles retention, see [SMITHDB.md](SMITHDB.md#blob-storage)), IRSA, a managed node group, and EBS caches. An install upgraded from 0.17 without SmithDB sets `false` first. See [SMITHDB.md](SMITHDB.md). |
| `smithdb_ingestion_enabled` | `true` | no | Write new runs to SmithDB. Counts only with `enable_smithdb = true` |
| `smithdb_query_enabled` | `true` | no | Serve reads from SmithDB. An install with traces in ClickHouse keeps it `false` until they are migrated |
| `smithdb_metastore_source` | `create` | no | Only `create` (dedicated RDS) from 0.18; `external` fails at plan. See [Move an external metastore to RDS](SMITHDB.md#move-an-external-metastore-to-rds) |
| `smithdb_metastore_engine_version` | `18` | no | PostgreSQL major version for the managed SmithDB metastore |
| `smithdb_metastore_existing_security_group_id` | `null` | no | Attach an existing SG to the metastore RDS instance instead of creating one. See [bring your own security groups](#bring-your-own-security-groups) |
| `smithdb_metastore_manage_existing_security_group_rules` | `false` | no | Let Terraform still write the required EKS-node ingress rule onto a supplied metastore SG. See [bring your own security groups](#bring-your-own-security-groups) |
| `smithdb_node_instance_type` | `m6a.4xlarge` | no | SmithDB instance type: `m6a.4xlarge` for the small tier that the Helm values run, `m6a.8xlarge` for medium, `m6a.16xlarge` for large. See [SMITHDB.md](SMITHDB.md#scaling-up) |
| `smithdb_cache_storage` | `network-disk` | no | SmithDB cache storage: `network-disk` (gp3 volumes) or `local-ssd` (the nodes' instance-store NVMe as RAID0, which needs a type such as `m6id.4xlarge`). See [SMITHDB.md](SMITHDB.md#local-ssd-cache) |
| `smithdb_node_min_count` | `2` | no | Minimum SmithDB nodes |
| `smithdb_node_max_count` | `5` | no | Maximum SmithDB nodes; must exceed the minimum |
| `smithdb_node_root_volume_size_gb` | `100` | no | SmithDB boot disk size in GiB |
| `langsmith_deployments_encryption_key` | `""` | no | Fernet key for LangSmith Deployments |
| `langsmith_agent_builder_encryption_key` | `""` | no | Fernet key for Fleet; historical variable name retained for compatibility |
| `langsmith_insights_encryption_key` | `""` | no | Fernet key for Insights |
| `langsmith_engine_encryption_key` | `""` | no | Fernet key for Engine. Set by `setup-env.sh` |
| `langsmith_engine_usage_signing_secret` | `""` | no | Engine usage signing secret, at least 32 characters. Set by `setup-env.sh` |
| `owner` | `""` | no | Owner tag applied to all resources |
| `cost_center` | `""` | no | Cost center tag for billing |
| `tags` | `{}` | no | Additional tags applied to all resources |

---

## Teardown

### Uninstall the Helm release

```bash
cd terraform/aws
make uninstall
```

### Destroy infrastructure

```bash
# Disable deletion protection first
# Set postgres_deletion_protection = false in infra/terraform.tfvars

cd terraform/aws/infra
terraform apply
terraform destroy

# After destroy succeeds, remove cloud secrets explicitly, then local files.
cd ..
make purge-secrets
make clean
```
