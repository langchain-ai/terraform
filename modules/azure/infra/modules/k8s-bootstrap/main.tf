# ── Providers ─────────────────────────────────────────────────────────────────
# Credentials are passed in from the root module via variables (not from a local
# kubeconfig) so this module works in CI/CD pipelines without file system access.

# On an Entra ID cluster (kube_auth = "entra") the client certificate is empty and
# the providers sign in through kubelogin with the caller's az session instead.

provider "kubernetes" {
  host                   = var.host
  client_certificate     = var.kube_auth == "entra" ? null : base64decode(var.client_certificate)
  client_key             = var.kube_auth == "entra" ? null : base64decode(var.client_key)
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)

  dynamic "exec" {
    for_each = var.kube_auth == "entra" ? [1] : []
    content {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = var.host
    client_certificate     = var.kube_auth == "entra" ? null : base64decode(var.client_certificate)
    client_key             = var.kube_auth == "entra" ? null : base64decode(var.client_key)
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)

    dynamic "exec" {
      for_each = var.kube_auth == "entra" ? [1] : []
      content {
        api_version = "client.authentication.k8s.io/v1beta1"
        command     = "kubelogin"
        args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
      }
    }
  }
}

# ── Namespace ─────────────────────────────────────────────────────────────────
# Dedicated namespace isolates LangSmith workloads from other cluster tenants.
# The workload.identity label is required by the Azure Workload Identity webhook
# to inject OIDC tokens into pods so they can authenticate to Azure Blob Storage.

resource "kubernetes_namespace_v1" "langsmith" {
  metadata {
    name = var.langsmith_namespace
    labels = {
      "app"                         = "langsmith"
      "azure.workload.identity/use" = "true"
    }
  }
}

# ── Service Accounts (Workload Identity, pull Secret) ─────────────────────────
# langsmith-ksa is the account the operator's agent pods run as. It carries
# the blob identity's client-ID annotation, but that grants nothing: there is
# no federated credential for it (k8s-cluster's
# service_accounts_for_workload_identity) and the agent template sets no
# azure.workload.identity/use label. Keep it that way: federating it would give
# every agent's code Storage Blob Data Contributor on the blob account.
#
# With langsmith_image_pull_secret_name set, every account here carries the
# Secret as imagePullSecrets. The chart's own pods pull with
# images.imagePullSecrets from the values file; the pods the operator creates
# for each deployment do not, and run as langsmith-ksa (the agent pod) or as
# the namespace's default account (its Redis and PostgreSQL). The provider
# reads imagePullSecrets back, so a Secret attached by hand is removed at the
# next apply; declared here, it stays.

locals {
  langsmith_image_pull_secrets = var.langsmith_image_pull_secret_name == "" ? [] : [var.langsmith_image_pull_secret_name]
}

resource "kubernetes_service_account_v1" "langsmith" {
  metadata {
    name      = "langsmith-ksa"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = var.blob_managed_identity_client_id
    }
  }

  dynamic "image_pull_secret" {
    for_each = local.langsmith_image_pull_secrets
    content {
      name = image_pull_secret.value
    }
  }
}

# Helm pre-install hooks run before ordinary chart resources are created. Own
# the hook ServiceAccounts here so the Jobs can start on the first install.
resource "kubernetes_service_account_v1" "backend" {
  metadata {
    name      = var.backend_service_account_name
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = var.blob_managed_identity_client_id
    }
  }

  dynamic "image_pull_secret" {
    for_each = local.langsmith_image_pull_secrets
    content {
      name = image_pull_secret.value
    }
  }
}

resource "kubernetes_service_account_v1" "smithdb" {
  count = var.enable_smithdb ? 1 : 0

  metadata {
    name      = var.smithdb_service_account_name
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = var.smithdb_managed_identity_client_id
    }
  }

  dynamic "image_pull_secret" {
    for_each = local.langsmith_image_pull_secrets
    content {
      name = image_pull_secret.value
    }
  }
}

