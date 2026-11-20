# Remote state backend configuration.
#
# By default, state is stored locally (terraform.tfstate).
#
# To keep state in an S3 bucket you own, without editing this file, copy
# backend.hcl.example to backend.hcl (git-ignored), fill in your bucket, key, and
# region, and run `make init`. Locking uses S3 itself, with no DynamoDB table.
#
#   cp backend.hcl.example backend.hcl
#   make init                           # new deployment
#   make init ARGS="-migrate-state"     # move existing local state into the bucket
#
# Deleting backend.hcl and running `make init ARGS="-migrate-state"` moves state
# back to a local file. See "Terraform state backend" in the README.
