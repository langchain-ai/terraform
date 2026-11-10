# Plan tests with a mocked provider: no credentials and no state. Run with
# terraform init -backend=false && terraform test in the module directory.

mock_provider "google" {}

variables {
  project_id                 = "p"
  crossplane_service_account = "cp@x.iam.gserviceaccount.com"
  external_id                = "ext"
}

run "default_unchanged" {
  command = plan

  assert {
    condition     = length(google_project_iam_custom_role.name_fenced) == 0 && length(google_project_iam_member.name_fenced) == 0
    error_message = "No fenced roles by default."
  }

  assert {
    condition     = length(google_project_iam_custom_role.provisioner.permissions) == length(local.base_provisioner_permissions)
    error_message = "The default provisioner role is the full list."
  }

  assert {
    condition     = length(google_project_iam_custom_role.postgres_setup) == 0 && length(google_project_iam_member.byo_iam) == 0
    error_message = "No byo_iam grants by default."
  }
}

run "restricted" {
  command = plan

  variables {
    restrict_to_langsmith_names = true
  }

  assert {
    condition     = toset(keys(google_project_iam_custom_role.name_fenced)) == toset(["CloudSql", "Gke", "ForwardingRules", "Networks", "Subnetworks", "Routers", "Addresses", "RedisClusters", "ConnectionPolicies", "Storage", "SecretManager"])
    error_message = "One fenced role per kind."
  }

  assert {
    condition     = length(setintersection(google_project_iam_custom_role.provisioner.permissions, local.name_fenced_permissions)) == 0
    error_message = "Fenced permissions left the provisioner role."
  }

  assert {
    condition     = length(setunion(google_project_iam_custom_role.provisioner.permissions, local.name_fenced_permissions)) == length(local.base_provisioner_permissions)
    error_message = "No permission is lost overall."
  }

  assert {
    condition = alltrue([for p in [
      "compute.networks.create", "compute.networks.use", "compute.subnetworks.create", "compute.subnetworks.use",
      "compute.routers.create", "compute.addresses.create", "compute.addresses.createInternal", "compute.addresses.use",
      "compute.addresses.useInternal", "compute.globalAddresses.create", "compute.globalAddresses.createInternal",
      "compute.globalAddresses.delete", "compute.globalAddresses.deleteInternal", "compute.globalAddresses.setLabels",
      "compute.forwardingRules.pscCreate", "networkconnectivity.serviceConnectionPolicies.create",
    ] : !contains(google_project_iam_custom_role.provisioner.permissions, p)])
    error_message = "Network creates and use permissions are fenced."
  }

  assert {
    condition = alltrue([for p in [
      "compute.networks.get", "compute.routers.use", "compute.globalAddresses.use", "compute.globalAddresses.get",
      "compute.globalAddresses.list", "servicenetworking.services.addPeering", "artifactregistry.repositories.update",
    ] : contains(google_project_iam_custom_role.provisioner.permissions, p)])
    error_message = "Unfenceable and read permissions stay in the provisioner role."
  }

  assert {
    condition     = google_project_iam_member.name_fenced["Storage"].condition[0].expression == "resource.name.startsWith(\"projects/_/buckets/langsmith-\")" && google_project_iam_custom_role.name_fenced["SecretManager"].role_id == "langsmithByocNamedSecretManager"
    error_message = "Storage condition and role ID."
  }

  assert {
    condition     = length(google_project_iam_custom_role.postgres_setup) == 0 && length(google_project_iam_member.byo_iam_crossplane_container_admin) == 0
    error_message = "No byo_iam resources without byo_iam."
  }
}

