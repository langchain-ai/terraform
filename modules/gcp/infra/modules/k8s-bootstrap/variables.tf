# Variables for K8s Bootstrap Module

variable "project_id" {
  description = "GCP Project ID"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a GCP project ID: 6 to 30 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

# Needed so the kubectl provisioners can fetch credentials for this specific
# cluster rather than relying on the ambient kubeconfig context.
variable "region" {
  description = "Region of the GKE cluster. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a GCP region, for example us-central1."
  }
}

variable "cluster_name" {
  description = "Name of the GKE cluster being bootstrapped. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,38}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a GKE cluster name: up to 40 lowercase letters, digits, or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
}

#------------------------------------------------------------------------------
# Namespace Configuration
#------------------------------------------------------------------------------
variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = "langsmith"
}

variable "workload_identity_gsa_email" {
  description = "Optional GCP service account email to annotate on the LangSmith Kubernetes service account for Workload Identity."
  type        = string
  default     = ""
}

variable "resource_quota_include_limits" {
  description = "Include aggregate CPU and memory limits in the LangSmith namespace ResourceQuota. Disable for sandbox-host, whose Firecracker VMs use child cgroups beneath the pod cgroup."
  type        = bool
  default     = true
}

variable "resource_quota_extra_cpu" {
  description = "Additional CPU added to the LangSmith namespace ResourceQuota, on both the requests and the limits side. The root uses this to make room for optional features that add large pods, so the base figures stay the same for a plain install. Zero keeps the base quota."
  type        = number
  default     = 0

  validation {
    condition     = var.resource_quota_extra_cpu >= 0 && var.resource_quota_extra_cpu <= 200
    error_message = "resource_quota_extra_cpu must be between 0 and 200. A namespace quota is a guardrail against a runaway HPA, so it must stay bounded rather than being raised until every pod fits."
  }
}

variable "resource_quota_extra_memory_gi" {
  description = "Additional memory in GiB added to the LangSmith namespace ResourceQuota, on both the requests and the limits side. Counterpart to resource_quota_extra_cpu."
  type        = number
  default     = 0

  validation {
    condition     = var.resource_quota_extra_memory_gi >= 0 && var.resource_quota_extra_memory_gi <= 400
    error_message = "resource_quota_extra_memory_gi must be between 0 and 400."
  }
}

variable "resource_quota_extra_pods" {
  description = "Additional pod count added to the LangSmith namespace ResourceQuota. Counterpart to resource_quota_extra_cpu."
  type        = number
  default     = 0

  validation {
    condition     = var.resource_quota_extra_pods >= 0 && var.resource_quota_extra_pods <= 400
    error_message = "resource_quota_extra_pods must be between 0 and 400."
  }
}

variable "allow_critical_priority_pods" {
  description = "Create a PriorityClass-scoped ResourceQuota admitting system-node-critical and system-cluster-critical pods into the LangSmith namespace. Required for the JuiceFS CSI driver the sandbox feature depends on: GKE limits those priority classes to namespaces holding a matching scoped quota, and without one the CSI DaemonSet and controller are rejected at admission. Leave false when sandboxes are disabled."
  type        = bool
  default     = false
}

variable "default_container_requests" {
  description = "Default CPU and memory requests injected by a LimitRange into containers that omit them. An empty map disables the LimitRange. No default limits are imposed."
  type        = map(string)
  default     = {}

  validation {
    condition = (
      length(var.default_container_requests) == 0 ||
      (
        length(var.default_container_requests) == 2 &&
        contains(keys(var.default_container_requests), "cpu") &&
        contains(keys(var.default_container_requests), "memory") &&
        alltrue([for value in values(var.default_container_requests) : trimspace(value) != ""])
      )
    )
    error_message = "default_container_requests must be empty or contain exactly non-empty cpu and memory values."
  }
}

variable "sandbox_host_ingress_cidrs" {
  description = "Node-network CIDRs admitted to LangSmith pods for the host-networked sandbox-host. Used on CALICO, where an ipBlock matches node IPs. On GKE Dataplane V2 an ipBlock does not match node-sourced traffic, so the root leaves this empty and scopes the default-deny (default_deny_excluded_component) instead. Empty disables the policy."
  type        = list(string)
  default     = []
}

variable "default_deny_excluded_component" {
  description = "app.kubernetes.io/component label value to EXCLUDE from the langsmith-default default-deny ingress policy, leaving that one pod reachable while every other pod stays denied. Used on GKE Dataplane V2 to let the host-networked sandbox-host reach platform-backend without dropping namespace isolation (an ipBlock cannot match node-sourced traffic on Cilium). Empty selects all pods (full default-deny)."
  type        = string
  default     = ""
}

#------------------------------------------------------------------------------
# Database Credentials
#------------------------------------------------------------------------------
variable "use_external_postgres" {
  description = "Whether using external PostgreSQL (Cloud SQL). When false, skips PostgreSQL secret creation."
  type        = bool
  default     = true
}

