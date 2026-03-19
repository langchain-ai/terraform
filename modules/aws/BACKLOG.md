# AWS Backlog

Tracked gaps in the AWS LangSmith starter. Ordered by priority within each section.

Items marked with **(opt-in)** have working implementations gated behind a variable default of `false`.

---

## Security

### Critical

- [ ] **Terraform state uses local backend** — state contains plaintext secrets; configure S3 remote backend with DynamoDB locking

### High

- [ ] **No VPC Flow Logs** — add `aws_flow_log` resource to VPC module
- [ ] **SSM Parameter Store: no rotation runbook** — document emergency rotation procedure for breach scenarios; `api_key_salt` and `jwt_secret` must never be rotated on a schedule; `postgres_password` and `redis_auth_token` can be rotated with coordinated app restart
- [ ] **RDS: no Multi-AZ** — single-AZ by default; add `multi_az = var.rds_multi_az` to `modules/postgres/main.tf`
- [ ] **PostgreSQL TLS not enforced in connection string** — app connection URL should include `?sslmode=require`
- [ ] **EKS: no control plane audit logging enabled by default** — log types are wired in via variable but verify the default is actually applied on fresh deploys

### Medium

- [ ] **No pod security standards on `langsmith` namespace** — add `pod-security.kubernetes.io/enforce: baseline` label (`modules/k8s-bootstrap/main.tf`)
- [ ] **No Kubernetes network policies** — east-west traffic is unrestricted
- [ ] **EKS envelope encryption not enabled** — encrypt etcd secrets at rest via `encryption_config`
- [ ] **RDS: no CloudWatch log exports** — add `enabled_cloudwatch_logs_exports = ["postgresql"]`
- [ ] **RDS: no enhanced monitoring** — add `monitoring_interval` and `monitoring_role_arn`
- [ ] **Missing IAM permission boundaries** — add optional `iam_permissions_boundary_arn` variable for enterprise orgs
- [ ] **RDS: no custom parameter group** — enforce `ssl=1`, `log_connections=1`, `password_encryption=scram-sha-256`
- [ ] **Postgres engine version default is 14** — update default to 16 and enable auto minor version upgrades
- [ ] **Single NAT gateway** — hardcoded `single_nat_gateway = true`; add variable for production multi-AZ NAT

### Low

- [ ] **Redis resources missing tags** — add `tags` to all taggable resources in `modules/redis/main.tf`

---

## Observability

- [ ] **No CloudWatch Container Insights** — install `aws-cloudwatch-metrics` addon or enable via EKS add-ons API
- [ ] **No application-level metrics** — LangSmith pods expose Prometheus endpoints; no scrape config deployed
- [ ] **No centralized log aggregation** — deploy Fluent Bit DaemonSet shipping to CloudWatch Logs
- [ ] **No alerting** — no CloudWatch Alarms or SNS topics for pod restarts, RDS CPU, ElastiCache evictions, ALB 5xx
- [ ] **No uptime / synthetic monitoring** — no Route 53 health checks or external probes

---

## Disaster Recovery

- [ ] **No RDS snapshot automation** — add `backup_window`, `maintenance_window`, and optionally cross-region replication
- [ ] **No S3 versioning enabled by default** — implementation exists but `var.s3_versioning_enabled` defaults to `false`; enable for production
- [ ] **No S3 cross-region replication** — for DR scenarios, replicate to a secondary region
- [ ] **No EBS snapshot policy** — ClickHouse PVC has no Data Lifecycle Manager policy
- [ ] **No cluster recovery runbook** — no documented procedure for full rebuild from backups
- [ ] **No multi-region failover design** — active-passive vs. active-active not documented

---

## Scaling

- [ ] **No HPA documentation** — document recommended CPU/memory thresholds per component
- [ ] **No VPA configuration** — useful for right-sizing ClickHouse and queue workloads
- [ ] **Cluster autoscaler not tuned** — default thresholds not documented for production
- [ ] **KEDA `ScaledObject` not documented** — document recommended Redis trigger values for production load
- [ ] **No load testing baseline** — no documented RPS/latency targets for go-live validation
- [ ] **Node group: single instance type** — ClickHouse benefits from memory-optimized instances (`r5.xlarge`)

---

## Upgrades

- [ ] **No EKS version upgrade runbook** — control plane → node groups → add-on version bumps
- [ ] **No RDS engine upgrade runbook** — engine version 14 → 16 requires maintenance window + schema verification
- [ ] **No Helm chart upgrade guide** — review changelog, drain queue, verify migration jobs
- [ ] **No add-on version pinning** — ALB controller, EBS CSI, cert-manager, KEDA, ESO versions not pinned
- [ ] **No version compatibility matrix** — Helm chart × EKS × RDS engine × K8s API versions

---

## Operations

- [ ] **No cost optimization guidance** — instance right-sizing, Reserved Instance recommendations, Spot for non-stateful pods
- [ ] **No IAM least-privilege review** — node group uses AWS managed policies; scope to minimum required
- [ ] **No tagging strategy** — tags inconsistent across modules; needed for cost allocation and compliance
- [ ] **No `terraform.tfvars` validation** — add variable validation blocks for region format, instance types, etc.

