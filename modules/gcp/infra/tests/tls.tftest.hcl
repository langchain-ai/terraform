# Ingress TLS in the GCP root: the tls_certificate_source preconditions and
# warnings, the Certificate Manager module (google-managed), and the cert-manager
# install and Certificate in k8s-bootstrap. mock_provider means no cloud
# credentials, no state, and no API calls.
#
# A root plan cannot read the attributes of a resource inside a child module, so
# the root runs assert on module counts and root outputs, and the module runs
# plan certificate-manager and k8s-bootstrap on their own.

# A mock provider returns a computed list attribute as an empty list, and the
# DNS authorization record is read at index 0. Give it the shape the API returns,
# during plan, since every run here is a plan.
mock_provider "google" {
  override_during = plan

  mock_resource "google_certificate_manager_dns_authorization" {
    defaults = {
      id = "projects/langsmith-plan-tests/locations/global/dnsAuthorizations/ls-prod-langsmith-tls-dnsauth"
      dns_resource_record = [{
        name = "_acme-challenge.langsmith.acme.test."
        type = "CNAME"
        data = "0123456789abcdef.1.authorize.certificatemanager.goog."
      }]
    }
  }
}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "local" {}

variables {
  project_id        = "langsmith-plan-tests"
  postgres_password = "fixture-not-a-real-secret-Aa1"
}

# See tests/wiring.tftest.hcl for why the cluster module is overridden.
override_module {
  target = module.gke_cluster
  outputs = {
    cluster_name   = "langsmith-plan-tests-gke"
    cluster_id     = "projects/langsmith-plan-tests/locations/us-central1/clusters/langsmith-plan-tests-gke"
    endpoint       = "10.0.0.1"
    ca_certificate = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
    location       = "us-central1"
  }
}

# ── Root: google-managed ─────────────────────────────────────────────────────

run "google_managed_on_gke_plans_the_certificate_and_its_dns_record" {
  command = plan

  variables {
    install_ingress        = true
    ingress_type           = "gke"
    tls_certificate_source = "google-managed"
    langsmith_domain       = "langsmith.acme.test"
    enable_dns_module      = true
  }

  assert {
    condition     = length(module.certificate_manager) == 1
    error_message = "google-managed did not plan the Certificate Manager module"
  }
  assert {
    condition     = output.tls_certificate_map_name == "ls-prod-langsmith-tls-map"
    error_message = "The certificate map is not named after the deployment"
  }
  assert {
    condition     = output.tls_dns_authorization_record_managed && output.tls_dns_authorization_record.type == "CNAME"
    error_message = "With the DNS module on, Terraform should create the DNS authorization CNAME"
  }
  # The load balancer holds the certificate: no Secret and no cert-manager.
  assert {
    condition     = output.tls_secret_name == null && output.cert_manager_version == null
    error_message = "google-managed should use no TLS Secret and install no cert-manager"
  }
}

run "google_managed_without_the_dns_module_outputs_the_record_to_add" {
  command = plan

  variables {
    install_ingress        = true
    ingress_type           = "gke"
    tls_certificate_source = "google-managed"
    langsmith_domain       = "langsmith.acme.test"
    enable_dns_module      = false
  }

  assert {
    condition = (
      !output.tls_dns_authorization_record_managed &&
      output.tls_dns_authorization_record.name == "_acme-challenge.langsmith.acme.test."
    )
    error_message = "Without the DNS module, the record should be an output for the operator, not a resource"
  }
}

run "other_sources_plan_no_certificate_manager" {
  command = plan

  variables {
    tls_certificate_source = "none"
  }

  assert {
    condition     = length(module.certificate_manager) == 0 && output.tls_certificate_map_name == null
    error_message = "tls_certificate_source = none planned the Certificate Manager module"
  }
}

run "google_managed_without_the_gke_gateway_is_rejected" {
  command = plan

  variables {
    install_ingress        = false
    tls_certificate_source = "google-managed"
    langsmith_domain       = "langsmith.acme.test"
  }

  expect_failures = [terraform_data.validate_inputs]
}

