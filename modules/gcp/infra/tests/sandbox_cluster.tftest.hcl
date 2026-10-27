# sandbox_deployment_mode = "separate_cluster": a dedicated sandbox GKE cluster
# in the same VPC. mock_provider means no cloud credentials, no state, and no
# API calls.
#
# A root plan cannot read the attributes of a resource inside a child module,
# so the module-level pieces (control-plane range, sandbox subnet, internal
# gateway, Redis AUTH) each get a run that plans that module on its own.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubernetes" {
  alias = "sandbox"
}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "local" {}

variables {
  project_id        = "langsmith-plan-tests"
  postgres_password = "fixture-not-a-real-secret-Aa1"

  enable_sandboxes             = true
  sandbox_deployment_mode      = "separate_cluster"
  langsmith_helm_chart_version = "0.18.0"
  gateway_load_balancer_type   = "internal"

  langsmith_api_key_salt       = "fixture-api-key-salt-not-a-real-secret"
  sandbox_service_auth_secret  = "fixture-sandbox-service-auth-0123456789abcdef"
  sandbox_callback_signing_jwk = "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"fixture\"}"
}

# master_auth is a computed nested block, and a mock provider returns it as an
# empty list, which modules/k8s-cluster/outputs.tf indexes. See wiring.tftest.hcl.
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

override_module {
  target = module.sandbox_gke
  outputs = {
    cluster_name   = "ls-prod-sbox-gke"
    cluster_id     = "projects/langsmith-plan-tests/locations/us-central1/clusters/ls-prod-sbox-gke"
    endpoint       = "10.0.0.2"
    ca_certificate = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
    location       = "us-central1"
  }
}

override_resource {
  target          = random_id.suffix
  override_during = plan
  values = {
    hex = "a1b2c3d4"
  }
}

# Known node identities, so the firewall targets can be checked at plan time.
override_resource {
  target          = google_service_account.sandbox_host_node
  override_during = plan
  values = {
    email  = "ls-prod-sbox-node@langsmith-plan-tests.iam.gserviceaccount.com"
    member = "serviceAccount:ls-prod-sbox-node@langsmith-plan-tests.iam.gserviceaccount.com"
  }
}

override_resource {
  target          = google_service_account.sandbox_system_node
  override_during = plan
  values = {
    email  = "ls-prod-sbox-sys@langsmith-plan-tests.iam.gserviceaccount.com"
    member = "serviceAccount:ls-prod-sbox-sys@langsmith-plan-tests.iam.gserviceaccount.com"
  }
}

# ── Separate cluster: what gets created ──────────────────────────────────────

run "separate_cluster_creates_the_sandbox_cluster" {
  command = plan

  assert {
    condition     = length(module.sandbox_gke) == 1
    error_message = "separate_cluster did not plan the sandbox GKE cluster"
  }
  assert {
    condition     = local.sandbox_cluster_name == "ls-prod-sbox-gke"
    error_message = "the sandbox cluster is not named <base>-sbox-gke"
  }
  assert {
    condition     = length(google_service_account.sandbox_system_node) == 1 && google_service_account.sandbox_system_node[0].account_id == "ls-prod-sbox-sys"
    error_message = "the sandbox cluster's system pool has no service account of its own"
  }
  assert {
    condition     = length(google_project_iam_member.sandbox_system_node) == 3
    error_message = "the system pool service account should hold exactly the three default node roles"
  }
  assert {
    condition     = length(google_service_account.sandbox_host_node) == 1
    error_message = "separate_cluster did not plan the sandbox-host node service account"
  }
  assert {
    condition     = length(module.sandbox_juicefs_redis) == 1
    error_message = "separate_cluster did not plan the JuiceFS Redis"
  }
  assert {
    condition     = length(time_sleep.wait_for_sandbox_cluster) == 1
    error_message = "separate_cluster does not wait for the sandbox cluster's API server"
  }
}

