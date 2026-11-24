# The AWS ruleset at the version the aws module pins, for hosts/aws; the bundled Terraform rules for
# the rest (scripts/check.sh reads modules/<provider>/.tflint.hcl).
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
