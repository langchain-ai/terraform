# The SmithDB object-store bucket must carry no lifecycle rules.
#
# Compaction handles retention on the SmithDB bucket, so it gets no TTL, and
# deleting live objects can make data unavailable. Only the platform bucket gets
# TTL rules (modules/storage, ttl_s/ and ttl_l/).
#
# A plan test cannot assert that a resource is absent by referencing it, and the
# test framework does not expose resources inside a child module. So this scans
# the HCL source that builds the SmithDB bucket for a lifecycle resource or an
# inline lifecycle_rule block. The first assert is a control: the same scan must
# find the platform bucket's rule, so a wrong path (an empty fileset) cannot make
# the guard pass vacuously.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  name_prefix       = "plantest"
  postgres_password = "fixture-not-a-real-secret-Aa1"
  redis_auth_token  = "fixture-not-a-real-token-0123456789"

  acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "smithdb_bucket_has_no_lifecycle_rules" {
  command = plan

  variables {
    enable_smithdb = true
  }

  assert {
    condition     = length(module.smithdb) == 1
    error_message = "enable_smithdb = true did not plan SmithDB, so the bucket guard checked nothing"
  }

  # Control: the scan finds the platform bucket's TTL rule.
  assert {
    condition = anytrue([
      for f in fileset("${path.module}/modules/storage", "*.tf") :
      strcontains(file("${path.module}/modules/storage/${f}"), "aws_s3_bucket_lifecycle_configuration")
    ])
    error_message = "the source scan did not find the platform bucket's lifecycle configuration in modules/storage, so it cannot be trusted to guard the SmithDB bucket"
  }

  # The SmithDB module builds the bucket, so nothing in it may expire objects.
  assert {
    condition = !anytrue(flatten([
      for f in fileset("${path.module}/modules/smithdb", "*.tf") : [
        for token in ["aws_s3_bucket_lifecycle_configuration", "lifecycle_rule"] :
        strcontains(file("${path.module}/modules/smithdb/${f}"), token)
      ]
    ]))
    error_message = "modules/smithdb declares a lifecycle rule. Do not set a TTL on the SmithDB bucket: compaction handles retention there, and deleting live objects can make data unavailable."
  }

  # A rule could also be attached from the root, against the module's bucket.
  assert {
    condition = !anytrue([
      for f in fileset(path.module, "*.tf") :
      strcontains(file("${path.module}/${f}"), "aws_s3_bucket_lifecycle_configuration")
    ])
    error_message = "the AWS root declares an aws_s3_bucket_lifecycle_configuration. The platform bucket's rule lives in modules/storage; the SmithDB bucket must have none."
  }
}