# Kubernetes creates the default service account in the namespace. With a pull
# Secret set, the module adopts it (the provider's resource for exactly that)
# and attaches the Secret, because the operator's Redis and PostgreSQL pods run
# as it. Clearing the setting destroys the resource, which deletes the account;
# Kubernetes recreates it, without the Secret, within seconds.
resource "kubernetes_default_service_account_v1" "langsmith" {
  count = var.langsmith_image_pull_secret_name == "" ? 0 : 1

  metadata {
    name      = "default"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  image_pull_secret {
    name = var.langsmith_image_pull_secret_name
  }
}

locals {
  # The accounts that carry the pull Secret, for the output and the tests.
  langsmith_image_pull_secret_service_accounts = var.langsmith_image_pull_secret_name == "" ? [] : compact([
    "langsmith-ksa",
    var.backend_service_account_name,
    var.enable_smithdb ? var.smithdb_service_account_name : "",
    "default",
  ])
}

# SmithDB's disk-backed caches use per-pod generic ephemeral PVCs. Premium SSD
# v2 exposes provisioned IOPS and throughput independently of volume capacity,
# so the chart's 100-200 GiB cache sizes can meet SmithDB's performance target
# without being inflated solely to buy more disk performance.
resource "kubernetes_storage_class_v1" "smithdb_cache" {
  count = var.enable_smithdb ? 1 : 0

  metadata {
    name = var.smithdb_cache_storage_class_name
  }

  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  # The disk CSI driver creates these disks in the node resource group, outside
  # Terraform, and tags them only from the tags parameter (key1=val1,key2=val2),
  # not from the cluster. Kubernetes refuses parameter updates, so a tag change
  # replaces the StorageClass; disks already provisioned keep their old tags.
  parameters = merge(
    {
      skuName           = "PremiumV2_LRS"
      cachingMode       = "None"
      DiskIOPSReadWrite = tostring(var.smithdb_cache_disk_iops)
      DiskMBpsReadWrite = tostring(var.smithdb_cache_disk_throughput)
    },
    length(var.tags) > 0 ? { tags = join(",", [for k, v in var.tags : "${k}=${v}"]) } : {},
  )
}

# ── Resource Quota ────────────────────────────────────────────────────────────
# Caps total CPU/memory/pod count for the namespace. Prevents a runaway LangSmith
# deployment (e.g. KEDA over-scaling) from starving kube-system or other tenants.
# Base: 40 CPU req / 80 CPU lim, 80 GiB req / 160 GiB lim, 200 pods. The
# resource_quota_extra_* inputs add SmithDB's pods on top, once to requests and
# twice to limits, so a plain install keeps the base figures.
#
# With sandboxes on, the quota caps requests only. sandbox-host runs Firecracker
# VMs in child cgroups beneath its own pod cgroup, so a container limit would cap
# every sandbox on the node, and a limits.* quota would force one onto it.

resource "kubernetes_resource_quota_v1" "langsmith" {
  metadata {
    name      = "langsmith-quota"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    hard = merge({
      "requests.cpu"    = tostring(40 + var.resource_quota_extra_cpu)
      "requests.memory" = "${80 + var.resource_quota_extra_memory_gi}Gi"
      pods              = tostring(200 + var.resource_quota_extra_pods)
      }, var.enable_sandboxes ? {} : {
      "limits.cpu"    = tostring(80 + var.resource_quota_extra_cpu * 2)
      "limits.memory" = "${160 + var.resource_quota_extra_memory_gi * 2}Gi"
    })
  }
}

# ── Limit Range ───────────────────────────────────────────────────────────────
# Required companion to the ResourceQuota above: because the quota's `hard` includes
# requests/limits, Kubernetes forces EVERY pod to declare them. Some chart components
# (e.g. the bundled Postgres/Redis StatefulSets for the standalone insights/polly/fleet
# agent features) ship without resource stanzas, so without defaults they're rejected
# with "failed quota: must specify limits.cpu/... for: <container>" and never schedule.
# This LimitRange supplies defaults so those pods inherit sane values and satisfy the quota.
# With sandboxes on it supplies requests only: a default 1 CPU limit lands below
# sandbox-host's 2 CPU request, and the API server rejects the pod.
resource "kubernetes_limit_range_v1" "langsmith" {
  metadata {
    name      = "langsmith-defaults"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = var.enable_sandboxes ? null : {
        cpu    = "1"
        memory = "1Gi"
      }
      # 250m covers an unsized container's startup CPU, so the scheduler stops
      # packing more of them onto a node than it can feed. A LimitRange applies
      # at admission: running pods keep their old request until they restart.
      default_request = {
        cpu    = "250m"
        memory = "256Mi"
      }
    }
  }
}

