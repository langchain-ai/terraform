terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Required by time_sleep.wait_for_alb_webhook in main.tf
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
  }
}
