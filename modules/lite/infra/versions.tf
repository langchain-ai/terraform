#------------------------------------------------------------------------------
# Terraform and providers. Lite talks to no cluster: the box installs itself from the bundle, so there is
# no kubernetes or helm provider.

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

# Configured whatever the cloud: the provider looks for credentials at start, and a bare-metal plan failed
# for want of AWS credentials it never needed. With cloud = baremetal it gets placeholders and checks
# nothing, so it never calls AWS.
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