# ── Network Policy ────────────────────────────────────────────────────────────
# Default-deny blocks all ingress to LangSmith pods unless explicitly allowed.
# This is defense-in-depth: even if a pod is compromised, it cannot receive
# lateral traffic from other namespaces. Egress is unrestricted (external DBs).

resource "kubernetes_network_policy_v1" "langsmith_default_deny" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# Namespace the selected ingress controller's data plane runs in. The
# NetworkPolicy below must allow ingress from this namespace, or the controller's
# proxy cannot reach LangSmith pods (default-deny drops it → 503 with ~10s
# connection timeout). AGIC resolves to "" and is allowed by ip_block instead:
# Application Gateway routes from its dedicated subnet, not an in-cluster pod
# namespace, so there is no namespace to name here.
locals {
  ingress_namespace = lookup({
    "nginx"         = "ingress-nginx"
    "envoy-gateway" = "envoy-gateway-system"
    "istio"         = "istio-system"
    "istio-addon"   = "aks-istio-ingress"
  }, var.ingress_controller, "")
}

# Allows ingress from the selected ingress controller's namespace (external
# traffic via LB) and from within the langsmith namespace itself (inter-service
# calls). The intra-namespace rule is required on its own: without it, backend
# pods cannot call each other (e.g. queue workers calling the internal API).
resource "kubernetes_network_policy_v1" "langsmith_allow_internal" {
  metadata {
    name      = "allow-from-ingress"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    pod_selector {}

    # Ingress controller namespace — skipped for controllers that do not run as
    # in-cluster pods (e.g. agic), where ingress_namespace resolves to "".
    dynamic "ingress" {
      for_each = local.ingress_namespace != "" ? [local.ingress_namespace] : []
      content {
        from {
          namespace_selector {
            match_labels = {
              "kubernetes.io/metadata.name" = ingress.value
            }
          }
        }
      }
    }

    # Application Gateway subnet — the AGIC counterpart to the namespace rule
    # above. In Azure CNI mode the gateway puts pod IPs straight into its backend
    # pool and connects from its own subnet, so there is no source namespace to
    # match and only an address range identifies it. Azure requires that subnet be
    # exclusive to the gateway, so the range admits nothing else.
    dynamic "ingress" {
      for_each = var.ingress_controller == "agic" ? var.agic_subnet_cidrs : []
      content {
        from {
          ip_block {
            cidr = ingress.value
          }
        }
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.langsmith_namespace
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}

# sandbox-host runs on the host network, so its calls to platform-backend come
# from a node IP, which no namespace rule above matches. Azure NPM matches node
# IPs by ipBlock, so this admits the node subnet to platform-backend's API port
# alone. Under node-subnet IPAM, pods draw from the same range and reach that port
# too; under overlay, only nodes do. Cilium on AKS never matches a node IP by
# ipBlock, so there helm/scripts/deploy.sh applies a CiliumNetworkPolicy instead.
resource "kubernetes_network_policy_v1" "platform_backend_from_nodes" {
  count = var.enable_sandboxes && var.network_policy_engine != "cilium" ? 1 : 0

  metadata {
    name      = "allow-nodes-to-platform-backend"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/component" = var.platform_backend_component
      }
    }

    ingress {
      dynamic "from" {
        for_each = var.node_subnet_cidrs
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
      ports {
        port     = "1986"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }

  lifecycle {
    precondition {
      # An ingress rule with ports and no peers admits every source.
      condition     = length(var.node_subnet_cidrs) > 0
      error_message = "The NetworkPolicy admitting sandbox-host to platform-backend needs the AKS node subnet's address prefixes, and none were found."
    }
  }
}

# ── Kubernetes Secrets (infrastructure dependencies) ──────────────────────────
# These are created here because they depend on Terraform outputs (connection URLs).
# Application-level secrets (api_key_salt, jwt_secret, admin_password) are
# written by infra/scripts/create-k8s-secrets.sh from Azure Key Vault.

# PostgreSQL connection URL injected into the namespace so the Helm chart can
# reference it via existingSecretName. Created here (not by Helm) because the
# URL is a Terraform output — it's only known after the postgres module runs.
resource "kubernetes_secret_v1" "postgres" {
  count = var.use_external_postgres ? 1 : 0

  metadata {
    name      = "langsmith-postgres-secret"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = {
    connection_url = var.postgres_connection_url
    # POSTGRES_URI and POSTGRES_PASSWORD are required by the listener's deploy_image
    # task (host.platforms.k8s_operator.database_k8s.add_postgres_uri_secret) to
    # provision per-deployment databases for LangSmith Deployments (Pass 3+).
    POSTGRES_URI      = var.postgres_connection_url
    POSTGRES_PASSWORD = var.postgres_admin_password
  }

  type = "Opaque"
}

# Fleet Postgres connection URL — the dedicated langsmith_fleet database.
# Referenced by the chart via fleet.postgres.external.existingSecretName. Only the
# Postgres secret is created for Fleet: its Redis is the chart's in-cluster bundled
# StatefulSet (Azure Managed Redis can't provide the logical-DB isolation the
# AWS/GCP Fleet uses, and Fleet has no clusterSafeMode knob), so there is no
# langsmith-fleet-redis secret.
resource "kubernetes_secret_v1" "fleet_postgres" {
  count = var.enable_fleet && var.use_external_postgres ? 1 : 0

  metadata {
    name      = "langsmith-fleet-postgres"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = {
    postgres_connection_url = var.fleet_postgres_connection_url
  }

  type = "Opaque"
}

# Redis connection URL (rediss://...) injected the same way as the Postgres secret.
# KEDA ScaledObjects also reference this secret to authenticate queue-depth queries.
resource "kubernetes_secret_v1" "redis" {
  count = var.use_external_redis ? 1 : 0

  metadata {
    name      = "langsmith-redis-secret"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  # All three keys in both modes — the chart reads only the pair its mode needs, so
  # switching modes is a values-file edit, not a terraform apply.
  data = {
    connection_url          = var.redis_connection_url
    redis_cluster_node_uris = var.redis_cluster_node_uris
    redis_cluster_password  = var.redis_cluster_password
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "smithdb_metastore" {
  count = var.enable_smithdb ? 1 : 0

  metadata {
    name      = "smithdb-metastore"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = merge({
    smithdb_metastore_db_host     = var.smithdb_metastore_host
    smithdb_metastore_db_name     = var.smithdb_metastore_database
    smithdb_metastore_db_username = var.smithdb_metastore_username
    }, var.smithdb_metastore_password == null ? {} : {
    smithdb_metastore_db_password = var.smithdb_metastore_password
  })

  type = "Opaque"
}

# LangSmith license key secret — required for the application to start.
# The Helm chart references this via config.licenseKeySecretName.
resource "kubernetes_secret_v1" "license" {
  count = var.langsmith_license_key != "" ? 1 : 0

  metadata {
    name      = "langsmith-license"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = {
    license_key = var.langsmith_license_key
  }

  type = "Opaque"
}

# JuiceFS config for sandbox-host and the chart's juicefs-format Job, passed to
# the chart as sandboxes.juicefs.existingSecretName. The format Job's name hashes
# this Secret's name, not its data, so a changed value reaches an existing volume
# only under a new Secret name. Write-only, so the metaurl's Redis key stays out
# of this resource's state, and a new value is written only when the revision
# changes or the Redis is replaced: a new Redis has a new host and key, and
# replacing the Secret writes them without a revision bump.
resource "terraform_data" "sandbox_juicefs_redis" {
  count = var.enable_sandboxes ? 1 : 0
  input = var.sandbox_juicefs_redis_id
}

resource "kubernetes_secret_v1" "sandbox_juicefs" {
  count = var.enable_sandboxes ? 1 : 0

  metadata {
    name      = var.sandbox_juicefs_secret_name
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data_wo          = var.sandbox_juicefs_config
  data_wo_revision = var.sandbox_juicefs_config_revision

  type = "Opaque"

  lifecycle {
    replace_triggered_by = [terraform_data.sandbox_juicefs_redis]
  }
}

# ── cert-manager ──────────────────────────────────────────────────────────────
# TLS automation infrastructure. Manages Let's Encrypt certificates.
# ClusterIssuers are applied separately by helm/scripts/deploy.sh.

# Orders cert-manager after the Envoy Gateway release. cert-manager looks for the
# Gateway API CRDs only at startup, so one started before them never serves
# Gateways even with the feature gate below.
resource "terraform_data" "gateway_api_crds" {
  input = var.envoy_gateway_version
}

resource "helm_release" "cert_manager" {
  count = var.install_cert_manager ? 1 : 0

  depends_on = [terraform_data.gateway_api_crds]

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  wait             = true
  wait_for_jobs    = true

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "256Mi"
  }

  # Envoy Gateway: the HTTP-01 gatewayHTTPRoute solver, and the Gateway shim that
  # issues the certificate a Gateway's cluster-issuer annotation asks for, both
  # need Gateway API support. On the pinned v1.14 that is this feature gate;
  # v1.15 and later replace it with config.enableGatewayAPI.
  dynamic "set" {
    for_each = var.ingress_controller == "envoy-gateway" ? [1] : []
    content {
      name  = "featureGates"
      value = "ExperimentalGatewayAPISupport=true"
    }
  }

  # DNS-01 via Azure Workload Identity: annotate the cert-manager service account
  # with the Managed Identity client ID so it can call the Azure DNS API.
  # The federated credential (created in k8s-cluster module) allows the OIDC
  # token exchange that binds the pod to the identity.
  dynamic "set" {
    for_each = var.tls_certificate_source == "dns01" ? [1] : []
    content {
      name  = "podLabels.azure\\.workload\\.identity/use"
      value = "true"
      type  = "string"
    }
  }
  dynamic "set" {
    for_each = var.tls_certificate_source == "dns01" ? [1] : []
    content {
      name  = "serviceAccount.annotations.azure\\.workload\\.identity/client-id"
      value = var.cert_manager_identity_client_id
    }
  }
}

# No ClusterIssuer is created here, for either HTTP-01 or DNS-01.
# kubernetes_manifest requires a live API connection during plan, which fails on fresh
# deploy (no cluster exists yet). Both issuers are applied by helm/scripts/deploy.sh
# after the cluster is up, via kubectl apply. The DNS-01 issuer needs the pod labels
# and service account annotation set on the cert-manager release above.

# ── KEDA ──────────────────────────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling. Scales LangSmith queue workers
# based on Redis queue depth.
#
# With keda_image_registry, the chart's global.image.registry puts the mirror
# in front of each image's repository, whose default carries the ghcr.io host
# (ghcr.io/kedacore/<name>), so the pull is <registry>/ghcr.io/kedacore/<name>.
# keda_image_registry_keeps_source_host = false drops that segment by setting
# the three repositories to kedacore/<name>. The tag is the chart's appVersion,
# which KEDA keeps equal to the chart version. local.keda_images composes the
# same paths for the keda_images output, so a plan shows what the nodes pull.
locals {
  keda_mirror       = var.install_keda && var.keda_image_registry != ""
  keda_image_prefix = local.keda_mirror ? (var.keda_image_registry_keeps_source_host ? "${var.keda_image_registry}/ghcr.io/kedacore/" : "${var.keda_image_registry}/kedacore/") : "ghcr.io/kedacore/"
  keda_images = var.install_keda ? {
    for name in ["keda", "keda-metrics-apiserver", "keda-admission-webhooks"] : name => "${local.keda_image_prefix}${name}:${var.keda_version}"
  } : {}
  keda_mirror_sets = merge(
    local.keda_mirror ? { "global.image.registry" = var.keda_image_registry } : {},
    local.keda_mirror && !var.keda_image_registry_keeps_source_host ? {
      "image.keda.repository"             = "kedacore/keda"
      "image.metricsApiServer.repository" = "kedacore/keda-metrics-apiserver"
      "image.webhooks.repository"         = "kedacore/keda-admission-webhooks"
    } : {},
    var.install_keda && var.keda_image_pull_secret_name != "" ? { "imagePullSecrets[0].name" = var.keda_image_pull_secret_name } : {},
  )
}

resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = var.keda_chart_repository
  # A mirror behind a login takes the two; null keeps the fetch anonymous.
  repository_username = var.keda_chart_repository_username != "" ? var.keda_chart_repository_username : null
  repository_password = var.keda_chart_repository_password != "" ? var.keda_chart_repository_password : null
  chart               = "keda"
  version             = var.keda_version
  wait                = true
  wait_for_jobs       = true

  set {
    name  = "resources.operator.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.operator.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "resources.operator.limits.cpu"
    value = "500m"
  }
  set {
    name  = "resources.operator.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "resources.metricServer.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.metricServer.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "resources.metricServer.limits.cpu"
    value = "500m"
  }
  set {
    name  = "resources.metricServer.limits.memory"
    value = "512Mi"
  }

  # The mirror, the repository layout and the pull Secret, only when set.
  dynamic "set" {
    for_each = local.keda_mirror_sets
    content {
      name  = set.key
      value = set.value
    }
  }
}
