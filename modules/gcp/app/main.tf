#------------------------------------------------------------------------------
# LangSmith App Module (Pass 2 — Terraform)
#
# Deploys LangSmith via Helm, assuming infra (Pass 1) is complete.
# Equivalent to helm/scripts/deploy.sh but managed by Terraform.
#
# Prerequisites:
#   - GKE cluster running (Pass 1 complete)
#   - Helm values populated: make init-values
#   - Infra outputs pulled: make init-app
#   - Then: make apply-app
#
# Auth note: Uses gcloud application-default credentials (same as infra/).
# Run `gcloud auth application-default login` before apply-app if not already done.
#------------------------------------------------------------------------------

# ── Providers ─────────────────────────────────────────────────────────────────

provider "google" {
  project = local.project_id
  region  = local.region
}

data "google_client_config" "default" {}

data "google_container_cluster" "this" {
  name     = local.cluster_name
  location = local.region
  project  = local.project_id
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.this.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.google_container_cluster.this.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  }
}

# ── ClickHouse Secret (only when Insights is enabled) ────────────────────────
# Stores ClickHouse credentials in a K8s Secret so the password never appears
# in Helm values or Helm release metadata.

resource "kubernetes_secret" "clickhouse" {
  count = var.enable_insights ? 1 : 0

  metadata {
    name      = "langsmith-clickhouse"
    namespace = local.namespace
  }
  data = {
    clickhouse_host     = var.clickhouse_host
    clickhouse_port     = tostring(var.clickhouse_port)
    clickhouse_user     = var.clickhouse_username
    clickhouse_password = var.clickhouse_password
    clickhouse_db       = var.clickhouse_database
    clickhouse_tls      = tostring(var.clickhouse_tls)
  }
  type = "Opaque"
}

# ── Helm Release ──────────────────────────────────────────────────────────────

resource "helm_release" "langsmith" {
  depends_on = [
    terraform_data.validate_required,
    kubernetes_secret.clickhouse,
  ]

  name             = var.release_name
  namespace        = local.namespace
  create_namespace = true
  repository       = "https://langchain-ai.github.io/helm"
  chart            = "langsmith"
  version          = var.chart_version != "" ? var.chart_version : null
  timeout          = var.helm_timeout

  # Do NOT use wait = true. The chart's post-install bootstrap job deploys
  # operator-managed agents (clio, polly, agent-builder) which can take 10+
  # minutes on a cold cluster with autoscaling. Terraform marks the release as
  # failed if the job exceeds the timeout — even though all workloads are healthy.
  wait = false

  force_update = var.helm_force_update

  # Values layering — YAML files are the single source of truth (shared with helm/scripts path).
  # Only overrides_values is HCL — it contains dynamic, env-specific config (hostname, WI, GCS).
  # This is the same values chain as deploy.sh: base → overrides → sizing → addons.
  values = concat(
    # 1. Base GCP config (ingress type, storage, auth, external postgres/redis)
    [file("${local.values_path}/langsmith-values.yaml")],
    # 2. Dynamic overrides (hostname, Workload Identity annotations, GCS bucket)
    [yamlencode(local.overrides_values)],
    # 3. Sizing
    var.sizing == "production"       ? [file("${local.values_path}/langsmith-values-sizing-production.yaml")] : [],
    var.sizing == "production-large" ? [file("${local.values_path}/langsmith-values-sizing-production-large.yaml")] : [],
    var.sizing == "dev"              ? [file("${local.values_path}/langsmith-values-sizing-dev.yaml")] : [],
    var.sizing == "minimum"          ? [file("${local.values_path}/langsmith-values-sizing-minimum.yaml")] : [],
    # 4. Product addons
    var.enable_agent_deploys ? [file("${local.values_path}/langsmith-values-agent-deploys.yaml"), yamlencode(local.agent_deploys_overrides)] : [],
    var.enable_agent_builder ? [file("${local.values_path}/langsmith-values-agent-builder.yaml")] : [],
    var.enable_insights      ? [file("${local.values_path}/langsmith-values-insights.yaml"), yamlencode(local.insights_overrides)] : [],
    var.enable_polly         ? [file("${local.values_path}/langsmith-values-polly.yaml")] : [],
  )
}

# ── langsmith-ksa for agent deployment pods ──────────────────────────────────
# Creates the SA up front with the Workload Identity annotation so operator-
# spawned agent pods have GCS access from the start.
# The SA must exist before the operator tries to use it — kubernetes_annotations
# alone would fail on first apply because the SA doesn't exist yet.

resource "kubernetes_service_account_v1" "langsmith_ksa" {
  count = var.enable_agent_deploys && length(local.wi_annotations) > 0 ? 1 : 0

  metadata {
    name      = "langsmith-ksa"
    namespace = local.namespace
    annotations = local.wi_annotations
  }

  lifecycle {
    ignore_changes = [metadata[0].labels]
  }
}
