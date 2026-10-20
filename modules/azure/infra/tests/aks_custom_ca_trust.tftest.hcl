# aks_custom_ca_trust_certificate_files: PEM files whose CA certificates AKS
# installs in every Linux node's trust store, so containerd on the node can pull
# from an image mirror whose certificate an internal CA signed. The cluster
# resource reads each file, trims the whitespace around the certificate block,
# and base64-encodes it with one trailing newline, one entry per file in the
# order given, so a clean fixture encodes exactly as filebase64 reads it; no files leaves the attribute null, so a cluster created before
# the setting plans no change. The fixtures under tests/fixtures/ are throwaway
# self-signed certificates with no key kept. The expected values are tolist()
# because the output is a list and a bare [...] is a tuple, which == never
# treats as equal. Each refusal run breaks one input. A file is one entry,
# its trimmed content plus one newline: one certificate block or a bundle of
# several, with # comment lines and blank lines at most around them. A key before or after a
# certificate, a byte-order mark, or an openssl "Bag Attributes" preamble is
# refused. Comments and bundles pass because AKS keeps an entry as given and a
# cluster may already hold one written from such a file; a clean fixture, one
# trailing newline and nothing before the first block, encodes exactly as
# filebase64 reads it, which is why the acceptance runs compare against it. The key blocks in the fixtures are twelve characters of base64
# and not keys. Attach mode skips every file
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

run "accepts_a_bundle_of_certificates_in_one_file" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-two-in-one.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-two-in-one.pem")])
    error_message = "A file holding several certificates should be one entry, its trimmed content plus one newline, which for this clean fixture is the file as filebase64 reads it: a cluster can already hold a bundle entry"
  }
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

run "accepts_comment_lines_above_the_certificate" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-comment.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-1-comment.pem")])
    error_message = "Comment lines above the certificate block should pass, and the entry should carry them: AKS keeps an entry as given, and a cluster may already hold one with a comment; for this clean fixture the entry is the file as filebase64 reads it"
  }
}

run "refuses_a_key_before_the_certificate" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-key-first.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

# A file that passes the checks but puts no working CA on the nodes is the
# worst outcome: every node is replaced and pulls still fail with an unknown
# authority. The node's PEM decoder takes a block only as whole lines, the
# BEGIN and END markers alone on theirs and base64 between, so the file
# checks do the same. Each of the next three refusals is a file that AKS
# would accept and never load.
run "refuses_a_commented_out_certificate" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-commented-out.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

# A key commented out line by line left nothing for the content check to see,
# and AKS would have stored it with the certificate.
run "refuses_a_private_key_commented_out_after_the_certificate" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-plus-commented-key.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_commented_key_whose_markers_carry_spaces" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-plus-commented-key-spaced.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_commented_key_with_four_dashes_in_lowercase" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-plus-commented-key-lowercase.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_commented_key_body_with_its_markers_deleted" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-plus-commented-key-body-only.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

# A live certificate plus a commented-out old one passes on this patch line, as
# it has since v0.16.118 (main refuses it), as one entry equal to the file.
run "accepts_a_commented_out_old_certificate_beside_a_live_one" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-plus-commented-old-cert.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-1-plus-commented-old-cert.pem")])
    error_message = "A commented-out old certificate beside a live one should pass on release/0.16 as one entry equal to the file"
  }
}

# The boundary on the other side: prose that names the markers mid-line and a
# hex fingerprint on its own comment line pass, as one entry equal to the file.
run "accepts_prose_naming_the_markers_and_a_hex_fingerprint" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-prose-and-fingerprint.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-1-prose-and-fingerprint.pem")])
    error_message = "Prose naming the markers and a hex fingerprint line should pass as one entry equal to the file"
  }
}

run "refuses_a_note_after_the_end_marker" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-1-note-after-end.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

run "refuses_a_block_whose_body_is_not_base64" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-not-base64-body.pem"]
  }

  expect_failures = [var.aks_custom_ca_trust_certificate_files]
}

# A comment line above a five-certificate bundle with one trailing newline is
# the shape a cluster already holds; it must keep passing as one entry.
run "accepts_a_comment_line_above_a_five_certificate_bundle" {
  command = plan

  variables {
    aks_custom_ca_trust_certificate_files = ["tests/fixtures/ca-bundle-five-with-comment.pem"]
  }

  assert {
    condition     = module.aks.custom_ca_trust_certificates_base64 == tolist([filebase64("tests/fixtures/ca-bundle-five-with-comment.pem")])
    error_message = "A comment line above a five-certificate bundle should pass as one entry equal to the file"
  }
}
