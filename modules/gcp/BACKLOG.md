# GCP Backlog

Tracked gaps in the GCP LangSmith starter. Ordered by priority within each section.

Items marked with **(opt-in)** have working implementations gated behind a variable default of `false`.

---

## Security

### Critical

- [ ] **Terraform state uses local backend** — state contains plaintext secrets; configure GCS remote backend with object versioning and locking via `backend "gcs" { bucket = ...; prefix = ... }`

### High

- [ ] **No VPC Flow Logs** — add `log_config { aggregation_interval = "INTERVAL_5_SEC"; flow_sampling = 0.5 }` to the subnet in `modules/networking/main.tf`
- [ ] **PostgreSQL TLS not enforced in connection string** — `k8s-bootstrap` writes the connection URL without `?sslmode=require`; Cloud SQL enforces TLS by default but the connection string should be explicit
- [ ] **Redis: no AUTH configured** — Memorystore is access-controlled by VPC private IP only; add `auth_enabled = true` to the redis module for defense-in-depth
- [ ] **GCS HMAC keys not rotated** — HMAC keys are created manually and have no rotation mechanism; document a rotation runbook or use Workload Identity + native GCS auth if the chart supports it

### Medium

- [ ] **No pod security standards on `langsmith` namespace** — add `pod-security.kubernetes.io/enforce: baseline` label in `modules/k8s-bootstrap/main.tf`
- [ ] **No Kubernetes network policies** — GKE Dataplane V2 (Cilium) supports NetworkPolicy but none are deployed; east-west traffic is unrestricted
- [ ] **GKE: no Binary Authorization** — no policy enforcing signed container images; consider `AUDIT` mode as a starting point
- [ ] **No Cloud Armor (WAF)** — Cloud Armor can be attached to the Envoy Gateway's BackendService; implement as an opt-in module (`create_cloud_armor = false`)
- [ ] **Missing IAM permission boundaries** — GCP service account has project-level `secretmanager.secretAccessor`; scope to specific secrets only
- [ ] **GKE: Shielded Nodes not enforced** — add `shielded_instance_config { enable_secure_boot = true; enable_integrity_monitoring = true }` to node pool

### Low

- [ ] **No Cloud Audit Logs module** — GCP logs all Admin Activity by default; Data Read/Write logs are opt-in. Add a `google_project_iam_audit_config` resource to enable data access logs for GCS, Cloud SQL, and Secret Manager
- [ ] **Cloud SQL: no custom parameter group enforcing `ssl_mode`** — rely on default Cloud SQL SSL enforcement; add explicit `ssl_mode = "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"` flag

---

## Observability

- [ ] **No Cloud Monitoring dashboards** — no pre-built dashboards for GKE node health, Cloud SQL query latency, Memorystore evictions, or LangSmith pod restarts
- [ ] **No application-level metrics** — LangSmith pods expose Prometheus endpoints; no `PodMonitoring` resources deployed for Google Managed Prometheus scraping
- [ ] **No alerting policies** — no Cloud Monitoring alert policies for pod restarts, Cloud SQL CPU > 80%, Redis evictions, or 5xx error rate on the Gateway
- [ ] **No uptime checks** — no Cloud Monitoring uptime check on the LangSmith health endpoint

---

## Disaster Recovery

- [ ] **No Cloud SQL automated backup export** — Cloud SQL has automated backups enabled but no export to GCS for long-term retention or cross-region DR
- [ ] **No GCS versioning enabled by default** — LangSmith bucket has no object versioning; accidental deletions are permanent
- [ ] **No GCS cross-region replication** — no documented procedure for DR failover to a secondary region
- [ ] **No GKE PVC snapshot policy** — ClickHouse PVC (premium-rwo) has no VolumeSnapshot schedule
- [ ] **No cluster recovery runbook** — no documented procedure for full rebuild from Cloud SQL + GCS backups

---

## Scaling

