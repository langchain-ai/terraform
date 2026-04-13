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

- [x] **`setup-env.sh`: `_ssm_put_safe` tmpjson file not chmod'd** — `setup-env.sh:81` writes plaintext secret JSON to a `mktemp`-created file at default permissions (0644) before cleanup. The `.secret` local file path at line 201 is fixed (chmod 600 applied), but the tmpjson path is not. Fix: add `chmod 600 "$_tmpjson"` immediately after `mktemp` at line 81. (`setup-env.sh:81`)
- [x] **`manage-ssm.sh`: SSM delete swallows stderr** — `2>/dev/null` on `aws ssm delete-parameter` hides IAM, network, and throttling errors; user sees only "not found or could not be deleted". Fix: capture stderr and surface it (`manage-ssm.sh:244`)
- [x] **`manage-ssm.sh`: `_aws` wrapper not used** — all `aws` calls in `manage-ssm.sh` use bare `aws` instead of the `_aws()` wrapper from `_common.sh` that strips stale credential env vars. Operators using the hydrate-creds workflow get confusing auth failures. Fix: replace `aws ssm ...` with `_aws ssm ...` throughout `manage-ssm.sh`. (`manage-ssm.sh` throughout)
- [x] **`manage-ssm.sh`: credential failures misreported as "not found"** — `cmd_get` interprets any non-zero return from `_get_param` as "Parameter not found", including expired credentials and IAM errors. Fix: check the error message from SSM and surface the actual cause. (`manage-ssm.sh:163-167`)
- [ ] **`manage-ssm.sh`: secret value passed via CLI arg** — `--value "$val"` is visible in `ps aux` / `/proc/<pid>/cmdline`. `setup-env.sh` avoids this via `_ssm_put_safe` (JSON temp file). Fix: extract `_ssm_put_safe` to `_common.sh` and use it in `cmd_set` (`manage-ssm.sh:198`)
- [ ] **`quickstart.sh`: instance_types input not sanitized** — if any form or script generates tfvars by wrapping values in brackets (e.g. `"[m5.4xlarge]"` instead of `"m5.4xlarge"`), Terraform rejects the value with `Invalid value`. Fix: add bracket-strip sanitization in `_ask` for instance type fields, or validate that instance type values match `^[a-z][0-9a-z]+\.[0-9a-z]+$`. (`quickstart.sh` instance_types prompt)
- [ ] **`quickstart.sh`: input validation doesn't reject double-quote** — a user value containing `"` produces malformed HCL like `name_prefix = "my"value"`. Fix: add `"` to the rejection regex in `_ask` (`quickstart.sh:35`)
- [x] **`quickstart.sh`: Envoy next-steps missing NLB hostname guidance** — when no custom domain is configured, Envoy mode next-steps don't tell the user where to find the NLB/Gateway DNS name for the HTTPRoute `hostnames` field. User is left without guidance. Fix: add a note to the Envoy next-steps block pointing to `kubectl get gateway -n langsmith`. (`quickstart.sh` Envoy next-steps block)
- [x] **`quickstart.sh`: Envoy TLS menu not restricted** — Istio mode shows a restricted 2-option TLS menu (DNS-01 or None). Envoy mode falls through to the general menu and allows Let's Encrypt HTTP-01, which is untested behind Envoy's NLB. Fix: restrict Envoy to the same DNS-01 / None menu as Istio, or add HTTP-01 guidance to the Envoy next-steps. (`quickstart.sh` Section 7)
- [x] **`quickstart.sh`: ISTIO_NLB_SCHEME captured but never written** — Section 6 asks for Istio NLB scheme (internet-facing / internal) and stores in `$ISTIO_NLB_SCHEME` but never writes it to `terraform.tfvars`. The comment says to change it post-deploy via Helm values, but the user's answer is silently discarded. Fix: either write the variable or remove the question and add a note to next-steps. (`quickstart.sh` Section 6)
- [x] **`quickstart.sh`: ACM+Envoy/Istio guard fires after all 11 sections** — the pre-write guard correctly aborts on incompatible combos (ACM+Envoy, ACM+Istio) but only runs after the user completes the full questionnaire (~25 questions). Move the check to immediately after Sections 6+7 to fail faster. (`quickstart.sh` `_pre_write_guard`)
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

