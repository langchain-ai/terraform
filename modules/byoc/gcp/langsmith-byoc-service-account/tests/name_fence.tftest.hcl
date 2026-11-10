# Plan tests with a mocked provider: no credentials and no state. Run with
# terraform init -backend=false && terraform test in the module directory.

mock_provider "google" {
  mock_resource "google_tags_tag_key" {
    override_during = plan
    defaults = {
      id = "tagKeys/111"
    }
  }

  mock_resource "google_tags_tag_value" {
    override_during = plan
    defaults = {
      id = "tagValues/222"
    }
  }
}

variables {
  project_id                 = "p"
  crossplane_service_account = "cp@x.iam.gserviceaccount.com"
  external_id                = "ext"
}

run "default" {
  command = plan

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
    condition     = length(google_project_iam_custom_role.postgres_setup) == 0 && length(google_project_iam_member.byo_iam) == 0
    error_message = "No byo_iam resources without byo_iam."
  }

  assert {
    condition     = google_project_iam_member.crossplane_container_admin.condition[0].expression == "resource.matchTagId(\"tagKeys/111\", \"tagValues/222\")" && !strcontains(google_project_iam_member.project_iam_granter[0].condition[0].expression, "roles/container.admin")
    error_message = "The module grants Crossplane container.admin on clusters with the cluster tag, and the provisioner can't grant container.admin."
  }

  assert {
    condition     = google_project_iam_custom_role.cluster_connect.permissions == toset(["container.clusters.connect"]) && google_project_iam_member.crossplane_cluster_connect.condition[0].expression == "resource.name.extract(\"/clusters/{name}\").startsWith(\"langsmith-\")"
    error_message = "Crossplane gets connect on langsmith- clusters only."
  }

  assert {
    condition     = google_tags_tag_key.cluster[0].short_name == "managed_by" && google_tags_tag_key.cluster[0].parent == "projects/p" && google_tags_tag_value.cluster.short_name == "langsmith" && google_tags_tag_value_iam_member.provisioner.role == "roles/resourcemanager.tagUser"
    error_message = "The cluster tag is managed_by: langsmith, and the provisioner can use it."
  }

  assert {
    condition     = alltrue([for p in ["container.clusters.createTagBinding", "container.clusters.deleteTagBinding"] : contains(google_project_iam_custom_role.name_fenced["Gke"].permissions, p) && !contains(google_project_iam_custom_role.provisioner.permissions, p)]) && length([for p in google_project_iam_custom_role.provisioner.permissions : p if strcontains(p, "createTagBinding")]) == 0
    error_message = "The provisioner can tag only langsmith- clusters."
  }

  assert {
    condition     = length(google_project_iam_custom_role.project_iam_granter) == 1 && length(google_project_iam_custom_role.service_account_user) == 1 && contains(google_project_iam_custom_role.provisioner.permissions, "iam.serviceAccounts.create")
    error_message = "Without byo_iam, the provisioner keeps its IAM roles."
  }
}

run "byo_iam" {
  command = plan

  variables {
    byo_iam = true
  }

  assert {
    condition     = !contains(google_project_iam_custom_role.provisioner.permissions, "iam.serviceAccounts.create") && !contains(google_project_iam_custom_role.provisioner.permissions, "storage.buckets.delete") && length(google_project_iam_member.name_fenced) == 11
    error_message = "byo_iam and the fence both apply."
  }

  assert {
    condition     = google_project_iam_member.crossplane_container_admin.condition[0].expression == "resource.matchTagId(\"tagKeys/111\", \"tagValues/222\")"
    error_message = "The Crossplane grant is limited to clusters with the cluster tag."
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

run "shared_cluster_tag_key" {
  command = plan

  variables {
    cluster_tag_key   = "tagKeys/999"
    cluster_tag_value = "langsmith-stg"
  }

  assert {
    condition     = length(google_tags_tag_key.cluster) == 0 && google_tags_tag_value.cluster.parent == "tagKeys/999" && google_tags_tag_value.cluster.short_name == "langsmith-stg"
    error_message = "A second copy adds its value to the existing managed_by key."
  }

  assert {
    condition     = google_project_iam_member.crossplane_container_admin.condition[0].expression == "resource.matchTagId(\"tagKeys/999\", \"tagValues/222\")"
    error_message = "The Crossplane grant matches the existing key."
  }
}

run "role_ids_fit_with_longest_prefix" {
  command = plan

  variables {
    byo_iam               = true
    custom_role_id_prefix = "abcdefghijabcdefghijabcdefghijabcdefghij"
  }

  assert {
    condition     = alltrue(concat([for r in google_project_iam_custom_role.name_fenced : length(r.role_id) <= 64], [for r in google_project_iam_custom_role.postgres_setup : length(r.role_id) <= 64], [length(google_project_iam_custom_role.cluster_connect.role_id) <= 64]))
    error_message = "A custom role ID is longer than 64 characters."
  }
}

run "deployment_observability" {
  command = plan

  variables {
    deployment_observability = true
  }

  assert {
    condition     = alltrue([for p in local.observability_provisioner_permissions : contains(google_project_iam_custom_role.provisioner.permissions, p)])
    error_message = "Deployment observability adds its log bucket and sink permissions to the provisioner role."
  }

  assert {
    condition     = length(setintersection(google_project_iam_custom_role.provisioner.permissions, local.name_fenced_permissions)) == 0
    error_message = "Fenced permissions stay out of the provisioner role with deployment observability."
  }

  assert {
    condition     = contains(local.granted_roles, "roles/logging.viewAccessor") && !contains(local.granted_roles, "roles/container.admin")
    error_message = "The provisioner may grant the observability roles but not roles/container.admin."
  }
}
