# Conditional wiring in the Azure root: every optional module, asserted in both
# directions. mock_provider means no cloud credentials, no state, and no API
# calls, so these run in the PR path.
#
# Each run sets the variable it asserts on rather than relying on the default,
# so a default change shows up as a failing assertion here and not as a test
# that quietly stops covering anything.

mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
  # Throwaway keypair, generated for this fixture and the private half discarded.
  # create_bastion = true with the empty default fails inside azurerm's own
  # schema validator rather than at a precondition on the root variable.
  bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLvAeJ8tG7HNaDGXt2T05HJmj1X1qaP+jb2MTDRBLNEPOwsvT7UrCsGp/8AB5MZIyMmRLoNOz1GTRWWBQsgQoKJD1jPUJNvSDZ16g4yFV4wX2o6nxooi53U9L6JWH6XrXn2Ozhca7tC0o26Oyd2toFrf8An8H8Gnwsdr3EOIrqvL0ZxXvjgGLZDx9auENfrlrhob8+6QLsZkEzphDWqKhbYpy46WEYtwHvKRpYX1YlDN6jbObN0wifqu98UZNsIr7FoZR3luNj1bA/kjqUC61GW6UziPyCoMhk3Jf9IMQ24OBXn2Xp4JWMZ3jYp+IL1fi9YVgofvsOvlYM2XGtmgzt plan-tests-fixture"
}

# ── Optional modules, off ────────────────────────────────────────────────────

run "optional_modules_absent_when_flags_are_false" {
  command = plan

  variables {
    create_waf         = false
    create_diagnostics = false
    create_bastion     = false
    create_dns_zone    = false
  }

  assert {
    condition     = length(module.waf) == 0
    error_message = "create_waf = false still planned the waf module"
  }
  assert {
    condition     = length(module.diagnostics) == 0
    error_message = "create_diagnostics = false still planned the diagnostics module"
  }
  assert {
    condition     = length(module.bastion) == 0
    error_message = "create_bastion = false still planned the bastion module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "create_dns_zone = false still planned the dns module"
  }
}

# ── Optional modules, on ─────────────────────────────────────────────────────
# One run per flag. A single run with everything on would pass while three of
# the four flags were wired to the same variable.

run "create_waf_adds_only_the_waf" {
  command = plan

  variables {
    create_waf = true
  }

  assert {
    condition     = length(module.waf) == 1
    error_message = "create_waf = true did not plan the waf module"
  }
  assert {
    condition     = length(module.diagnostics) == 0
    error_message = "create_waf = true also planned diagnostics"
  }
}

run "create_diagnostics_adds_only_diagnostics" {
  command = plan

  variables {
    create_diagnostics = true
  }

  assert {
    condition     = length(module.diagnostics) == 1
    error_message = "create_diagnostics = true did not plan the diagnostics module"
  }
  assert {
    condition     = length(module.waf) == 0
    error_message = "create_diagnostics = true also planned the waf"
  }
}

run "create_dns_zone_adds_only_dns" {
  command = plan

  variables {
    create_dns_zone = true
  }

  assert {
    condition     = length(module.dns) == 1
    error_message = "create_dns_zone = true did not plan the dns module"
  }
  assert {
    condition     = length(module.bastion) == 0
    error_message = "create_dns_zone = true also planned the bastion"
  }
}

run "create_bastion_adds_only_bastion" {
  command = plan

  variables {
    create_bastion = true
  }

  assert {
    condition     = length(module.bastion) == 1
    error_message = "create_bastion = true did not plan the bastion module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "create_bastion = true also planned the dns zone"
  }
}

# ── Data plane source switches ───────────────────────────────────────────────
# in-cluster means the chart runs it, so Terraform must plan nothing.

run "external_postgres_is_planned" {
  command = plan

  variables {
    postgres_source = "external"
  }

  assert {
    condition     = length(module.postgres) == 1
    error_message = "postgres_source = external did not plan the flexible server"
  }
}

run "in_cluster_postgres_plans_nothing" {
  command = plan

  variables {
    postgres_source = "in-cluster"
  }

  assert {
    condition     = length(module.postgres) == 0
    error_message = "postgres_source = in-cluster still planned a flexible server"
  }
}

run "external_redis_is_planned" {
  command = plan

  variables {
    redis_source = "external"
  }

  assert {
    condition     = length(module.redis) == 1
    error_message = "redis_source = external did not plan Azure Managed Redis"
  }
}

run "in_cluster_redis_plans_nothing" {
  command = plan

  variables {
    redis_source = "in-cluster"
  }

  assert {
    condition     = length(module.redis) == 0
    error_message = "redis_source = in-cluster still planned Azure Managed Redis"
  }
}