variable "postgres_connection_url" {
  description = "PostgreSQL connection URL (format: postgresql://user:password@host:port/database) - only used when use_external_postgres = true"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# Redis Credentials
#------------------------------------------------------------------------------
variable "use_managed_redis" {
  description = "Whether using managed Redis (Memorystore). When false, skips Redis secret creation."
  type        = bool
  default     = true
}

variable "redis_connection_url" {
  description = "Redis connection URL (format: redis://host:port) - only used when use_managed_redis = true"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# License
#------------------------------------------------------------------------------
variable "langsmith_license_key" {
  description = "LangSmith license key"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# KEDA Configuration
#------------------------------------------------------------------------------
variable "install_keda" {
  description = "Install KEDA for LangSmith Deployment feature (autoscaling agent deployments)"
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# TLS / Certificate Configuration
#------------------------------------------------------------------------------
variable "tls_certificate_source" {
  description = "Source of TLS certificates: 'none', 'google-managed', 'existing', 'cert-manager', or 'letsencrypt'. This module handles the Secret-based sources; 'google-managed' lives on the load balancer."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "google-managed", "existing", "cert-manager", "letsencrypt"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be one of: none, google-managed, existing, cert-manager, letsencrypt."
  }
}

variable "install_cert_manager" {
  description = "Install cert-manager"
  type        = bool
  default     = false
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version (OCI chart oci://quay.io/jetstack/charts/cert-manager)"
  type        = string
  default     = "v1.21.2"

  validation {
    condition     = can(regex("^v1\\.[0-9]+\\.[0-9]+$", var.cert_manager_version))
    error_message = "cert_manager_version must look like v1.21.2."
  }
}

variable "cert_manager_enable_gateway_api" {
  description = "Turn on cert-manager's Gateway API support, which the Let's Encrypt HTTP-01 solver needs. Applies the Gateway API CRDs from gateway_api_crds_url before cert-manager starts."
  type        = bool
  default     = false
}

variable "gateway_api_crds_url" {
  description = "Gateway API CRD bundle applied ahead of cert-manager when cert_manager_enable_gateway_api is true. Must match the ingress module's bundle."
  type        = string
  default     = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml"

  validation {
    condition     = startswith(var.gateway_api_crds_url, "https://")
    error_message = "gateway_api_crds_url must be an https:// URL."
  }
}

variable "cert_manager_issuer_name" {
  description = "Issuer or ClusterIssuer for tls_certificate_source = 'cert-manager'. Created by the operator, not by this module."
  type        = string
  default     = ""
}

variable "cert_manager_issuer_kind" {
  description = "Kind of cert_manager_issuer_name: 'ClusterIssuer', or 'Issuer' in the LangSmith namespace."
  type        = string
  default     = "ClusterIssuer"

  validation {
    condition     = contains(["ClusterIssuer", "Issuer"], var.cert_manager_issuer_kind)
    error_message = "cert_manager_issuer_kind must be ClusterIssuer or Issuer."
  }
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt certificate notifications (required if tls_certificate_source is 'letsencrypt')"
  type        = string
  default     = ""
}

variable "gateway_name" {
  description = "Name of the Gateway resource for cert-manager HTTP01 challenges (Envoy Gateway)"
  type        = string
  default     = "langsmith-gateway"
}

#------------------------------------------------------------------------------
# Existing TLS Certificate (when tls_certificate_source = "existing")
#------------------------------------------------------------------------------
variable "tls_certificate_crt" {
  description = "TLS certificate (PEM format). Can be base64 encoded or raw PEM content."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_certificate_key" {
  description = "TLS private key (PEM format). Can be base64 encoded or raw PEM content."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_secret_name" {
  description = "Name of the TLS Secret the Gateway HTTPS listener reads, in the LangSmith namespace. Created here for 'existing' with PEM inputs, by cert-manager for 'letsencrypt' and 'cert-manager', or by the operator with tls_existing_secret_name. Empty when no Secret is used."
  type        = string
  default     = "langsmith-tls"

  validation {
    condition = var.tls_secret_name == "" || (
      length(var.tls_secret_name) <= 253 &&
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", var.tls_secret_name))
    )
    error_message = "tls_secret_name must be empty or a Kubernetes Secret name: up to 253 lowercase letters, digits, hyphens, or dots, starting and ending with a letter or digit."
  }
}

variable "langsmith_domain" {
  description = "Domain name for LangSmith (used for TLS secret annotations)"
  type        = string
  default     = ""
}

#------------------------------------------------------------------------------
# ClickHouse Configuration
#------------------------------------------------------------------------------
variable "clickhouse_source" {
  description = "ClickHouse deployment type: 'in-cluster', 'langsmith-managed', or 'external'"
  type        = string
  default     = "in-cluster"
}

variable "clickhouse_host" {
  description = "ClickHouse host (for external/managed)"
  type        = string
  default     = ""
}

variable "clickhouse_port" {
  description = "ClickHouse native port"
  type        = number
  default     = 9440
}

variable "clickhouse_http_port" {
  description = "ClickHouse HTTP port"
  type        = number
  default     = 8443
}

variable "clickhouse_user" {
  description = "ClickHouse username"
  type        = string
  default     = "default"
}

variable "clickhouse_password" {
  description = "ClickHouse password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "clickhouse_database" {
  description = "ClickHouse database name"
  type        = string
  default     = "default"
}

variable "clickhouse_tls" {
  description = "Enable TLS for ClickHouse"
  type        = bool
  default     = true
}

variable "clickhouse_ca_cert" {
  description = "ClickHouse CA certificate (PEM)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "allow_gke_gateway_traffic" {
  description = "Admit Google Cloud load balancer and health-check traffic (130.211.0.0/22, 35.191.0.0/16) to LangSmith pods. Needed for ingress_type = \"gke\", where the load balancer reaches pods directly through container-native NEGs."
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# Labels
#------------------------------------------------------------------------------
variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
