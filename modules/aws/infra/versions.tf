terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.33 for aws_launch_template cpu_options.nested_virtualization, which
      # the eks module (>= 21.x, below) needs to boot sandbox-host nodes on cheap
      # virtual instances (m7i/c7i/m8i/...) instead of bare metal.
      version = ">= 6.33.0, < 7.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    # kubectl provider is used for the SmithDB Karpenter CRs (EC2NodeClass,
    # NodePool). kubectl_manifest defers schema validation to apply time — plan
    # succeeds even before the Karpenter CRDs are installed by the eks add-on.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
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