run "separate_cluster_gives_juicefs_its_own_bucket" {
  command = plan

  assert {
    condition     = length(google_storage_bucket.sandbox_juicefs) == 1 && google_storage_bucket.sandbox_juicefs[0].name == "langsmith-plan-tests-ls-prod-jfs-a1b2c3d4"
    error_message = "separate_cluster did not plan the JuiceFS-only bucket <project>-<base>-jfs<suffix>"
  }
  assert {
    condition     = google_storage_bucket.sandbox_juicefs[0].uniform_bucket_level_access && google_storage_bucket.sandbox_juicefs[0].public_access_prevention == "enforced"
    error_message = "the JuiceFS bucket must use uniform bucket-level access and enforced public access prevention"
  }
  assert {
    condition     = length(google_storage_bucket.sandbox_juicefs[0].versioning) == 0 && length(google_storage_bucket.sandbox_juicefs[0].cors) == 0
    error_message = "the JuiceFS bucket should carry neither versioning nor CORS"
  }

  # Cloud Storage checks a list call against the bucket, so the grant on a
  # JuiceFS-only bucket must have no condition.
  assert {
    condition = (
      length(google_storage_bucket_iam_member.sandbox_host_node_juicefs_bucket) == 1
      && google_storage_bucket_iam_member.sandbox_host_node_juicefs_bucket[0].role == "roles/storage.objectAdmin"
      && length(google_storage_bucket_iam_member.sandbox_host_node_juicefs_bucket[0].condition) == 0
    )
    error_message = "the sandbox node service account needs an unconditioned objectAdmin grant on the JuiceFS bucket"
  }

  # The same-cluster grant reaches into the trace bucket. It must not exist here.
  assert {
    condition     = length(google_storage_bucket_iam_member.sandbox_host_node_juicefs) == 0
    error_message = "separate_cluster still grants the sandbox node service account on the trace bucket"
  }
}

run "separate_cluster_writes_the_sandbox_cluster_secrets" {
  command = plan

  assert {
    condition     = length(kubernetes_namespace_v1.sandbox) == 1 && kubernetes_namespace_v1.sandbox[0].metadata[0].name == "langsmith-sandbox"
    error_message = "separate_cluster did not plan the sandbox namespace"
  }
  assert {
    condition = (
      length(kubernetes_secret_v1.sandbox_runtime) == 1
      && kubernetes_secret_v1.sandbox_runtime[0].metadata[0].name == "langsmith-sandbox-runtime"
      && kubernetes_secret_v1.sandbox_runtime[0].metadata[0].namespace == "langsmith-sandbox"
    )
    error_message = "separate_cluster did not plan the runtime Secret in the sandbox namespace"
  }

  # Exactly the two keys the runtime chart reads, with the control plane's
  # values. The salt must not reach the sandbox cluster.
  assert {
    condition     = toset(keys(local.sandbox_runtime_secret_data)) == toset(["sandbox_callback_signing_jwk", "sandbox_service_auth_secret"])
    error_message = "the runtime Secret must hold exactly sandbox_service_auth_secret and sandbox_callback_signing_jwk"
  }
  assert {
    condition = (
      nonsensitive(local.sandbox_runtime_secret_data.sandbox_service_auth_secret == var.sandbox_service_auth_secret)
      && nonsensitive(local.sandbox_runtime_secret_data.sandbox_callback_signing_jwk == var.sandbox_callback_signing_jwk)
    )
    error_message = "the runtime Secret values are not the control plane's"
  }

  assert {
    condition = (
      length(kubernetes_secret_v1.sandbox_juicefs_config) == 1
      && kubernetes_secret_v1.sandbox_juicefs_config[0].metadata[0].namespace == "langsmith-sandbox"
    )
    error_message = "separate_cluster did not plan the JuiceFS config Secret in the sandbox namespace"
  }
  assert {
    condition     = local.sandbox_juicefs_separate_secret_data.storage == "gs" && local.sandbox_juicefs_separate_secret_data.name == "sandbox-juicefs"
    error_message = "the sandbox JuiceFS config Secret does not point JuiceFS at Cloud Storage"
  }
  # Another cluster reaches the Redis over the VPC, so the URL carries AUTH.
  assert {
    condition     = startswith(nonsensitive(local.sandbox_juicefs_separate_secret_data.metaurl), "redis://:")
    error_message = "the sandbox JuiceFS metaurl carries no Redis AUTH"
  }

  # The LangSmith namespace gets none of it.
  assert {
    condition     = length(kubernetes_secret_v1.sandbox_juicefs_csi_config) == 0
    error_message = "separate_cluster still writes the JuiceFS config Secret into the LangSmith namespace"
  }
}

