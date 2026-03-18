# AWS Backlog

Tracked gaps in the AWS LangSmith starter. Ordered by priority within each section.

---

## Security

### Critical

- [x] **Redis: no encryption at rest** — add `at_rest_encryption_enabled = true` to ElastiCache cluster (`modules/redis/main.tf`)
- [x] **Redis: no encryption in transit** — add `transit_encryption_enabled = true` (`modules/redis/main.tf`)
- [x] **Redis: no auth token** — any pod in the VPC can connect without credentials (`modules/redis/main.tf`)
- [x] **RDS: no storage encryption** — add `storage_encrypted = true` (`modules/postgres/main.tf`)
- [x] **S3: no server-side encryption** — add `aws_s3_bucket_server_side_encryption_configuration` (`modules/storage/main.tf`)
- [x] **S3: no public access block** — add `aws_s3_bucket_public_access_block` with all settings `true` (`modules/storage/main.tf`)
- [x] **S3: wildcard Principal `"*"` in bucket policy** — replace with specific service principals (`modules/storage/main.tf`)
- [ ] **Terraform state uses local backend** — state contains plaintext secrets; configure S3 remote backend with DynamoDB locking

### High

- [ ] **EKS public API endpoint defaults to `true`** — flip default to `false`; add optional bastion module (EC2 + SSM, no port 22) and document SSM port-forwarding as the standard access pattern; add `cluster_endpoint_public_access_cidrs` variable as a middle ground for temporary onboarding access (`variables.tf`, new `modules/bastion/`)
- [x] **IRSA trust policy missing `sub` condition** — any service account can assume the LangSmith role; scoped to `system:serviceaccount:${var.langsmith_namespace}:*` via `StringLike` (`modules/eks/main.tf`)
- [ ] **No VPC Flow Logs** — add `aws_flow_log` resource to VPC module
- [ ] **No CloudTrail** — no API-level audit trail; add CloudTrail logging to S3
- [ ] **ALB: no access logging** — enable `access_logs` on the ALB (`modules/alb/main.tf`)
- [ ] **ALB: no WAF association** — attach AWS WAF with rate limiting and managed rule groups
- [ ] **Secrets Manager: no rotation runbook** — `api_key_salt` and `jwt_secret` must never be rotated on a schedule (rotation invalidates all API keys and active sessions respectively); document an emergency rotation procedure for breach scenarios with explicit acknowledgment of consequences; `postgres_password` and `redis_auth_token` can be rotated but require coordinated app restart
- [ ] **RDS: missing `backup_retention_period`** — explicitly set (recommend ≥ 7 days) (`modules/postgres/main.tf`)
- [ ] **EKS: no control plane audit logging** — `api`, `audit`, and `authenticator` logs are not enabled on the EKS cluster; add `cluster_enabled_log_types` to the EKS module call in `main.tf`
- [ ] **RDS: no Multi-AZ** — single-AZ by default; AZ outage means database downtime with no auto-failover; add `multi_az = var.rds_multi_az` to `modules/postgres/main.tf`
- [ ] **PostgreSQL TLS not enforced in connection string** — application connection URL should include `?sslmode=require`; partially overlaps with custom parameter group item but must also be enforced at the app level

### Medium

- [ ] **No pod security standards on `langsmith` namespace** — add `pod-security.kubernetes.io/enforce: baseline` label; `restricted` is likely too strict for LangSmith components without image-level changes outside our control (`modules/k8s-bootstrap/main.tf`)
- [ ] **No Kubernetes network policies** — east-west traffic is unrestricted; deploy network policies with CNI
- [ ] **EKS envelope encryption not enabled** — enable `enable_cluster_encryption_config` to encrypt etcd secrets at rest
- [ ] **RDS: no CloudWatch log exports** — add `enabled_cloudwatch_logs_exports = ["postgresql"]` (`modules/postgres/main.tf`)
- [ ] **RDS: no enhanced monitoring** — add `monitoring_interval` and `monitoring_role_arn` (`modules/postgres/main.tf`)
- [ ] **Missing IAM permission boundaries** — add optional `iam_permissions_boundary_arn` variable (default empty); when set, attach to all created IAM roles (LangSmith IRSA, ESO, EBS CSI) to support enterprise orgs that cap role permissions centrally (`main.tf`, `modules/eks/main.tf`)
- [ ] **RDS: no custom parameter group** — enforce `ssl=1`, `log_connections=1`, `password_encryption=scram-sha-256`
- [ ] **Postgres engine version default is 14** — update default to 16 and enable auto minor version upgrades
- [ ] **Single NAT gateway** — cost-optimized default but single point of failure per AZ; evaluate enabling one NAT gateway per AZ for production deployments (`modules/vpc/main.tf`)

### Low

