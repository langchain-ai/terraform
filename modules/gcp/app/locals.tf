#------------------------------------------------------------------------------
# Resolve infrastructure values
#
# Each value: explicit variable wins, otherwise null → precondition error.
# The pull-infra-outputs.sh script (make init-app) populates these from
# the infra module's terraform output, so in the common case all of these
# are set via infra.auto.tfvars.json automatically.
#------------------------------------------------------------------------------

locals {
  project_id                   = var.project_id
  region                       = var.region
  environment                  = var.environment
  name_prefix                  = var.name_prefix
  cluster_name                 = var.cluster_name
  workload_identity_annotation = var.workload_identity_annotation
  bucket_name                  = var.bucket_name
  ingress_ip                   = var.ingress_ip
  tls_certificate_source       = var.tls_certificate_source
  namespace                    = var.langsmith_namespace

  # Helm values path — reads from the active values directory (same files the scripts path uses).
  # init-values.sh copies from examples/ into values/ on first run; the app module reads from there.
  values_path = coalesce(var.helm_values_path, "${path.module}/../helm/values")

  # Derived
  hostname = coalesce(var.hostname, local.ingress_ip, "")
  protocol = local.tls_certificate_source == "none" ? "http" : "https"

  # Workload Identity annotation block — reused across all components.
  # Null-safe: if IAM module was not enabled (no WI SA), annotations map is empty.
  wi_annotations = (
    local.workload_identity_annotation != null && local.workload_identity_annotation != ""
    ? { "iam.gke.io/gcp-service-account" = local.workload_identity_annotation }
    : {}
  )

  # Components that need Workload Identity service account annotations.
  # Addon components are only included when their feature is enabled —
  # avoids generating overrides for service accounts that don't exist.
  wi_components = concat(
    ["platformBackend", "backend", "ingestQueue", "queue"],
    var.enable_agent_deploys ? ["hostBackend", "listener", "operator"] : [],
  )

  # Overrides — env-specific config generated from Terraform variables.
  # Equivalent to what init-values.sh writes into values-overrides.yaml.
  overrides_values = merge(
    {
      config = {
        hostname             = local.hostname
        initialOrgAdminEmail = var.admin_email
        deployment = {
          url = "${local.protocol}://${local.hostname}"
        }
        blobStorage = {
          bucketName = local.bucket_name
          apiURL     = "https://storage.googleapis.com"
        }
      }
      commonEnv = concat(
        [],
        var.enable_usage_telemetry ? [{ name = "PHONE_HOME_USAGE_REPORTING_ENABLED", value = "true" }] : [],
      )
    },
    # Postgres/Redis: disable external if using in-cluster
    var.postgres_source != "external" ? { postgres = { external = { enabled = false } } } : {},
    var.redis_source != "external" ? { redis = { external = { enabled = false } } } : {},
    # Workload Identity annotations for each component
    length(local.wi_annotations) > 0 ? { for component in local.wi_components : component => {
      serviceAccount = {
        annotations = local.wi_annotations
      }
    } } : {},
  )

  # Agent deploys override — TLS flag only (dynamic per environment).
  # Resource sizing and operator template come from the YAML file.
  agent_deploys_overrides = {
    config = {
      deployment = {
        tlsEnabled = local.tls_certificate_source != "none"
      }
    }
  }

  # Insights override — ClickHouse connection details.
  # The YAML file enables the feature; this layers on the actual connection config.
  insights_overrides = {
    clickhouse = {
      external = {
        host               = var.clickhouse_host
        port               = tostring(var.clickhouse_port)
        database           = var.clickhouse_database
        user               = var.clickhouse_username
        tls                = var.clickhouse_tls
        existingSecretName = "langsmith-clickhouse"
      }
    }
  }

  # Chart version. Enabling SmithDB never moves the chart line implicitly — the
  # operator picks the version. The pattern accepts semver prereleases and build
  # metadata because the 0.16 line has only ever published release candidates,
  # and rejects range syntax because Helm never matches a prerelease against a
  # range, so "~0.16.0" would resolve to no chart at all.
  chart_version_effective         = var.chart_version
  smithdb_chart_version_supported = can(regex("^0\\.(1[6-9]|[2-9][0-9]|[1-9][0-9]{2,})(\\.[0-9]+)?(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$", var.chart_version))

  # SmithDB overrides — env-specific config generated from the infra outputs,
  # plus the staged LangSmith integration gates. Equivalent to what
  # init-values.sh writes into langsmith-values-smithdb-overrides.yaml, and
  # layered last for the same reason.
  smithdb_overrides = var.enable_smithdb ? {
    smithdb = {
      serviceAccount = {
        annotations = {
          # Workload Identity — binds the chart's SmithDB service account to the
          # dedicated GCP service account holding objectAdmin on the bucket.
          "iam.gke.io/gcp-service-account" = var.smithdb_gsa_email
        }
      }
      config = {
        existingSecretName = var.smithdb_metastore_secret_name
        objectStore = {
          type   = "gcs"
          bucket = var.smithdb_object_store_bucket
        }
        metastore = {
          hostSecretKey     = "smithdb_metastore_db_host"
          databaseSecretKey = "smithdb_metastore_db_name"
          usernameSecretKey = "smithdb_metastore_db_username"
          passwordSecretKey = "smithdb_metastore_db_password"
          port              = tostring(var.smithdb_metastore_port)
          useSsl            = var.smithdb_metastore_use_ssl
        }
      }
      # The migration Job reads its own useSsl leaf, which the chart defaults to
      # false. Cloud SQL is created with ssl_mode = ENCRYPTED_ONLY, so leaving it
      # unset makes the pre-install hook fail on connect and takes the release
      # down with it.
      metastoreMigration = {
        useSsl = var.smithdb_metastore_use_ssl
      }
      # The chart refuses to render with the migration gate on unless taskdb has
      # a credential, so always point it at the Terraform-created secret.
      migration = {
        taskdb = {
          postgres = {
            auth = {
              existingSecretName = var.smithdb_taskdb_secret_name
            }
          }
        }
      }
      langsmith = {
        ingestion = {
          enabled = var.smithdb_ingestion_enabled
        }
        migration = {
          enabled = var.smithdb_migration_enabled
        }
        query = {
          enabled = var.smithdb_query_enabled
        }
      }
    }
  } : {}
}

