# aks_custom_ca_trust_certificate_files: PEM files whose CA certificates AKS
# installs in every Linux node's trust store, so containerd on the node can pull
# from an image mirror whose certificate an internal CA signed. The cluster
# resource reads each file, trims the whitespace around the certificate block,
# and base64-encodes it with one trailing newline, one entry per file in the
# order given, so a clean fixture encodes exactly as filebase64 reads it; no files leaves the attribute null, so a cluster created before
# the setting plans no change. The fixtures under tests/fixtures/ are throwaway
# self-signed certificates with no key kept. The expected values are tolist()
# because the output is a list and a bare [...] is a tuple, which == never
# treats as equal. Each refusal run breaks one input. A file whose content is
# not the one certificate block alone (a key after it, a byte-order mark, an
# openssl "Bag Attributes" preamble) is refused; the key block in the fixture
# is twelve characters of base64 and not a key. Attach mode skips every file
# check: byo_network.tftest.hcl has that run, with the attach overrides.

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

run "no_files_leaves_the_attribute_null" {
  command = plan

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == null
    error_message = "With no aks_custom_ca_trust_certificate_files the cluster should set no custom CA trust certificates, so a cluster created before the setting plans no change"
  }
}

run "one_file_is_one_base64_entry" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-1.pem")])
    error_message = "One PEM file should become one entry, the file's bytes base64-encoded as filebase64 reads them"
  }
}

run "two_files_keep_their_order" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-2.pem", "tests/fixtures/ca-1.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-2.pem"), filebase64("tests/fixtures/ca-1.pem")])
    error_message = "Two PEM files should become two entries in the order given"
  }
}

run "whitespace_around_the_block_does_not_change_the_entry" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-surrounding-whitespace.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-1.pem")])
    error_message = "A blank line before the certificate block and extra newlines after it should encode exactly as the clean file does, so an editor's whitespace change does not replace every node"
  }
}

# Eleven distinct spellings of the two fixtures, so only the 10-file limit fails
# and not the refusal of a file listed twice.
run "refuses_an_eleventh_certificate" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = [
      "tests/fixtures/ca-1.pem", "./tests/fixtures/ca-1.pem", "tests/./fixtures/ca-1.pem", "./tests/./fixtures/ca-1.pem",
      "tests/fixtures/../fixtures/ca-1.pem", "./tests/fixtures/../fixtures/ca-1.pem",
      "tests/fixtures/ca-2.pem", "./tests/fixtures/ca-2.pem", "tests/./fixtures/ca-2.pem", "./tests/./fixtures/ca-2.pem",
      "tests/fixtures/../fixtures/ca-2.pem",
    ]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_file_listed_twice" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1.pem", "tests/fixtures/ca-2.pem", "tests/fixtures/ca-1.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_missing_file" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1.pem", "tests/fixtures/does-not-exist.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_file_that_is_not_a_certificate" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/not-a-cert.txt"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_two_certificates_in_one_file" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-two-in-one.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_crlf_line_endings" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-crlf.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_certificate_followed_by_its_key" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-plus-key.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_an_openssl_bag_attributes_preamble" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-bag-attributes.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_byte_order_mark" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-bom.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}