- [ ] **Redis resources missing tags** — add `tags` to all taggable resources (`modules/redis/main.tf`)
- [ ] **No password complexity validation** on sensitive variables like `postgres_password` (`variables.tf`)
- [ ] **Secrets Manager recovery window is 7 days** — increase to 30 for production (`modules/secrets/main.tf`)
- [ ] **Empty stub modules** — `modules/k8s-cluster/` and `modules/networking/` are empty; remove or document intent

---

## Observability

- [ ] **No CloudWatch Container Insights** — EKS node and pod metrics not collected; install `aws-cloudwatch-metrics` addon or enable via EKS add-ons API
- [ ] **No application-level metrics** — LangSmith pods expose Prometheus endpoints; no scrape config or CloudWatch metrics adapter deployed
- [ ] **No centralized log aggregation** — pod logs go nowhere by default; deploy Fluent Bit DaemonSet shipping to CloudWatch Logs; RDS PostgreSQL logs need `enabled_cloudwatch_logs_exports`
- [ ] **No alerting** — no CloudWatch Alarms or SNS topics for pod restarts, RDS CPU, ElastiCache evictions, or ALB 5xx rate
- [ ] **No uptime / synthetic monitoring** — no Route 53 health checks or external probes on the ALB endpoint

---

## Disaster Recovery

- [ ] **No RDS backup configuration documented** — `backup_retention_period` not set; no docs on restore procedure or RTO/RPO targets
- [ ] **No RDS snapshot automation** — add `backup_window`, `maintenance_window`, and optionally `aws_db_instance_automated_backups_replication` for cross-region DR
- [ ] **No S3 versioning** — enable versioning on the LangSmith bucket; trace payloads are not recoverable after accidental delete without it
- [ ] **No S3 cross-region replication** — for DR scenarios, replicate to a secondary region; add `aws_s3_bucket_replication_configuration`
- [ ] **No EBS snapshot policy** — ClickHouse data lives on an EBS-backed PVC; no AWS Data Lifecycle Manager policy for the node's EBS volumes
- [ ] **No cluster recovery runbook** — no documented procedure for rebuilding from scratch after full cluster loss (restore RDS from snapshot → restore S3 → re-run Pass 1 + Pass 2)
- [ ] **No multi-region failover design** — active-passive vs. active-active decision, DNS failover strategy, and data replication lag tolerance not documented

---

## Scaling

- [ ] **No HPA documentation** — LangSmith pods use HPA but Helm values are not documented in this repo; add recommended CPU/memory thresholds per component to `SERVICES.md`
- [ ] **No VPA configuration** — no Vertical Pod Autoscaler recommendations; useful for right-sizing ClickHouse and queue workloads
- [ ] **Cluster autoscaler not tuned** — default scale-down delay and unneeded threshold not documented; add recommended values for production
- [ ] **KEDA `ScaledObject` not documented** — `queue` and `ingest-queue` scale on Redis queue depth via KEDA but the thresholds are chart defaults; document recommended Redis trigger values for production load
- [ ] **No load testing baseline** — no documented methodology or target RPS/latency baselines; needed to validate cluster sizing before enterprise go-live
- [ ] **Node group: single instance type** — `m5.xlarge` only; ClickHouse benefits from memory-optimized instances; consider adding a second node group with `r5.xlarge` for stateful workloads

---

## Upgrades

- [ ] **No EKS version upgrade runbook** — no documented procedure for upgrading EKS (control plane first, then node groups); must handle managed node group rolling replacement and add-on version bumps
- [ ] **No RDS engine upgrade runbook** — `engine_version` is currently `14`; upgrading to 16 requires a planned maintenance window and schema compatibility verification
- [ ] **No Helm chart upgrade guide** — no documented process for upgrading the LangSmith chart version; needs: review changelog for breaking values changes, drain queue before upgrade, verify migration jobs complete
- [ ] **No add-on version pinning** — ALB controller, EBS CSI driver, cert-manager, KEDA, ESO versions are not pinned in Terraform; upstream chart updates can break deploys unexpectedly
- [ ] **No version compatibility matrix** — no documented table of: Helm chart version × EKS version × RDS engine version × Kubernetes API versions used

---

## Operations

- [ ] **No Helm values overlay documented** — `langsmith-values.yaml.example` exists but recommended overlays for production vs. light-deploy not documented
- [ ] **No cost optimization guidance** — no documented instance right-sizing, Reserved Instance recommendations, or Spot node group option for non-stateful pods
- [ ] **No IAM least-privilege review** — node group uses AWS managed policies; should be scoped to minimum required permissions for production
- [ ] **No tagging strategy** — resource tags are inconsistent across modules; needed for cost allocation, automation, and compliance tagging requirements
- [ ] **No `terraform.tfvars` validation** — no Terraform variable validation blocks to catch misconfigured values (wrong region format, invalid instance type) before `apply`
