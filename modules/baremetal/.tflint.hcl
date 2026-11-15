# No cloud provider here, so no provider ruleset: the bundled Terraform ruleset,
# at its recommended preset, pinned like the other modules' (scripts/check.sh
# reads modules/<provider>/.tflint.hcl).
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
