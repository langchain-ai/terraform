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

run "gke_with_existing_tls_serves_https_and_redirects_http" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type           = "gke"
    tls_certificate_source = "existing"
    tls_secret_name        = "corp-langsmith-tls"
  }

  assert {
    condition     = [for l in yamldecode(local_file.gke_gateway[0].content).spec.listeners : l.name] == ["http", "https"]
    error_message = "With TLS, the Gateway should have the HTTP listener for the redirect and the HTTPS listener"
  }
  assert {
    condition     = yamldecode(local_file.gke_gateway[0].content).spec.listeners[1].tls.certificateRefs[0].name == "corp-langsmith-tls"
    error_message = "The HTTPS listener should terminate with tls_secret_name"
  }
  assert {
    condition = (
      length(null_resource.apply_https_redirect) == 1 &&
      yamldecode(local_file.https_redirect[0].content).metadata.namespace == "langsmith" &&
      yamldecode(local_file.https_redirect[0].content).spec.parentRefs[0].sectionName == "http" &&
      yamldecode(local_file.https_redirect[0].content).spec.rules[0].filters[0].requestRedirect == { scheme = "https", statusCode = 301 }
    )
    error_message = "The redirect route should sit beside the GKE Gateway and 301 the http listener to HTTPS"
  }
  # The GKE Gateway shares the LangSmith namespace with the Secret.
  assert {
    condition     = length(null_resource.apply_reference_grant) == 0
    error_message = "The GKE Gateway needs no ReferenceGrant"
  }
}

run "gke_with_google_managed_tls_uses_the_certificate_map" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type             = "gke"
    tls_certificate_source   = "google-managed"
    tls_certificate_map_name = "ls-prod-langsmith-tls-map"
  }

  assert {
    condition     = yamldecode(local_file.gke_gateway[0].content).metadata.annotations["networking.gke.io/certmap"] == "ls-prod-langsmith-tls-map"
    error_message = "The GKE Gateway should name the certificate map in networking.gke.io/certmap"
  }
  # GKE rejects a Gateway with both the certmap annotation and certificateRefs.
  assert {
    condition = (
      [for l in yamldecode(local_file.gke_gateway[0].content).spec.listeners : l.name] == ["http", "https"] &&
      !contains(keys(yamldecode(local_file.gke_gateway[0].content).spec.listeners[1]), "tls")
    )
    error_message = "With a certificate map, the HTTPS listener must carry no tls block"
  }
  assert {
    condition     = length(null_resource.apply_https_redirect) == 1
    error_message = "google-managed should redirect HTTP to HTTPS"
  }
}

run "gke_google_managed_on_a_regional_class_is_rejected" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type             = "gke"
    gke_gateway_class        = "gke-l7-rilb"
    tls_certificate_source   = "google-managed"
    tls_certificate_map_name = "ls-prod-langsmith-tls-map"
  }

  expect_failures = [local_file.gke_gateway]
}

# ── Envoy Gateway TLS ────────────────────────────────────────────────────────

run "envoy_without_tls_serves_http_only" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    tls_certificate_source = "none"
  }

  assert {
    condition = (
      [for l in yamldecode(local_file.gateway[0].content).spec.listeners : l.name] == ["http"] &&
      length(null_resource.apply_https_redirect) == 0 &&
      length(null_resource.apply_reference_grant) == 0
    )
    error_message = "With no TLS, Envoy should serve LangSmith on the HTTP listener with no redirect"
  }
}

# The ReferenceGrant used to exist only for Let's Encrypt, so an 'existing'
# Secret in the LangSmith namespace was not readable from envoy-gateway-system.
run "envoy_with_existing_tls_grants_the_secret_and_redirects" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    tls_certificate_source = "existing"
    tls_secret_name        = "corp-langsmith-tls"
  }

  assert {
    condition = (
      length(null_resource.apply_reference_grant) == 1 &&
      yamldecode(local_file.reference_grant[0].content).spec.to[0].name == "corp-langsmith-tls"
    )
    error_message = "Envoy with an existing Secret should plan the ReferenceGrant for it"
  }
  assert {
    condition = (
      [for l in yamldecode(local_file.gateway[0].content).spec.listeners : l.name] == ["http", "https"] &&
      yamldecode(local_file.https_redirect[0].content).metadata.namespace == "envoy-gateway-system"
    )
    error_message = "Envoy with TLS should redirect the HTTP listener, from beside the Gateway"
  }
}

run "envoy_with_letsencrypt_has_no_gateway_shim_annotation" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    tls_certificate_source = "letsencrypt"
  }

  assert {
    condition     = !contains(keys(yamldecode(local_file.gateway[0].content).metadata), "annotations")
    error_message = "The Envoy Gateway should not carry cert-manager.io/cluster-issuer: k8s-bootstrap owns the Certificate"
  }
  assert {
    condition     = length(null_resource.apply_reference_grant) == 1 && length(null_resource.apply_https_redirect) == 1
    error_message = "Let's Encrypt on Envoy should plan the ReferenceGrant and the redirect"
  }
}

run "envoy_rejects_google_managed" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    tls_certificate_source = "google-managed"
  }

  expect_failures = [local_file.gateway]
}

run "gke_with_your_own_issuer_terminates_from_the_secret" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type           = "gke"
    tls_certificate_source = "cert-manager"
  }

  assert {
    condition = (
      yamldecode(local_file.gke_gateway[0].content).spec.listeners[1].tls.certificateRefs[0].name == "langsmith-tls" &&
      !contains(keys(yamldecode(local_file.gke_gateway[0].content).metadata), "annotations")
    )
    error_message = "cert-manager on the GKE Gateway should terminate from the Secret, with no certificate map"
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

# ── Input validation ─────────────────────────────────────────────────────────
# The provisioners pass these values to the shell only through the environment,
# and the module also validates them, so a value with shell syntax stops the
# plan even when this module is called without the root module.
run "cluster_name_with_shell_syntax_is_rejected" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    cluster_name = "gke$(id)"
  }

  expect_failures = [var.cluster_name]
}

# The GKE Gateway static IP is <gateway_name>-ip, so the name stops at 60.
run "gateway_name_too_long_for_the_static_ip_is_rejected" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    ingress_type = "gke"
    gateway_name = "langsmith-gateway-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxa"
  }

  expect_failures = [var.gateway_name]
}

run "namespace_region_and_project_with_shell_syntax_are_rejected" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    langsmith_namespace = "langsmith;id"
    region              = "us-central1 && id"
    project_id          = "proj`id`"
  }

  expect_failures = [var.langsmith_namespace, var.region, var.project_id]
}

run "gateway_api_crds_url_must_be_https" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    gateway_api_crds_url = "http://example.com/standard-install.yaml"
  }

  expect_failures = [var.gateway_api_crds_url]
}