run "separate_cluster_firewall" {
  command = plan

  assert {
    condition = (
      length(google_compute_firewall.sandbox_host_from_langsmith) == 1
      && google_compute_firewall.sandbox_host_from_langsmith[0].direction == "INGRESS"
      && google_compute_firewall.sandbox_host_from_langsmith[0].priority == 900
      && one(google_compute_firewall.sandbox_host_from_langsmith[0].allow).protocol == "tcp"
      && one(google_compute_firewall.sandbox_host_from_langsmith[0].allow).ports == tolist(["19190"])
    )
    error_message = "sandbox nodes must admit TCP 19190 at priority 900"
  }
  assert {
    condition     = toset(google_compute_firewall.sandbox_host_from_langsmith[0].target_service_accounts) == toset(["ls-prod-sbox-node@langsmith-plan-tests.iam.gserviceaccount.com"])
    error_message = "TCP 19190 must open only on the sandbox-host nodes"
  }
  assert {
    condition     = toset(google_compute_firewall.sandbox_host_from_langsmith[0].source_ranges) == toset(["10.0.0.0/20", "10.4.0.0/14", "10.10.0.0/20"])
    error_message = "TCP 19190 must come only from the LangSmith node and pod ranges and the sandbox subnet"
  }

  # Overrides the untargeted allow-internal rule (priority 1000) for the
  # sandbox cluster's nodes, both pools.
  assert {
    condition = (
      length(google_compute_firewall.sandbox_deny_from_langsmith) == 1
      && google_compute_firewall.sandbox_deny_from_langsmith[0].priority == 950
      && one(google_compute_firewall.sandbox_deny_from_langsmith[0].deny).protocol == "all"
      && toset(google_compute_firewall.sandbox_deny_from_langsmith[0].source_ranges) == toset(["10.0.0.0/20", "10.4.0.0/14", "10.8.0.0/20"])
      && toset(google_compute_firewall.sandbox_deny_from_langsmith[0].target_service_accounts) == toset([
        "ls-prod-sbox-node@langsmith-plan-tests.iam.gserviceaccount.com",
        "ls-prod-sbox-sys@langsmith-plan-tests.iam.gserviceaccount.com",
      ])
    )
    error_message = "everything else from the LangSmith ranges must be denied to both sandbox pools at priority 950"
  }

  assert {
    condition = (
      length(google_compute_firewall.sandbox_host_to_juicefs_redis) == 1
      && google_compute_firewall.sandbox_host_to_juicefs_redis[0].direction == "EGRESS"
      && google_compute_firewall.sandbox_host_to_juicefs_redis[0].priority == 900
      && length(google_compute_firewall.sandbox_host_to_juicefs_redis[0].destination_ranges) == 1
      && toset(google_compute_firewall.sandbox_host_to_juicefs_redis[0].target_service_accounts) == toset(["ls-prod-sbox-node@langsmith-plan-tests.iam.gserviceaccount.com"])
    )
    error_message = "sandbox nodes must be allowed to reach the JuiceFS Redis"
  }
  assert {
    condition = (
      length(google_compute_firewall.sandbox_host_deny_private_services) == 1
      && google_compute_firewall.sandbox_host_deny_private_services[0].direction == "EGRESS"
      && google_compute_firewall.sandbox_host_deny_private_services[0].priority == 950
      && one(google_compute_firewall.sandbox_host_deny_private_services[0].deny).protocol == "all"
      && toset(google_compute_firewall.sandbox_host_deny_private_services[0].target_service_accounts) == toset(["ls-prod-sbox-node@langsmith-plan-tests.iam.gserviceaccount.com"])
    )
    error_message = "sandbox nodes must be denied the rest of the private services range"
  }
}