run "byo_iam_unrestricted" {
  command = plan

  variables {
    byo_iam = true
  }

  assert {
    condition     = length(google_project_iam_member.byo_iam_crossplane_container_admin[0].condition) == 0
    error_message = "The Crossplane grant is unconditioned without restrict_to_langsmith_names."
  }

  assert {
    condition     = contains(keys(google_project_iam_member.byo_iam), "langsmith-postgres-setup/roles/cloudsql.admin") && length(google_project_iam_custom_role.postgres_setup) == 0
    error_message = "postgres-setup keeps roles/cloudsql.admin."
  }

  assert {
    condition     = alltrue([for m in google_project_iam_member.byo_iam : length(m.condition) == 0])
    error_message = "No byo_iam project grant is conditioned."
  }
}

run "restricted_byo_iam" {
  command = plan

  variables {
    restrict_to_langsmith_names = true
    byo_iam                     = true
  }

  assert {
    condition     = !contains(google_project_iam_custom_role.provisioner.permissions, "iam.serviceAccounts.create") && !contains(google_project_iam_custom_role.provisioner.permissions, "storage.buckets.delete") && length(google_project_iam_member.name_fenced) == 11
    error_message = "byo_iam and the fence both apply."
  }

  assert {
    condition     = google_project_iam_member.byo_iam_crossplane_container_admin[0].condition[0].expression == "resource.name.extract(\"/clusters/{name}\").startsWith(\"langsmith-\") || resource.name == \"\""
    error_message = "The Crossplane grant is limited to langsmith- clusters and Kubernetes requests."
  }

  assert {
    condition = alltrue([for k in [
      "langsmith-workload/roles/cloudsql.client",
      "langsmith-workload/roles/cloudsql.instanceUser",
      "langsmith-postgres-setup/roles/cloudsql.viewer",
    ] : google_project_iam_member.byo_iam[k].condition[0].expression == "resource.name.extract(\"/instances/{name}\").startsWith(\"langsmith-\")"])
    error_message = "Cloud SQL grants are limited to langsmith- instances."
  }

  assert {
    condition = alltrue([for k in [
      "langsmith-workload/roles/redis.dbConnectionUser",
      "langsmith-sandbox-host/roles/redis.dbConnectionUser",
    ] : google_project_iam_member.byo_iam[k].condition[0].expression == "resource.name.extract(\"/clusters/{name}\").startsWith(\"langsmith-\")"])
    error_message = "Redis grants are limited to langsmith- clusters."
  }

  assert {
    condition = alltrue([for k in [
      "langsmith-node/roles/artifactregistry.reader",
      "langsmith-node/roles/container.defaultNodeServiceAccount",
      "langsmith-sandbox-host/roles/artifactregistry.reader",
    ] : length(google_project_iam_member.byo_iam[k].condition) == 0])
    error_message = "Grants that carry no resource name stay unconditioned."
  }

  assert {
    condition     = !contains(keys(google_project_iam_member.byo_iam), "langsmith-postgres-setup/roles/cloudsql.admin")
    error_message = "postgres-setup loses roles/cloudsql.admin."
  }

  assert {
    condition     = toset(google_project_iam_custom_role.postgres_setup[0].permissions) == toset(["cloudsql.users.create", "cloudsql.users.list", "cloudsql.users.update"]) && length(google_project_iam_member.postgres_setup[0].condition) == 0
    error_message = "postgres-setup gets the users-only role, unconditioned."
  }

  assert {
    condition     = google_project_iam_member.byo_iam_external_secrets[0].condition[0].expression == "resource.name.extract(\"/secrets/{name}/\").startsWith(\"ls-\")"
    error_message = "External Secrets stays limited to ls- secrets."
  }
}

run "role_ids_fit_with_longest_prefix" {
  command = plan

  variables {
    restrict_to_langsmith_names = true
    byo_iam                     = true
    custom_role_id_prefix       = "abcdefghijabcdefghijabcdefghijabcdefghij"
  }

  assert {
    condition     = alltrue(concat([for r in google_project_iam_custom_role.name_fenced : length(r.role_id) <= 64], [for r in google_project_iam_custom_role.postgres_setup : length(r.role_id) <= 64]))
    error_message = "A custom role ID is longer than 64 characters."
  }
}
