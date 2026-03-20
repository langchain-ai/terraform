#------------------------------------------------------------------------------
# Resolve infrastructure values
#
# Each value: explicit variable wins, otherwise null → precondition error.
# The pull-infra-outputs.sh script (make init-app) populates these from
# the infra module's terraform output, so in the common case all of these
# are set via infra.auto.tfvars.json automatically.
#------------------------------------------------------------------------------

locals {
  region                  = var.region
  name_prefix             = var.name_prefix
  environment             = var.environment
  cluster_name            = var.cluster_name
  langsmith_irsa_role_arn = var.langsmith_irsa_role_arn
  bucket_name             = var.bucket_name
  alb_arn                 = var.alb_arn
  alb_dns_name            = var.alb_dns_name
  tls_certificate_source  = var.tls_certificate_source
  namespace               = var.langsmith_namespace

  # Helm values path — reads from the active values directory (same files the scripts path uses).
  # init-values.sh copies from examples/ into values/ on first run; the app module reads from there.
  values_path = coalesce(var.helm_values_path, "${path.module}/../helm/values")

  # Derived
  ssm_prefix = "/langsmith/${local.name_prefix}-${local.environment}"
  hostname   = coalesce(var.hostname, local.alb_dns_name, "")
  protocol   = local.tls_certificate_source == "none" ? "http" : "https"

  tls_enabled_for_deploys = var.tls_enabled_for_deploys != null ? var.tls_enabled_for_deploys : (local.tls_certificate_source != "none")

  # Ingress annotations — base set, then conditionals for TLS and pre-provisioned ALB
  ingress_annotations = merge(
    {
      "alb.ingress.kubernetes.io/scheme"       = var.alb_scheme
      "alb.ingress.kubernetes.io/target-type"  = "ip"
      "alb.ingress.kubernetes.io/listen-ports" = local.tls_certificate_source == "none" ? "[{\"HTTP\": 80}]" : "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
    },
    # TLS: redirect HTTP→HTTPS
    local.tls_certificate_source != "none" ? {
      "alb.ingress.kubernetes.io/ssl-redirect" = "443"
    } : {},
    # ACM: attach certificate ARN
    local.tls_certificate_source == "acm" ? {
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
    } : {},
    local.alb_arn != null && local.alb_arn != "" ? {
      "alb.ingress.kubernetes.io/load-balancer-arn" = local.alb_arn
    } : {},
  )

  # IRSA annotation block — reused across all components
  irsa_annotations = {
    "eks.amazonaws.com/role-arn" = local.langsmith_irsa_role_arn
  }

  # Components that need IRSA service account annotations.
  # Addon components are only included when their feature is enabled —
  # avoids generating overrides for service accounts that don't exist.
  irsa_components = concat(
    ["platformBackend", "backend", "ingestQueue", "queue"],
    var.enable_agent_deploys ? ["hostBackend", "listener", "operator"] : [],
  )
}

#------------------------------------------------------------------------------
# Preconditions — fail early with clear messages
#------------------------------------------------------------------------------

resource "terraform_data" "validate_required" {
  lifecycle {
    precondition {
      condition     = local.region != null
      error_message = "region is required — set var.region or run: make init-app"
    }
    precondition {
      condition     = local.name_prefix != null
      error_message = "name_prefix is required — set var.name_prefix or run: make init-app"
    }
    precondition {
      condition     = local.environment != null
      error_message = "environment is required — set var.environment or run: make init-app"
    }
    precondition {
      condition     = local.cluster_name != null
      error_message = "cluster_name is required — set var.cluster_name or run: make init-app"
    }
    precondition {
      condition     = local.langsmith_irsa_role_arn != null
      error_message = "langsmith_irsa_role_arn is required — set var.langsmith_irsa_role_arn or run: make init-app"
    }
    precondition {
      condition     = local.bucket_name != null
      error_message = "bucket_name is required — set var.bucket_name or run: make init-app"
    }
    precondition {
      condition     = local.tls_certificate_source != null
      error_message = "tls_certificate_source is required — set var.tls_certificate_source or run: make init-app"
    }
    precondition {
      condition     = local.namespace != null
      error_message = "langsmith_namespace is required — set var.langsmith_namespace or run: make init-app"
    }
    precondition {
      condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.admin_email))
      error_message = "admin_email must be a valid email address — update it in app/terraform.tfvars"
    }
    precondition {
      condition     = local.tls_certificate_source != "acm" || (var.acm_certificate_arn != null && var.acm_certificate_arn != "")
      error_message = "acm_certificate_arn is required when tls_certificate_source = acm — set var.acm_certificate_arn or run: make init-app"
    }
    precondition {
      condition     = !var.enable_agent_builder || var.enable_agent_deploys
      error_message = "enable_agent_builder requires enable_agent_deploys = true"
    }
    precondition {
      condition     = !var.enable_insights || var.clickhouse_host != ""
      error_message = "clickhouse_host is required when enable_insights = true"
    }
    precondition {
      condition     = fileexists("${local.values_path}/langsmith-values.yaml")
      error_message = "Helm values files not found at ${local.values_path}/. Run: make init-values (copies templates from helm/values/examples/)"
    }
  }
}