run "separate_cluster_outputs" {
  command = plan

  assert {
    condition     = output.sandbox_deployment_mode == "separate_cluster" && output.sandbox_namespace == "langsmith-sandbox" && output.sandbox_runtime_secret_name == "langsmith-sandbox-runtime"
    error_message = "the separate_cluster outputs init-values.sh reads are wrong"
  }
  assert {
    condition     = output.sandbox_cluster_name == "ls-prod-sbox-gke" && output.sandbox_cluster_location == "us-central1"
    error_message = "the sandbox cluster outputs are wrong"
  }
}

# ── Same cluster: unchanged ─────────────────────────────────────────────────

run "same_cluster_plans_no_sandbox_cluster" {
  command = plan

  variables {
    sandbox_deployment_mode    = "same_cluster"
    gateway_load_balancer_type = "external"
  }

  assert {
    condition = (
      length(module.sandbox_gke) == 0
      && length(google_service_account.sandbox_system_node) == 0
      && length(google_storage_bucket.sandbox_juicefs) == 0
      && length(google_compute_firewall.sandbox_host_from_langsmith) == 0
      && length(google_compute_firewall.sandbox_deny_from_langsmith) == 0
      && length(google_compute_firewall.sandbox_host_to_juicefs_redis) == 0
      && length(google_compute_firewall.sandbox_host_deny_private_services) == 0
      && length(kubernetes_namespace_v1.sandbox) == 0
      && length(kubernetes_secret_v1.sandbox_runtime) == 0
      && length(kubernetes_secret_v1.sandbox_juicefs_config) == 0
    )
    error_message = "same_cluster planned a separate-cluster resource"
  }
  assert {
    condition = (
      length(google_storage_bucket_iam_member.sandbox_host_node_juicefs) == 1
      && length(kubernetes_secret_v1.sandbox_juicefs_csi_config) == 1
    )
    error_message = "same_cluster lost its trace-bucket grant or its JuiceFS config Secret"
  }
  assert {
    condition     = output.sandbox_cluster_name == null && output.sandbox_deployment_mode == "same_cluster"
    error_message = "same_cluster reports a sandbox cluster"
  }
}

run "sandboxes_off_plans_no_sandbox_cluster" {
  command = plan

  variables {
    enable_sandboxes           = false
    gateway_load_balancer_type = "external"
  }

  assert {
    condition     = length(module.sandbox_gke) == 0 && length(google_storage_bucket.sandbox_juicefs) == 0 && length(kubernetes_secret_v1.sandbox_runtime) == 0
    error_message = "sandbox_deployment_mode = separate_cluster planned a sandbox cluster with enable_sandboxes = false"
  }
  assert {
    condition     = output.sandbox_deployment_mode == null
    error_message = "sandboxes off still reports a sandbox mode"
  }
}

# ── Separate cluster: guards ─────────────────────────────────────────────────

