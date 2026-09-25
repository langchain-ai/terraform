# Teardown settings that a plan can check. A root plan cannot read the
# attributes of a resource inside a child module, so each run plans one child
# module on its own. mock_provider means no cloud credentials, no state, and no
# API calls.

mock_provider "google" {}
mock_provider "time" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "local" {}

# ── Private service connection (modules/networking) ──────────────────────────

run "private_service_connection_is_abandoned_on_destroy" {
  command = plan

  module {
    source = "./modules/networking"
  }

  variables {
    project_id                        = "langsmith-plan-tests"
    region                            = "us-central1"
    environment                       = "dev"
    vpc_name                          = "langsmith-plan-tests-vpc"
    subnet_cidr                       = "10.0.0.0/20"
    pods_cidr                         = "10.4.0.0/14"
    services_cidr                     = "10.8.0.0/20"
    enable_private_service_connection = true
  }

  # Without ABANDON, terraform destroy stops on this connection for some time
  # after the Cloud SQL and Memorystore deletes.
  assert {
    condition     = google_service_networking_connection.private_vpc_connection[0].deletion_policy == "ABANDON"
    error_message = "The private service connection does not set deletion_policy = ABANDON"
  }
}

# ── Gateway delete on destroy (modules/ingress) ──────────────────────────────

run "envoy_ingress_plans_the_gateway_delete" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    project_id       = "langsmith-plan-tests"
    region           = "us-central1"
    cluster_name     = "langsmith-plan-tests-gke"
    ingress_type     = "envoy"
    langsmith_domain = ""
    gateway_name     = "langsmith-plan-tests-gateway"
  }

  assert {
    condition     = length(null_resource.delete_gateway_on_destroy) == 1
    error_message = "ingress_type = envoy did not plan the Gateway delete on destroy"
  }

  # A destroy provisioner can read only self, so its triggers must hold the
  # cluster and the Gateway name.
  assert {
    condition = (
      null_resource.delete_gateway_on_destroy[0].triggers["project_id"] == "langsmith-plan-tests" &&
      null_resource.delete_gateway_on_destroy[0].triggers["region"] == "us-central1" &&
      null_resource.delete_gateway_on_destroy[0].triggers["cluster_name"] == "langsmith-plan-tests-gke" &&
      null_resource.delete_gateway_on_destroy[0].triggers["gateway_name"] == "langsmith-plan-tests-gateway"
    )
    error_message = "The Gateway delete triggers do not hold the project, region, cluster, and Gateway name"
  }
}

run "other_ingress_plans_no_gateway_delete" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    project_id       = "langsmith-plan-tests"
    region           = "us-central1"
    cluster_name     = "langsmith-plan-tests-gke"
    ingress_type     = "other"
    langsmith_domain = ""
    gateway_name     = "langsmith-plan-tests-gateway"
  }

  assert {
    condition     = length(null_resource.delete_gateway_on_destroy) == 0
    error_message = "ingress_type = other still planned the Gateway delete on destroy"
  }
}
