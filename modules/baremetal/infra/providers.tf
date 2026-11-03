# Both providers reach the cluster through a kubeconfig on this machine; there
# is no cloud API to ask for credentials. kube_context is required so a plan
# can never land on whatever context happens to be current.

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kube_context
  }
}