# The default langsmith_domain is an example. A certificate for it can never be
# authorized, so the plan stops instead of creating one.
run "google_managed_with_the_example_domain_is_rejected" {
  command = plan

  variables {
    install_ingress        = true
    ingress_type           = "gke"
    tls_certificate_source = "google-managed"
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── Root: existing, cert-manager, letsencrypt ────────────────────────────────

run "existing_with_a_precreated_secret_references_it" {
  command = plan

  variables {
    tls_certificate_source   = "existing"
    tls_existing_secret_name = "corp-langsmith-tls"
  }

  assert {
    condition     = output.tls_secret_name == "corp-langsmith-tls"
    error_message = "tls_existing_secret_name did not become the Secret the Gateway reads"
  }
}

run "existing_with_both_a_secret_and_pem_is_rejected" {
  command = plan

  variables {
    tls_certificate_source   = "existing"
    tls_existing_secret_name = "corp-langsmith-tls"
    tls_certificate_crt      = "-----BEGIN CERTIFICATE-----"
    tls_certificate_key      = "-----BEGIN PRIVATE KEY-----"
  }

  # The deprecation warning fires alongside the precondition.
  expect_failures = [terraform_data.validate_inputs, check.tls_settings]
}

run "existing_with_neither_is_rejected" {
  command = plan

  variables {
    tls_certificate_source = "existing"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "existing_with_pem_plans_and_warns" {
  command = plan

  variables {
    tls_certificate_source = "existing"
    tls_certificate_crt    = "-----BEGIN CERTIFICATE-----"
    tls_certificate_key    = "-----BEGIN PRIVATE KEY-----"
  }

  assert {
    condition     = output.tls_secret_name == "langsmith-tls"
    error_message = "PEM inputs should land in the default Secret name"
  }

  expect_failures = [check.tls_settings]
}

run "cert_manager_with_an_issuer_installs_the_supported_version" {
  command = plan

  variables {
    tls_certificate_source   = "cert-manager"
    cert_manager_issuer_name = "corp-pki"
  }

  assert {
    condition     = output.cert_manager_version == "v1.21.2" && output.tls_secret_name == "langsmith-tls"
    error_message = "tls_certificate_source = cert-manager did not install cert-manager v1.21.2 with the default Secret"
  }
}

run "cert_manager_without_an_issuer_is_rejected" {
  command = plan

  variables {
    tls_certificate_source = "cert-manager"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "letsencrypt_without_a_domain_is_rejected" {
  command = plan

  variables {
    tls_certificate_source = "letsencrypt"
    letsencrypt_email      = "ops@example.com"
    langsmith_domain       = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "letsencrypt_on_a_production_profile_warns" {
  command = plan

  variables {
    tls_certificate_source = "letsencrypt"
    letsencrypt_email      = "ops@example.com"
    sizing_profile         = "production"
  }

  expect_failures = [check.tls_settings]
}

run "letsencrypt_on_the_default_profile_does_not_warn" {
  command = plan

  variables {
    tls_certificate_source = "letsencrypt"
    letsencrypt_email      = "ops@example.com"
  }

  assert {
    condition     = output.cert_manager_version == "v1.21.2"
    error_message = "letsencrypt did not install cert-manager v1.21.2"
  }
}

run "deprecated_dns_create_certificate_warns" {
  command = plan

  variables {
    dns_create_certificate = true
  }

  expect_failures = [check.tls_settings]
}

# ── modules/certificate-manager ──────────────────────────────────────────────

run "certificate_manager_defaults_to_a_public_certificate_with_dns_authorization" {
  command = plan

  module {
    source = "./modules/certificate-manager"
  }

  variables {
    name   = "ls-prod-langsmith-tls"
    domain = "langsmith.example.com"
  }

  assert {
    condition = (
      length(google_certificate_manager_dns_authorization.langsmith) == 1 &&
      google_certificate_manager_dns_authorization.langsmith[0].domain == "langsmith.example.com" &&
      length(google_dns_record_set.dns_authorization) == 0
    )
    error_message = "With no zone, the module should plan the DNS authorization and no record"
  }
  assert {
    condition = (
      google_certificate_manager_certificate.langsmith.managed[0].domains == tolist(["langsmith.example.com"]) &&
      google_certificate_manager_certificate.langsmith.managed[0].issuance_config == null
    )
    error_message = "The certificate should cover only the domain, from a public CA"
  }
  assert {
    condition = (
      google_certificate_manager_certificate_map_entry.primary.matcher == "PRIMARY" &&
      google_certificate_manager_certificate_map_entry.primary.map == "ls-prod-langsmith-tls-map"
    )
    error_message = "The map entry should serve the certificate as PRIMARY from the module's map"
  }
}

run "certificate_manager_writes_the_record_into_a_zone" {
  command = plan

  module {
    source = "./modules/certificate-manager"
  }

  variables {
    name             = "ls-prod-langsmith-tls"
    domain           = "langsmith.example.com"
    dns_zone_name    = "ls-prod-langsmith"
    include_wildcard = true
  }

  assert {
    condition = (
      length(google_dns_record_set.dns_authorization) == 1 &&
      google_dns_record_set.dns_authorization[0].type == "CNAME" &&
      google_dns_record_set.dns_authorization[0].managed_zone == "ls-prod-langsmith"
    )
    error_message = "With a zone, the module should create the CNAME record in it"
  }
  assert {
    condition     = google_certificate_manager_certificate.langsmith.managed[0].domains == tolist(["langsmith.example.com", "*.langsmith.example.com"])
    error_message = "include_wildcard should add *.<domain>"
  }
}

run "certificate_manager_with_an_issuance_config_skips_dns_authorization" {
  command = plan

  module {
    source = "./modules/certificate-manager"
  }

  variables {
    name            = "ls-prod-langsmith-tls"
    domain          = "langsmith.example.com"
    dns_zone_name   = "ls-prod-langsmith"
    issuance_config = "projects/langsmith-plan-tests/locations/global/certificateIssuanceConfigs/corp-ca"
  }

  assert {
    condition = (
      length(google_certificate_manager_dns_authorization.langsmith) == 0 &&
      length(google_dns_record_set.dns_authorization) == 0 &&
      google_certificate_manager_certificate.langsmith.managed[0].issuance_config == "projects/langsmith-plan-tests/locations/global/certificateIssuanceConfigs/corp-ca"
    )
    error_message = "A private CA issuance config should replace the DNS authorization"
  }
}

run "certificate_manager_rejects_an_empty_domain" {
  command = plan

  module {
    source = "./modules/certificate-manager"
  }

  variables {
    name   = "ls-prod-langsmith-tls"
    domain = ""
  }

  expect_failures = [var.domain]
}

# ── modules/k8s-bootstrap: cert-manager ──────────────────────────────────────

run "letsencrypt_installs_cert_manager_with_gateway_api_after_the_crds" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    region                          = "us-central1"
    cluster_name                    = "langsmith-plan-tests-gke"
    environment                     = "dev"
    install_cert_manager            = true
    tls_certificate_source          = "letsencrypt"
    letsencrypt_email               = "ops@example.com"
    langsmith_domain                = "langsmith.example.com"
    gateway_name                    = "ls-prod-gateway"
    cert_manager_enable_gateway_api = true
  }

  assert {
    condition = (
      helm_release.cert_manager[0].repository == "oci://quay.io/jetstack/charts" &&
      helm_release.cert_manager[0].version == "v1.21.2"
    )
    error_message = "cert-manager should come from the OCI chart at v1.21.2"
  }
  assert {
    condition = (
      yamldecode(helm_release.cert_manager[0].values[0]).crds == { enabled = true, keep = true } &&
      yamldecode(helm_release.cert_manager[0].values[0]).config.enableGatewayAPI == true
    )
    error_message = "cert-manager should install and keep its CRDs, and turn on Gateway API support for Let's Encrypt"
  }
  assert {
    condition = (
      length(null_resource.gateway_api_crds_for_cert_manager) == 1 &&
      length(null_resource.cert_manager_upgrade_guard) == 1
    )
    error_message = "The Gateway API CRDs and the upgrade guard should run before cert-manager"
  }
  assert {
    condition     = yamldecode(local_file.letsencrypt_issuer[0].content).spec.acme.solvers[0].http01.gatewayHTTPRoute.parentRefs[0].sectionName == "http"
    error_message = "The HTTP-01 solver route should attach only to the http listener"
  }
  assert {
    condition     = yamldecode(local_file.certificate[0].content).spec.issuerRef == { name = "letsencrypt-prod", kind = "ClusterIssuer" }
    error_message = "The Let's Encrypt Certificate should use the letsencrypt-prod ClusterIssuer"
  }
}

run "cert_manager_source_uses_your_issuer_and_no_gateway_api" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    region                   = "us-central1"
    cluster_name             = "langsmith-plan-tests-gke"
    environment              = "dev"
    install_cert_manager     = true
    tls_certificate_source   = "cert-manager"
    cert_manager_issuer_name = "corp-pki"
    cert_manager_issuer_kind = "Issuer"
    langsmith_domain         = "langsmith.example.com"
  }

  assert {
    condition     = yamldecode(local_file.certificate[0].content).spec.issuerRef == { name = "corp-pki", kind = "Issuer" }
    error_message = "The Certificate should reference the operator's issuer"
  }
  assert {
    condition = (
      length(local_file.letsencrypt_issuer) == 0 &&
      length(null_resource.gateway_api_crds_for_cert_manager) == 0 &&
      !contains(keys(yamldecode(helm_release.cert_manager[0].values[0])), "config")
    )
    error_message = "Your own issuer needs no Let's Encrypt ClusterIssuer and no Gateway API support"
  }
}

run "existing_pem_creates_the_secret_and_a_precreated_secret_does_not" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    region                 = "us-central1"
    cluster_name           = "langsmith-plan-tests-gke"
    environment            = "dev"
    tls_certificate_source = "existing"
    tls_certificate_crt    = "-----BEGIN CERTIFICATE-----"
    tls_certificate_key    = "-----BEGIN PRIVATE KEY-----"
  }

  assert {
    condition     = length(kubernetes_secret.tls_certificate) == 1 && length(helm_release.cert_manager) == 0
    error_message = "existing with PEM inputs should create the Secret and install no cert-manager"
  }
}

run "existing_with_an_operator_secret_creates_nothing" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  # The root passes empty PEM inputs when tls_existing_secret_name is set.
  variables {
    region                 = "us-central1"
    cluster_name           = "langsmith-plan-tests-gke"
    environment            = "dev"
    tls_certificate_source = "existing"
    tls_secret_name        = "corp-langsmith-tls"
  }

  assert {
    condition     = length(kubernetes_secret.tls_certificate) == 0
    error_message = "An operator-owned Secret must not be created or overwritten by Terraform"
  }
}

# ── modules/k8s-bootstrap: input validation ──────────────────────────────────
# As in modules/ingress, the provisioners pass these values to the shell only
# through the environment, and the module also validates them, so a value with
# shell syntax stops the plan even when this module is called without the root.
run "k8s_bootstrap_cluster_name_with_shell_syntax_is_rejected" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    region       = "us-central1"
    cluster_name = "gke$(id)"
    environment  = "dev"
  }

  expect_failures = [var.cluster_name]
}

run "k8s_bootstrap_region_project_and_secret_name_with_shell_syntax_are_rejected" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    region          = "us-central1 && id"
    project_id      = "proj`id`"
    cluster_name    = "langsmith-plan-tests-gke"
    environment     = "dev"
    tls_secret_name = "langsmith-tls;id"
  }

  expect_failures = [var.region, var.project_id, var.tls_secret_name]
}

run "k8s_bootstrap_gateway_api_crds_url_must_be_https" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    region               = "us-central1"
    cluster_name         = "langsmith-plan-tests-gke"
    environment          = "dev"
    gateway_api_crds_url = "http://example.com/standard-install.yaml"
  }

  expect_failures = [var.gateway_api_crds_url]
}
