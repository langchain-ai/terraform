# The ingress module, one ingress_type at a time. mock_provider means no cloud
# credentials, no state, and no API calls. A root plan cannot read the
# attributes of a resource inside a child module, so each run plans the module
# on its own, as tests/teardown.tftest.hcl does.

mock_provider "google" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "local" {}

variables {
  project_id       = "langsmith-plan-tests"
  region           = "us-central1"
  cluster_name     = "langsmith-plan-tests-gke"
  langsmith_domain = "langsmith.example.com"
  gateway_name     = "langsmith-plan-tests-gateway"
}

# ingress_type is deliberately not set: this run is the guarantee that the
# default is Envoy and that none of the GKE resources exist without opting in.
run "default_ingress_is_envoy_and_plans_no_gke_resources" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  assert {
    condition     = length(helm_release.envoy_gateway) == 1 && length(null_resource.apply_gateway) == 1
    error_message = "The default ingress_type did not plan Envoy Gateway"
  }
  assert {
    condition = (
      length(google_compute_global_address.gke_gateway) == 0 &&
      length(local_file.gke_gateway) == 0 &&
      length(null_resource.apply_gke_gateway) == 0 &&
      length(null_resource.delete_gke_gateway_on_destroy) == 0
    )
    error_message = "The default ingress_type planned GKE Gateway resources"
  }
}

run "gke_plans_the_gateway_and_no_envoy_resources" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type           = "gke"
    tls_certificate_source = "none"
  }

  assert {
    condition = (
      length(google_compute_global_address.gke_gateway) == 1 &&
      length(local_file.gke_gateway) == 1 &&
      length(null_resource.apply_gke_gateway) == 1 &&
      length(null_resource.delete_gke_gateway_on_destroy) == 1
    )
    error_message = "ingress_type = gke did not plan the address, manifest, apply, and delete steps"
  }
  assert {
    condition = (
      length(helm_release.envoy_gateway) == 0 &&
      length(null_resource.apply_gateway) == 0 &&
      length(null_resource.delete_gateway_on_destroy) == 0
    )
    error_message = "ingress_type = gke still planned Envoy Gateway resources"
  }
  assert {
    condition     = google_compute_global_address.gke_gateway[0].name == "langsmith-plan-tests-gateway-ip"
    error_message = "The static IP is not named after the Gateway"
  }
  assert {
    condition = (
      yamldecode(local_file.gke_gateway[0].content).spec.gatewayClassName == "gke-l7-global-external-managed" &&
      yamldecode(local_file.gke_gateway[0].content).spec.addresses[0].value == "langsmith-plan-tests-gateway-ip"
    )
    error_message = "The Gateway does not use the default class and the reserved address"
  }
  assert {
    condition     = [for l in yamldecode(local_file.gke_gateway[0].content).spec.listeners : l.name] == ["http"]
    error_message = "tls_certificate_source = none should produce only the HTTP listener"
  }
}

run "gke_with_existing_tls_is_https_only" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type           = "gke"
    tls_certificate_source = "existing"
  }

  assert {
    condition     = [for l in yamldecode(local_file.gke_gateway[0].content).spec.listeners : l.name] == ["https"]
    error_message = "tls_certificate_source = existing should produce only the HTTPS listener"
  }
}

run "gke_regional_class_reserves_no_static_ip" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type           = "gke"
    gke_gateway_class      = "gke-l7-rilb"
    tls_certificate_source = "none"
  }

  assert {
    condition     = length(google_compute_global_address.gke_gateway) == 0
    error_message = "A regional class reserved a global address"
  }
  assert {
    condition     = !contains(keys(yamldecode(local_file.gke_gateway[0].content).spec), "addresses")
    error_message = "A regional class set spec.addresses"
  }
}

run "gke_rejects_letsencrypt" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type           = "gke"
    tls_certificate_source = "letsencrypt"
  }

  expect_failures = [local_file.gke_gateway]
}