#------------------------------------------------------------------------------
# Preconditions — fail early with clear messages
#------------------------------------------------------------------------------

resource "terraform_data" "validate_required" {
  lifecycle {
    precondition {
      condition     = local.project_id != null
      error_message = "project_id is required — set var.project_id or run: make init-app"
    }
    precondition {
      condition     = local.region != null
      error_message = "region is required — set var.region or run: make init-app"
    }
    precondition {
      condition     = local.cluster_name != null
      error_message = "cluster_name is required — set var.cluster_name or run: make init-app"
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
      condition     = !var.enable_agent_builder || var.enable_agent_deploys
      error_message = "enable_agent_builder requires enable_agent_deploys = true"
    }
    precondition {
      condition     = !var.enable_polly || var.enable_agent_deploys
      error_message = "enable_polly requires enable_agent_deploys = true"
    }
    precondition {
      condition     = !var.enable_insights || var.clickhouse_host != ""
      error_message = "clickhouse_host is required when enable_insights = true"
    }
    precondition {
      condition     = fileexists("${local.values_path}/langsmith-values.yaml")
      error_message = "Helm values files not found at ${local.values_path}/langsmith-values.yaml. Run: make init-values"
    }
    precondition {
      condition     = !var.enable_smithdb || fileexists("${local.values_path}/langsmith-values-smithdb.yaml")
      error_message = "enable_smithdb = true but ${local.values_path}/langsmith-values-smithdb.yaml is missing. Run: make init-values"
    }
    precondition {
      condition     = !var.enable_smithdb || (var.smithdb_object_store_bucket != null && var.smithdb_gsa_email != null)
      error_message = "smithdb_object_store_bucket and smithdb_gsa_email are required when enable_smithdb = true. Run: make init-app (they come from the infra outputs)."
    }
    precondition {
      condition     = !var.enable_smithdb || local.smithdb_chart_version_supported
      error_message = "enable_smithdb requires an exact chart_version of 0.16 or newer, for example \"0.16.0-rc.22\". Ranges such as \"~0.16.0\" never match the prerelease-only 0.16 line, and enabling SmithDB does not move the chart line on its own."
    }
    precondition {
      condition     = var.enable_smithdb || !(var.smithdb_ingestion_enabled || var.smithdb_migration_enabled || var.smithdb_query_enabled)
      error_message = "SmithDB integration gates require enable_smithdb = true."
    }
    precondition {
      condition     = !var.smithdb_migration_enabled || var.smithdb_ingestion_enabled
      error_message = "smithdb_migration_enabled requires smithdb_ingestion_enabled = true."
    }
    precondition {
      condition     = !var.smithdb_query_enabled || var.smithdb_ingestion_enabled
      error_message = "smithdb_query_enabled requires smithdb_ingestion_enabled = true."
    }
  }
}