- [ ] **GKE Autopilot mode untested** — `gke_use_autopilot = true` is wired but not validated end-to-end; Autopilot changes node pool management and some workload specs
- [ ] **No Vertical Pod Autoscaler config** — useful for right-sizing ClickHouse and queue workloads
- [ ] **KEDA `ScaledObject` not documented** — document recommended Redis trigger thresholds for production queue depth
- [ ] **No load testing baseline** — no documented RPS/latency targets or k6/Locust scripts for go-live validation
- [ ] **Cloud SQL connection pooling** — consider Cloud SQL Auth Proxy or `pgbouncer` sidecar for high-connection workloads

---

## Upgrades

- [ ] **No GKE version upgrade runbook** — control plane → node pool rolling upgrade procedure not documented
- [ ] **No Cloud SQL major version upgrade runbook** — POSTGRES_15 → 16 requires maintenance window + schema verification
- [ ] **No Helm chart upgrade guide** — review changelog, drain Redis queue, verify migration jobs before upgrading
- [ ] **No add-on version pinning** — Envoy Gateway, cert-manager, KEDA, ESO versions not pinned in `modules/k8s-bootstrap/main.tf`
- [ ] **No version compatibility matrix** — Helm chart × GKE × Cloud SQL × K8s API versions not documented

---

## Operations

- [ ] **No cost optimization guidance** — e2-standard-4 is a reasonable default but memory-optimized nodes (n2-highmem-4) may be more cost-effective for ClickHouse; document right-sizing recommendations
- [ ] **GCS access via HMAC keys** — HMAC key creation is manual and outside Terraform; ideally the LangSmith chart would support native GCS auth via Workload Identity to eliminate static key management
- [ ] **No tagging / label strategy** — `owner` and `cost_center` labels exist but no enforcement across all resources; needed for cost allocation and compliance
- [ ] **Envoy Gateway external IP is ephemeral** — if the Gateway resource is deleted and recreated, a new IP is issued; existing DNS records and any IP allowlists break permanently. Document this risk in TROUBLESHOOTING.md

---

## Testing

### Shell Scripts

- [ ] **Add ShellCheck to CI** — run `shellcheck helm/scripts/*.sh` on all shell scripts; fix existing warnings
- [ ] **Add Bats tests for `init-values.sh`** — cover: tfvars-driven addon selection, interactive fallback, ClickHouse prompt, re-run idempotency, error on missing outputs
- [ ] **Add Bats tests for `deploy.sh`** — cover: values chain construction, flag-gated addon inclusion, pending-upgrade rollback, langsmith-ksa annotation

### Terraform Modules

- [ ] **Add `terraform validate` + `tflint` CI step** — run against each module directory; add `.tflint.hcl` with GCP ruleset
- [ ] **Add native `terraform test` files for pure-logic modules** — start with `modules/networking` (CIDR outputs), `modules/storage` (bucket naming), `modules/iam` (service account email format)
- [ ] **Add plan-level snapshot tests** — `terraform plan -out=plan.tfplan && terraform show -json plan.tfplan` diffed against a baseline; catches unintended resource changes on module edits

---

## Deployment Audit Findings

Issues identified during module review. Items here don't block the happy path but affect edge cases.

- [ ] **Base `values.yaml` hardcodes `postgres.external.enabled: true`** — when `postgres_source = "in-cluster"`, `init-values.sh` writes an override to disable it, but manual copy of the base file skips that. Add a guard in `deploy.sh` that validates the override exists when `postgres_source = "in-cluster"`. (`helm/values/values.yaml:241-244`, `init-values.sh`)
- [x] **`values-overrides.yaml.example` uses stale secret names** — fixed: updated `values.yaml`, `values-overrides.yaml.example`, and added `examples/langsmith-values.yaml`
- [x] **`null_resource.wait_for_cluster` uses `local-exec` with `gcloud`** — fixed: replaced with `time_sleep.wait_for_cluster` (90s). The GKE Terraform resource already waits for RUNNING state; the sleep gives the API server time to become fully accessible without requiring gcloud or kubectl in PATH.
- [x] **`terraform_data.validate_inputs` has no `depends_on`** — fixed: added `depends_on = [google_project_service.apis]` so validation errors surface after APIs are enabled.
