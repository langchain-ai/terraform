# Shared AWS mock data for the plan tests. Every test file points its
# mock_provider "aws" block at this directory so the fixtures live in one place.
#
# A mock provider invents a random string for every computed attribute, and
# several of those attributes are parsed rather than passed through: the AWS
# provider rejects a malformed ARN or a policy document that is not JSON, and the
# vpc module has a postcondition on the availability-zone list. What follows
# gives those attributes a shape the parsers accept. Everything else stays
# generated.

mock_data "aws_availability_zones" {
  defaults = {
    names    = ["us-east-2a", "us-east-2b", "us-east-2c"]
    zone_ids = ["use2-az1", "use2-az2", "use2-az3"]
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:role/plan-tests"
    user_id    = "AIDAPLANTESTSFIXTURE"
  }
}

mock_data "aws_iam_session_context" {
  defaults = {
    issuer_arn  = "arn:aws:iam::123456789012:role/plan-tests"
    issuer_id   = "AROAPLANTESTSFIXTURE"
    issuer_name = "plan-tests"
  }
}

mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"}}]}"
  }
}

mock_data "aws_partition" {
  defaults = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

mock_data "aws_region" {
  defaults = {
    name = "us-east-2"
  }
}
