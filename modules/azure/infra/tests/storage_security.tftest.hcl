# Storage security defaults: no Shared Key, no anonymous blob access, copies only
# from the same Entra tenant, on both the trace-blob and SmithDB accounts. These
# are what Azure security-benchmark policies deny or audit, and nothing in the
# install needs the looser settings.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# Both azapi lists (clusters here, storage accounts in the root) take this
# default unless a run overrides one.
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [], accounts = [] }
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
  name_prefix             = "test"
  unique_resource_names   = false
}

run "defaults_close_keys_anonymous_access_and_copy_scope" {
  command = plan

  assert {
    condition     = module.blob.shared_access_key_enabled == false
    error_message = "The trace-blob account allows Shared Key by default"
  }

  assert {
    condition     = module.blob.allow_nested_items_to_be_public == false
    error_message = "The trace-blob account allows anonymous blob access"
  }

  assert {
    condition     = module.blob.allowed_copy_scope == "AAD"
    error_message = "The trace-blob account's copy scope is not AAD by default"
  }
}

run "shared_key_is_an_opt_in" {
  command = plan

  variables {
    storage_shared_access_key_enabled = true
  }

  assert {
    condition     = module.blob.shared_access_key_enabled == true
    error_message = "storage_shared_access_key_enabled = true did not reach the trace-blob account"
  }
}

run "copy_scope_private_link" {
  command = plan

  variables {
    storage_allowed_copy_scope = "PrivateLink"
  }

  assert {
    condition     = module.blob.allowed_copy_scope == "PrivateLink"
    error_message = "storage_allowed_copy_scope = PrivateLink did not reach the trace-blob account"
  }
}

run "copy_scope_empty_means_any" {
  command = plan

  variables {
    storage_allowed_copy_scope = ""
  }

  assert {
    condition     = module.blob.allowed_copy_scope == null
    error_message = "storage_allowed_copy_scope = \"\" did not leave the copy scope unset"
  }
}

run "copy_scope_rejects_other_values" {
  command = plan

  variables {
    storage_allowed_copy_scope = "Anywhere"
  }

  expect_failures = [
    var.storage_allowed_copy_scope,
  ]
}

run "smithdb_account_gets_the_same_defaults" {
  command = plan

  variables {
    enable_smithdb     = true
    availability_zones = ["1", "2", "3"]
  }

  assert {
    condition     = module.smithdb[0].storage_shared_access_key_enabled == false && module.smithdb[0].storage_allowed_copy_scope == "AAD"
    error_message = "The SmithDB account did not get Shared Key off and copy scope AAD"
  }
}

# SmithDB's static-key opt-in must not loosen the trace-blob account, which
# never uses a key.
run "smithdb_static_key_opt_in_leaves_trace_blob_closed" {
  command = plan

  variables {
    enable_smithdb                            = true
    availability_zones                        = ["1", "2", "3"]
    smithdb_storage_shared_access_key_enabled = true
  }

  assert {
    condition     = module.smithdb[0].storage_shared_access_key_enabled == true
    error_message = "smithdb_storage_shared_access_key_enabled = true did not reach the SmithDB account"
  }

  assert {
    condition     = module.blob.shared_access_key_enabled == false
    error_message = "SmithDB's static-key opt-in turned Shared Key on for the trace-blob account"
  }
}

run "trace_blob_opt_in_leaves_smithdb_closed" {
  command = plan

  variables {
    enable_smithdb                    = true
    availability_zones                = ["1", "2", "3"]
    storage_shared_access_key_enabled = true
  }

  assert {
    condition     = module.blob.shared_access_key_enabled == true && module.smithdb[0].storage_shared_access_key_enabled == false
    error_message = "storage_shared_access_key_enabled reached the SmithDB account, or did not reach the trace-blob account"
  }
}