run "separate_cluster_rejects_the_langsmith_namespace" {
  command = plan

  variables {
    sandbox_namespace = "langsmith"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_the_default_chart_line" {
  command = plan

  variables {
    langsmith_helm_chart_version = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_a_chart_range" {
  command = plan

  variables {
    langsmith_helm_chart_version = "~0.18.0"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_a_0_17_chart" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.17.9"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_accepts_a_release_candidate" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.18.0-rc.47"
  }

  assert {
    condition     = length(module.sandbox_gke) == 1
    error_message = "an exact 0.18 release candidate should be accepted"
  }
}

run "separate_cluster_rejects_a_short_service_auth_secret" {
  command = plan

  variables {
    sandbox_service_auth_secret = "too-short"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_the_salt_as_service_auth_secret" {
  command = plan

  variables {
    sandbox_service_auth_secret = "fixture-api-key-salt-not-a-real-secret"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_requires_the_callback_jwk" {
  command = plan

  variables {
    sandbox_callback_signing_jwk = ""
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_overlapping_ranges" {
  command = plan

  variables {
    # Inside the LangSmith pods range, 10.4.0.0/14.
    sandbox_subnet_cidr = "10.5.0.0/20"
  }

  expect_failures = [terraform_data.validate_inputs]
}

# The same CIDR in two variables is the plainest overlap of all.
run "separate_cluster_rejects_a_range_equal_to_a_langsmith_range" {
  command = plan

  variables {
    sandbox_pods_cidr = "10.4.0.0/14"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_two_equal_sandbox_ranges" {
  command = plan

  variables {
    sandbox_services_cidr = "10.10.0.0/20"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_overlapping_sandbox_ranges" {
  command = plan

  variables {
    sandbox_services_cidr = "10.10.8.0/21"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_the_langsmith_control_plane_range" {
  command = plan

  variables {
    sandbox_gke_master_ipv4_cidr = "172.17.0.0/28"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_rejects_an_external_gateway_without_tls" {
  command = plan

  variables {
    gateway_load_balancer_type = "external"
    tls_certificate_source     = "none"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "separate_cluster_accepts_an_external_gateway_with_tls" {
  command = plan

  variables {
    gateway_load_balancer_type = "external"
    tls_certificate_source     = "letsencrypt"
    letsencrypt_email          = "ops@example.com"
  }

  assert {
    condition     = length(module.sandbox_gke) == 1
    error_message = "an external gateway with TLS should be accepted"
  }
}

run "internal_gateway_requires_the_module_ingress" {
  command = plan

  variables {
    sandbox_deployment_mode = "same_cluster"
    install_ingress         = false
  }

  expect_failures = [terraform_data.validate_inputs]
}

# ── Module-level pieces ─────────────────────────────────────────────────────

run "k8s_cluster_keeps_the_default_control_plane_range" {
  command = plan

  module {
    source = "./modules/k8s-cluster"
  }

  variables {
    project_id          = "langsmith-plan-tests"
    region              = "us-central1"
    zone                = "us-central1-a"
    environment         = "prod"
    cluster_name        = "ls-prod-gke"
    network_id          = "projects/langsmith-plan-tests/global/networks/ls-prod-vpc"
    subnet_id           = "projects/langsmith-plan-tests/regions/us-central1/subnetworks/ls-prod-subnet"
    pods_range_name     = "pods"
    services_range_name = "services"
  }

  assert {
    condition     = one(google_container_cluster.primary[0].private_cluster_config).master_ipv4_cidr_block == "172.17.0.0/28"
    error_message = "the default control-plane range changed, which would replace existing clusters"
  }
}

run "k8s_cluster_takes_a_control_plane_range" {
  command = plan

  module {
    source = "./modules/k8s-cluster"
  }

  variables {
    project_id             = "langsmith-plan-tests"
    region                 = "us-central1"
    zone                   = "us-central1-a"
    environment            = "prod"
    cluster_name           = "ls-prod-sbox-gke"
    network_id             = "projects/langsmith-plan-tests/global/networks/ls-prod-vpc"
    subnet_id              = "projects/langsmith-plan-tests/regions/us-central1/subnetworks/ls-prod-vpc-sbox-subnet"
    pods_range_name        = "sbox-pods"
    services_range_name    = "sbox-services"
    master_ipv4_cidr_block = "172.17.0.16/28"
  }

  assert {
    condition     = one(google_container_cluster.primary[0].private_cluster_config).master_ipv4_cidr_block == "172.17.0.16/28"
    error_message = "master_ipv4_cidr_block did not reach the cluster"
  }
}

run "networking_adds_the_sandbox_subnet_on_request" {
  command = plan

  module {
    source = "./modules/networking"
  }

  variables {
    project_id            = "langsmith-plan-tests"
    region                = "us-central1"
    environment           = "prod"
    vpc_name              = "ls-prod-vpc"
    subnet_cidr           = "10.0.0.0/20"
    pods_cidr             = "10.4.0.0/14"
    services_cidr         = "10.8.0.0/20"
    create_sandbox_subnet = true
  }

  assert {
    condition = (
      length(google_compute_subnetwork.sandbox) == 1
      && google_compute_subnetwork.sandbox[0].name == "ls-prod-vpc-sbox-subnet"
      && google_compute_subnetwork.sandbox[0].ip_cidr_range == "10.10.0.0/20"
      && google_compute_subnetwork.sandbox[0].private_ip_google_access
    )
    error_message = "create_sandbox_subnet did not plan the sandbox subnet"
  }
  assert {
    condition = (
      { for r in google_compute_subnetwork.sandbox[0].secondary_ip_range : r.range_name => r.ip_cidr_range }
      == { "sbox-pods" = "10.12.0.0/16", "sbox-services" = "10.10.16.0/20" }
    )
    error_message = "the sandbox subnet's secondary ranges are wrong"
  }

  # The allow-internal rule must still admit only the LangSmith ranges, so the
  # sandbox subnet never gets blanket access to LangSmith's nodes.
  assert {
    condition     = toset(google_compute_firewall.allow_internal.source_ranges) == toset(["10.0.0.0/20", "10.4.0.0/14", "10.8.0.0/20"])
    error_message = "allow-internal must not admit the sandbox ranges"
  }
}

run "networking_has_no_sandbox_subnet_by_default" {
  command = plan

  module {
    source = "./modules/networking"
  }

  variables {
    project_id    = "langsmith-plan-tests"
    region        = "us-central1"
    environment   = "prod"
    vpc_name      = "ls-prod-vpc"
    subnet_cidr   = "10.0.0.0/20"
    pods_cidr     = "10.4.0.0/14"
    services_cidr = "10.8.0.0/20"
  }

  assert {
    condition     = length(google_compute_subnetwork.sandbox) == 0 && output.sandbox_subnet_id == null
    error_message = "the networking module created a sandbox subnet without being asked"
  }
}

run "ingress_internal_load_balancer" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    project_id         = "langsmith-plan-tests"
    region             = "us-central1"
    cluster_name       = "ls-prod-gke"
    langsmith_domain   = ""
    load_balancer_type = "internal"
  }

  assert {
    condition = (
      strcontains(local_file.gateway_class[0].content, "\"kind\": \"EnvoyProxy\"")
      && strcontains(local_file.gateway_class[0].content, "\"networking.gke.io/load-balancer-type\": \"Internal\"")
      && strcontains(local_file.gateway_class[0].content, "\"parametersRef\":")
    )
    error_message = "load_balancer_type = internal must add the EnvoyProxy and point the GatewayClass at it"
  }
}

run "ingress_external_load_balancer_is_unchanged" {
  command = plan

  module {
    source = "./modules/ingress"
  }

  variables {
    project_id       = "langsmith-plan-tests"
    region           = "us-central1"
    cluster_name     = "ls-prod-gke"
    langsmith_domain = ""
  }

  # The exact GatewayClass the module rendered before load_balancer_type
  # existed, so existing installs see no change.
  assert {
    condition = local_file.gateway_class[0].content == yamlencode({
      apiVersion = "gateway.networking.k8s.io/v1"
      kind       = "GatewayClass"
      metadata   = { name = "envoy-gateway-class" }
      spec       = { controllerName = "gateway.envoyproxy.io/gatewayclass-controller" }
    })
    error_message = "the default GatewayClass changed"
  }
}

run "redis_auth_is_opt_in" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    project_id    = "langsmith-plan-tests"
    region        = "us-central1"
    environment   = "prod"
    instance_name = "ls-prod-jfs-redis"
    network_id    = "projects/langsmith-plan-tests/global/networks/ls-prod-vpc"
  }

  assert {
    condition     = google_redis_instance.langsmith[0].auth_enabled == false
    error_message = "Redis AUTH must stay off by default"
  }
}

run "redis_auth_on_request" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    project_id    = "langsmith-plan-tests"
    region        = "us-central1"
    environment   = "prod"
    instance_name = "ls-prod-jfs-redis"
    network_id    = "projects/langsmith-plan-tests/global/networks/ls-prod-vpc"
    auth_enabled  = true
  }

  assert {
    condition     = google_redis_instance.langsmith[0].auth_enabled
    error_message = "auth_enabled did not reach the Memorystore instance"
  }
}