---

## Testing

### Shell Scripts

- [ ] **Add ShellCheck to CI** — run `shellcheck scripts/*.sh` on all shell scripts; fix existing warnings
- [ ] **Add Bats test suite for `setup-env.sh`** — cover: SSM write paths, auto-generation of `api_key_salt`/`jwt_secret`, `TF_VAR_*` export validation, idempotent re-runs, error on missing AWS credentials
- [ ] **Add Bats tests for `deploy.sh`** — cover: two-pass ALB hostname flow, ESO manifest apply, Helm upgrade invocation, values file generation
- [ ] **Add Bats tests for `manage-ssm.sh`** — cover: get/set/list/delete subcommands, prefix validation, missing-param error handling
- [ ] **Add Bats tests for `quickstart.sh`** — cover: input validation (reject `"`), tfvars generation, end-to-end non-interactive mode
- [ ] **Mock AWS CLI in Bats** — create `test/helpers/` with stub `aws` function returning canned SSM/STS responses; no real AWS calls in unit tests

### Terraform Modules

- [ ] **Add `terraform validate` + `tflint` CI step** — run against each module directory; add `.tflint.hcl` with AWS ruleset
- [ ] **Add native `terraform test` files for pure-logic modules** — start with `modules/vpc` (CIDR outputs), `modules/storage` (bucket naming, policy), `modules/secrets` (parameter paths); use `command = plan` to avoid real provisioning
- [ ] **Add Terratest integration suite** — Go tests that `apply`/`destroy` a minimal deployment (single-AZ, smallest instance types); validate: VPC connectivity, EKS cluster reachable, RDS accepts connections, S3 bucket accessible via IRSA
- [ ] **Add plan-level snapshot tests** — `terraform plan -out=plan.tfplan && terraform show -json plan.tfplan` diffed against a baseline; catches unintended resource changes on module edits
- [ ] **Document test strategy in `TESTING.md`** — which tests run locally vs CI, prerequisites (AWS sandbox account), how to add a test for a new module

---

## Deployment Audit Findings

Issues identified during the 2026-03-19 deployment audit. Items here don't block the happy path
(Option A scripts, external Postgres/Redis, ACM TLS) but affect edge cases and Option B.

### In-cluster mode

- [ ] **Base values hardcode `postgres.external.enabled: true`** — when `postgres_source = "in-cluster"`, `init-values.sh` writes an override to disable it, but manual file copy skips that. Also, `k8s-bootstrap` creates an empty `langsmith-postgres` K8s secret for in-cluster mode. Fix: either make the base values neutral or add a guard in `deploy.sh` that validates the override exists for in-cluster. (`langsmith-values.yaml:57-67`, `k8s-bootstrap/main.tf:23-43`, `init-values.sh:349-360`)

### App module (Option B)

- [x] **`kubernetes_manifest` for ESO CRDs fails at plan time on fresh cluster** — Fixed: switched `cluster_secret_store` and `external_secret` to `kubectl_manifest` (gavinbunney/kubectl ~> 1.14). This provider defers CRD schema validation to apply time, so `make plan-app` succeeds before ESO is installed. (`app/main.tf`, `app/versions.tf`)
- [ ] **Missing `fileexists()` preconditions for sizing/addon YAML files** — the precondition only checks for the base `langsmith-values.yaml`. If `sizing = "ha"` but the HA file doesn't exist, `file()` errors with a confusing message instead of the friendly precondition. Fix: add `fileexists()` checks for each conditional file. (`app/locals.tf:122`, `app/main.tf:206-211`)
- [x] **`langsmith_domain` not propagated to app module** — Fixed: added `langsmith_domain` output to `infra/outputs.tf`, variable to `app/variables.tf`, hostname resolution in `app/locals.tf` (`coalesce(var.hostname, var.langsmith_domain, local.alb_dns_name, "")`), and read+write in `pull-infra-outputs.sh`. (`infra/outputs.tf`, `app/variables.tf`, `app/locals.tf`, `app/scripts/pull-infra-outputs.sh`)

### Cosmetic / minor

- [ ] **Stale comment in base values example** — header references `langsmith-values-{env}.yaml` but the file is now `langsmith-values-overrides.yaml`. (`helm/values/examples/langsmith-values.yaml:14`)

