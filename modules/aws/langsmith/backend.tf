# You may want to keep the terraform state in S3 instead of locally
# terraform {
#   backend "s3" {
#     bucket         = "langsmith-terraform-state-bucket"
#     key            = "envs/dev/terraform.tfstate"  # customize as needed
#     region         = "us-west-2"
#     encrypt        = true
#   }
# }
