# Conditional wiring in the GCP root: every optional module, asserted in both
# directions. mock_provider means no cloud credentials, no state, and no API
# calls, so these run in the PR path.
#
# Each run sets every flag it asserts on rather than relying on the default, so
# a default change shows up as a failing assertion here and not as a test that
# quietly stops covering anything.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "local" {}

variables {
  project_id = "langsmith-plan-tests"
  # postgres_source defaults to external, and both the root precondition and
  # the postgres module's own length validation require a value.
  postgres_password = "fixture-not-a-real-secret-Aa1"
}

# master_auth is a computed nested block, and a mock provider returns computed
# blocks as an empty list rather than as unknown. modules/k8s-cluster/outputs.tf
# indexes master_auth[0], so without this override every run fails on that index
# instead of on what it asserts. The cost is that the cluster module itself is
# not planned here, so its autopilot conditional needs its own test once that
# output stops hard-indexing.
override_module {
  target = module.gke_cluster
  outputs = {
    cluster_name   = "langsmith-plan-tests-gke"
    cluster_id     = "projects/langsmith-plan-tests/locations/us-central1/clusters/langsmith-plan-tests-gke"
    endpoint       = "10.0.0.1"
    ca_certificate = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
    location       = "us-central1"
  }
}

# ── Optional modules, off ────────────────────────────────────────────────────

run "optional_modules_absent_when_flags_are_false" {
  command = plan

  variables {
    enable_sandboxes             = false
    enable_smithdb               = false
    enable_gcp_iam_module        = false
    enable_secret_manager_module = false
    enable_dns_module            = false
    install_ingress              = false
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 0
    error_message = "enable_sandboxes = false still planned the JuiceFS Redis"
  }
  assert {
    condition     = length(module.smithdb) == 0
    error_message = "enable_smithdb = false still planned SmithDB"
  }
  assert {
    condition     = length(module.iam) == 0
    error_message = "enable_gcp_iam_module = false still planned the iam module"
  }
  assert {
    condition     = length(module.secrets) == 0
    error_message = "enable_secret_manager_module = false still planned the secrets module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "enable_dns_module = false still planned the dns module"
  }
  assert {
    condition     = length(module.ingress) == 0
    error_message = "install_ingress = false still planned the ingress module"
  }
}

# ── Optional modules, one flag at a time ─────────────────────────────────────
# Every flag starts false and exactly one is flipped, so a run that also plans a
# sibling module means two flags read the same variable.

run "enable_gcp_iam_module_adds_only_iam" {
  command = plan

  variables {
    enable_gcp_iam_module        = true
    enable_secret_manager_module = false
    enable_dns_module            = false
    install_ingress              = false
  }

  assert {
    condition     = length(module.iam) == 1
    error_message = "enable_gcp_iam_module = true did not plan the iam module"
  }
  assert {
    condition     = length(module.secrets) == 0
    error_message = "enable_gcp_iam_module = true also planned the secrets module"
  }
}

run "enable_secret_manager_module_adds_only_secrets" {
  command = plan

  variables {
    enable_gcp_iam_module        = false
    enable_secret_manager_module = true
    enable_dns_module            = false
    install_ingress              = false
  }

  assert {
    condition     = length(module.secrets) == 1
    error_message = "enable_secret_manager_module = true did not plan the secrets module"
  }
  assert {
    condition     = length(module.iam) == 0
    error_message = "enable_secret_manager_module = true also planned the iam module"
  }
}

run "enable_dns_module_adds_only_dns" {
  command = plan

  variables {
    enable_gcp_iam_module        = false
    enable_secret_manager_module = false
    enable_dns_module            = true
    install_ingress              = false
  }

  assert {
    condition     = length(module.dns) == 1
    error_message = "enable_dns_module = true did not plan the dns module"
  }
  assert {
    condition     = length(module.ingress) == 0
    error_message = "enable_dns_module = true also planned the ingress module"
  }
}

run "install_ingress_adds_only_ingress" {
  command = plan

  variables {
    enable_gcp_iam_module        = false
    enable_secret_manager_module = false
    enable_dns_module            = false
    install_ingress              = true
  }

  assert {
    condition     = length(module.ingress) == 1
    error_message = "install_ingress = true did not plan the ingress module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "install_ingress = true also planned the dns module"
  }
}

run "enable_sandboxes_adds_the_juicefs_redis" {
  command = plan

  variables {
    enable_sandboxes = true
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 1
    error_message = "enable_sandboxes = true did not plan the JuiceFS Redis"
  }
}

# ── SmithDB ──────────────────────────────────────────────────────────────────

run "smithdb_plans_its_own_node_pool" {
  command = plan

  variables {
    enable_smithdb    = true
    gke_use_autopilot = false
  }

  assert {
    condition     = length(module.smithdb) == 1
    error_message = "enable_smithdb = true did not plan SmithDB"
  }
  assert {
    condition     = length(module.smithdb_nodes) == 1
    error_message = "SmithDB did not plan the Local SSD node pool it needs"
  }
}

run "smithdb_on_autopilot_is_rejected" {
  command = plan

  variables {
    enable_smithdb    = true
    gke_use_autopilot = true
  }

  # SmithDB needs the Local SSD node pools that Autopilot will not let this
  # module create.
  expect_failures = [terraform_data.validate_inputs]
}

# ── Data plane source switches ───────────────────────────────────────────────
# in-cluster means the chart runs it, so Terraform must plan nothing.

run "external_postgres_is_planned" {
  command = plan

  variables {
    postgres_source = "external"
  }

  assert {
    condition     = length(module.cloudsql) == 1
    error_message = "postgres_source = external did not plan Cloud SQL"
  }
}

run "in_cluster_postgres_plans_nothing" {
  command = plan

  variables {
    postgres_source = "in-cluster"
  }

  assert {
    condition     = length(module.cloudsql) == 0
    error_message = "postgres_source = in-cluster still planned Cloud SQL"
  }
}

run "external_redis_is_planned" {
  command = plan

  variables {
    redis_source = "external"
  }

  assert {
    condition     = length(module.redis) == 1
    error_message = "redis_source = external did not plan Memorystore"
  }
}

run "in_cluster_redis_plans_nothing" {
  command = plan

  variables {
    redis_source = "in-cluster"
  }

  assert {
    condition     = length(module.redis) == 0
    error_message = "redis_source = in-cluster still planned Memorystore"
  }
}
