# clickhouse_source = "external" with the connection in Terraform: clickhouse_host
# and its siblings write the langsmith-clickhouse Secret the chart reads, with
# the chart's key names; without clickhouse_host the Secret is init-values.sh's,
# as before. clickhouse_cluster is a value, not a Secret key, and only applies
# to an external ClickHouse. Each refusal run breaks one rule.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# The cluster module lists the subscription's AKS clusters to read the one it
# manages; the generated mock has no such shape, so give it an empty list.
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [] }
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
}

run "external_with_a_host_writes_the_secret" {
  command = plan

  variables {
    clickhouse_source      = "external"
    clickhouse_host        = "ch-repl-replicated.langsmith-data.svc"
    clickhouse_http_port   = 8123
    clickhouse_native_port = 9000
    clickhouse_password    = "fixture-not-a-real-secret"
    clickhouse_tls         = false
    clickhouse_cluster     = "replicated"
  }

  assert {
    condition     = output.clickhouse_secret_name == "langsmith-clickhouse"
    error_message = "With clickhouse_host set, Terraform should write the langsmith-clickhouse Secret, got ${coalesce(output.clickhouse_secret_name, "null")}"
  }

  assert {
    condition     = module.k8s_bootstrap.clickhouse_secret_labels["app.kubernetes.io/managed-by"] == "terraform"
    error_message = "The Secret Terraform writes should carry app.kubernetes.io/managed-by = terraform, the label preflight.sh reads to tell it from one init-values.sh created"
  }
}

run "external_without_a_host_leaves_the_secret_to_init_values" {
  command = plan

  variables {
    clickhouse_source = "external"
  }

  assert {
    condition     = output.clickhouse_secret_name == null
    error_message = "Without clickhouse_host the Secret is init-values.sh's; Terraform should write none"
  }
}

run "in_cluster_writes_no_secret" {
  command = plan

  assert {
    condition     = output.clickhouse_secret_name == null
    error_message = "With the chart's own ClickHouse there is no connection Secret to write"
  }
}

run "refuses_a_host_with_in_cluster_clickhouse" {
  command = plan

  variables {
    clickhouse_host     = "ch.example.com"
    clickhouse_password = "fixture-not-a-real-secret"
  }

  expect_failures = [var.clickhouse_host]
}

run "refuses_a_host_without_a_password" {
  command = plan

  variables {
    clickhouse_source = "external"
    clickhouse_host   = "ch.example.com"
  }

  expect_failures = [var.clickhouse_password]
}

run "refuses_a_host_with_a_scheme_or_port" {
  command = plan

  variables {
    clickhouse_source   = "external"
    clickhouse_host     = "https://ch.example.com:8443"
    clickhouse_password = "fixture-not-a-real-secret"
  }

  expect_failures = [var.clickhouse_host]
}

run "refuses_a_cluster_with_in_cluster_clickhouse" {
  command = plan

  variables {
    clickhouse_cluster = "replicated"
  }

  expect_failures = [var.clickhouse_cluster]
}

run "refuses_a_cluster_name_the_values_file_cannot_carry" {
  command = plan

  variables {
    clickhouse_source   = "external"
    clickhouse_host     = "ch-repl-replicated.langsmith-data.svc"
    clickhouse_password = "fixture-not-a-real-secret"
    clickhouse_cluster  = "repl\"icated"
  }

  expect_failures = [var.clickhouse_cluster]
}
