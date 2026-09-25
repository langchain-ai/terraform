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
    condition     = length(google_storage_bucket_iam_member.sandbox_host_node_juicefs) == 0
    error_message = "enable_sandboxes = false still planned the sandbox node bucket grant"
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

  # The IAM condition embeds the bucket name, which carries the random suffix.
  # A fixed suffix makes the expression known at plan time.
  override_resource {
    target          = random_id.suffix
    override_during = plan
    values          = { hex = "0a1b2c3d" }
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 1
    error_message = "enable_sandboxes = true did not plan the JuiceFS Redis"
  }

  # hostNetwork sandbox-host mounts JuiceFS as the node service account, so the
  # bucket grant must exist for that identity, not only the WI binding.
  assert {
    condition     = length(google_storage_bucket_iam_member.sandbox_host_node_juicefs) == 1
    error_message = "enable_sandboxes = true did not grant the sandbox node service account on the JuiceFS bucket"
  }
  assert {
    condition     = google_storage_bucket_iam_member.sandbox_host_node_juicefs[0].role == "roles/storage.objectAdmin"
    error_message = "the sandbox node bucket grant is not roles/storage.objectAdmin"
  }
  # Sandbox nodes run untrusted code, and the bucket also holds trace data, so
  # the grant must stay limited to the JuiceFS prefix.
  assert {
    condition = strcontains(
      google_storage_bucket_iam_member.sandbox_host_node_juicefs[0].condition[0].expression,
      "projects/_/buckets/langsmith-plan-tests-ls-prod-traces-0a1b2c3d/objects/sandbox-juicefs/\")",
    )
    error_message = "the sandbox node bucket grant is not limited to the JuiceFS object prefix"
  }
  assert {
    condition = strcontains(
      google_storage_bucket_iam_member.sandbox_host_node_juicefs[0].condition[0].expression,
      "objectListPrefix\", \"\").startsWith(\"sandbox-juicefs/\")",
    )
    error_message = "the sandbox node bucket grant does not limit list calls to the JuiceFS prefix"
  }
}

# ── Sandbox-host pool size ──────────────────────────────────────────────────

run "sandbox_host_machine_type_is_small_outside_production" {
  command = plan

  variables {
    enable_sandboxes = true
    sizing_profile   = "dev"
  }

  assert {
    condition     = output.sandbox_host_machine_type == "n2-standard-8"
    error_message = "sizing_profile = dev did not resolve the sandbox-host machine type to n2-standard-8"
  }
}

run "sandbox_host_machine_type_is_large_for_production" {
  command = plan

  variables {
    enable_sandboxes = true
    sizing_profile   = "production"
  }

  assert {
    condition     = output.sandbox_host_machine_type == "n2-standard-32"
    error_message = "sizing_profile = production did not resolve the sandbox-host machine type to n2-standard-32"
  }
}

run "sandbox_host_machine_type_production_large_matches_production" {
  command = plan

  variables {
    enable_sandboxes = true
    sizing_profile   = "production-large"
  }

  assert {
    condition     = output.sandbox_host_machine_type == "n2-standard-32"
    error_message = "sizing_profile = production-large did not resolve like production"
  }
}

run "sandbox_host_machine_type_explicit_value_wins" {
  command = plan

  variables {
    enable_sandboxes          = true
    sizing_profile            = "production"
    sandbox_host_machine_type = "n2-standard-8"
  }

  assert {
    condition     = output.sandbox_host_machine_type == "n2-standard-8"
    error_message = "an explicit sandbox_host_machine_type did not override sizing_profile"
  }
}

# The per-zone minimum defaults to 0, so a max of 0 plans. An explicit minimum
# above the max fails the precondition.
run "sandbox_host_max_zero_is_allowed_with_the_default_minimum" {
  command = plan

  variables {
    enable_sandboxes            = true
    sandbox_host_max_node_count = 0
  }
}

run "sandbox_host_max_below_min_is_rejected" {
  command = plan

  variables {
    enable_sandboxes            = true
    sandbox_host_min_node_count = 1
    sandbox_host_max_node_count = 0
  }

  expect_failures = [terraform_data.validate_inputs]
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
