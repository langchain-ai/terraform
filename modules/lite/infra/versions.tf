#------------------------------------------------------------------------------
# Terraform and providers. Lite talks to no cluster: the box installs itself
# from the bundle, so there is no kubernetes or helm provider.
#   aws     the instance, with cloud = aws (hosts/aws)
#   random  the generated credentials (secrets.tf)
#   tls     an AWS instance's ssh host key (hosts/aws)
#------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.33.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Configured whatever the cloud. The provider looks for credentials when it starts even when nothing
# uses it, and a bare-metal plan failed for want of AWS credentials it never needed; with cloud =
# baremetal it is given placeholders and told to check nothing, so it never calls AWS.
provider "aws" {
  region                      = var.aws_region
  access_key                  = var.cloud == "aws" ? null : "unused"
  secret_key                  = var.cloud == "aws" ? null : "unused"
  skip_credentials_validation = var.cloud != "aws"
  skip_requesting_account_id  = var.cloud != "aws"
  skip_metadata_api_check     = var.cloud != "aws"

  default_tags {
    tags = { "langsmith-lite" = var.name }
  }
}
