# langsmith_image_pull_secret_name: the pull Secret for the pods the operator
# creates, carried by the service accounts in the LangSmith namespace so that
# every apply keeps it. Unset attaches nothing; set, it reaches langsmith-ksa,
# the backend account, SmithDB's when enabled, and the namespace's default
# account, whose names follow the release name (SmithDB needs zones, as its
# own check says). The last run breaks the name.
# The list output is compared with tolist(), because a bare [ ] is a tuple and
# == never treats the two as equal; the empty case uses length().

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

run "unset_attaches_nothing" {
  command = plan

  assert {
    condition     = length(output.langsmith_image_pull_secret_service_accounts) == 0
    error_message = "Without langsmith_image_pull_secret_name no service account should carry a pull Secret, got ${jsonencode(output.langsmith_image_pull_secret_service_accounts)}"
  }

  assert {
    condition     = output.langsmith_image_pull_secret_name == ""
    error_message = "Without langsmith_image_pull_secret_name the output should be empty, got \"${output.langsmith_image_pull_secret_name}\""
  }
}

run "set_reaches_langsmith_ksa_backend_and_default" {
  command = plan

  variables {
    langsmith_image_pull_secret_name = "nexus-pull"
  }

  assert {
    condition     = output.langsmith_image_pull_secret_service_accounts == tolist(["langsmith-ksa", "langsmith-backend", "default"])
    error_message = "The pull Secret should reach langsmith-ksa, the backend account and default, got ${jsonencode(output.langsmith_image_pull_secret_service_accounts)}"
  }

  assert {
    condition     = output.langsmith_image_pull_secret_name == "nexus-pull"
    error_message = "The output should carry the Secret name, got \"${output.langsmith_image_pull_secret_name}\""
  }
}

run "set_with_smithdb_reaches_its_account_too" {
  command = plan

  variables {
    langsmith_image_pull_secret_name = "nexus-pull"
    enable_smithdb                   = true
    availability_zones               = ["1", "2", "3"]
  }

  assert {
    condition     = output.langsmith_image_pull_secret_service_accounts == tolist(["langsmith-ksa", "langsmith-backend", "langsmith-smithdb", "default"])
    error_message = "With SmithDB on, its account should carry the pull Secret as well, got ${jsonencode(output.langsmith_image_pull_secret_service_accounts)}"
  }
}

run "account_names_follow_the_release_name" {
  command = plan

  variables {
    langsmith_image_pull_secret_name = "nexus-pull"
    langsmith_release_name           = "ls"
    enable_smithdb                   = true
    availability_zones               = ["1", "2", "3"]
  }

  assert {
    condition     = output.langsmith_image_pull_secret_service_accounts == tolist(["langsmith-ksa", "ls-langsmith-backend", "ls-langsmith-smithdb", "default"])
    error_message = "The backend and SmithDB accounts should follow the release fullname, got ${jsonencode(output.langsmith_image_pull_secret_service_accounts)}"
  }
}

run "refuses_a_name_that_is_not_a_secret_name" {
  command = plan

  variables {
    langsmith_image_pull_secret_name = "Nexus_Pull"
  }

  expect_failures = [var.langsmith_image_pull_secret_name]
}
