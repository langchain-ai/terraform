locals {
  # Found by provisioning and tearing down data planes with nothing more.
  provisioner_permissions = [
    "cloudsql.databases.create",
    "cloudsql.databases.delete",
    "cloudsql.databases.get",
    "cloudsql.databases.update",
    "cloudsql.instances.create",
    "cloudsql.instances.delete",
    "cloudsql.instances.get",
    "cloudsql.instances.update",
    "compute.addresses.create",
    "compute.addresses.createInternal",
    "compute.addresses.delete",
    "compute.addresses.deleteInternal",
    "compute.addresses.get",
    "compute.addresses.setLabels",
    "compute.addresses.use",
    "compute.addresses.useInternal",
    "compute.forwardingRules.create",
    "compute.forwardingRules.delete",
    "compute.forwardingRules.get",
    "compute.forwardingRules.pscCreate",
    "compute.forwardingRules.pscDelete",
    "compute.forwardingRules.pscSetLabels",
    "compute.forwardingRules.pscUpdate",
    "compute.forwardingRules.setLabels",
    "compute.globalAddresses.create",
    "compute.globalAddresses.createInternal",
    "compute.globalAddresses.delete",
    "compute.globalAddresses.deleteInternal",
    "compute.globalAddresses.get",
    "compute.globalAddresses.list",
    "compute.globalAddresses.setLabels",
    "compute.globalAddresses.use",
    "compute.globalOperations.get",
    "compute.instanceGroupManagers.get",
    "compute.networks.addPeering",
    "compute.networks.create",
    "compute.networks.delete",
    "compute.networks.get",
    "compute.networks.removePeering",
    "compute.networks.update",
    "compute.networks.updatePeering",
    "compute.networks.updatePolicy",
    "compute.networks.use",
    "compute.regionOperations.get",
    "compute.routers.create",
    "compute.routers.delete",
    "compute.routers.get",
    "compute.routers.update",
    "compute.routers.use",
    "compute.subnetworks.create",
    "compute.subnetworks.delete",
    "compute.subnetworks.get",
    "compute.subnetworks.setPrivateIpGoogleAccess",
    "compute.subnetworks.update",
    "compute.subnetworks.use",
    "container.clusters.create",
    "container.clusters.delete",
    "container.clusters.get",
    "container.clusters.update",
    "container.operations.get",
    "dns.changes.create",
    "dns.changes.get",
    "dns.managedZones.create",
    "dns.managedZones.delete",
    "dns.managedZones.get",
    "dns.managedZones.list",
    "dns.managedZones.update",
    "dns.networks.bindPrivateDNSZone",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.get",
    "iam.serviceAccounts.getIamPolicy",
    "iam.serviceAccounts.list",
    "iam.serviceAccounts.setIamPolicy",
    "iam.serviceAccounts.update",
    "networkconnectivity.operations.get",
    "networkconnectivity.serviceConnectionPolicies.create",
    "networkconnectivity.serviceConnectionPolicies.delete",
    "networkconnectivity.serviceConnectionPolicies.get",
    "networkconnectivity.serviceConnectionPolicies.update",
    "redis.clusters.create",
    "redis.clusters.delete",
    "redis.clusters.get",
    "redis.clusters.update",
    "redis.operations.get",
    "resourcemanager.projects.get",
    "resourcemanager.projects.getIamPolicy",
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.get",
    "secretmanager.versions.add",
    "servicedirectory.services.create",
    "servicedirectory.services.delete",
    "servicenetworking.operations.get",
    "servicenetworking.services.addPeering",
    "servicenetworking.services.deleteConnection",
    "servicenetworking.services.get",
    "storage.anywhereCaches.list",
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.get",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
    "storage.buckets.update",
    "storage.objects.delete",
    "storage.objects.list",
  ]

  # The project roles the data plane compositions grant: to the GKE node and
  # sandbox host service accounts, the in-cluster workloads, and the control
  # plane's Crossplane service account for its access to the cluster. The
  # provisioner may grant only these.
  granted_roles = [
    "roles/artifactregistry.reader",
    "roles/cloudsql.admin",
    "roles/cloudsql.client",
    "roles/container.admin",
    "roles/container.defaultNodeServiceAccount",
    "roles/dns.admin",
    "roles/redis.dbConnectionUser",
    "roles/secretmanager.secretAccessor",
  ]

  apis = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "networkconnectivity.googleapis.com",
    "redis.googleapis.com",
    "secretmanager.googleapis.com",
    "servicedirectory.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
  ])
}

resource "google_project_service" "apis" {
  for_each = var.enable_apis ? local.apis : toset([])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_service_account" "provisioner" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = "LangSmith BYOC provisioner"
  # LangSmith reads this description to verify that the LangSmith organization
  # with this external ID owns the provisioner.
  description = var.external_id

  # The IAM API must be enabled first in a new project.
  depends_on = [google_project_service.apis]
}

resource "google_project_iam_custom_role" "provisioner" {
  project     = var.project_id
  role_id     = "${var.custom_role_id_prefix}Provisioner"
  title       = "LangSmith BYOC provisioner"
  description = "Creates, updates and deletes the resources of LangSmith BYOC data planes"
  stage       = "BETA"
  permissions = local.provisioner_permissions

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_custom_role" "project_iam_granter" {
  project     = var.project_id
  role_id     = "${var.custom_role_id_prefix}ProjectIamGranter"
  title       = "LangSmith BYOC project IAM granter"
  description = "Grants data plane service accounts their project roles. The binding limits which roles."
  stage       = "BETA"
  permissions = [
    "resourcemanager.projects.getIamPolicy",
    "resourcemanager.projects.setIamPolicy",
  ]

  depends_on = [google_project_service.apis]
}

# Data planes run GKE nodes and workloads as service accounts the provisioner
# creates. IAM conditions are not evaluated for actAs, so this role is
# unconditional. The provisioner can only create and grant within the limits
# above.
resource "google_project_iam_custom_role" "service_account_user" {
  project     = var.project_id
  role_id     = "${var.custom_role_id_prefix}ServiceAccountUser"
  title       = "LangSmith BYOC service account user"
  description = "Runs GKE nodes and workloads as the data plane service accounts"
  stage       = "BETA"
  permissions = ["iam.serviceAccounts.actAs"]

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "provisioner" {
  project = var.project_id
  role    = google_project_iam_custom_role.provisioner.name
  member  = "serviceAccount:${google_service_account.provisioner.email}"
}

resource "google_project_iam_member" "service_account_user" {
  project = var.project_id
  role    = google_project_iam_custom_role.service_account_user.name
  member  = "serviceAccount:${google_service_account.provisioner.email}"
}

resource "google_project_iam_member" "project_iam_granter" {
  project = var.project_id
  role    = google_project_iam_custom_role.project_iam_granter.name
  member  = "serviceAccount:${google_service_account.provisioner.email}"

  condition {
    title       = "data-plane-roles-only"
    description = "Grant only the roles LangSmith data planes use"
    expression  = "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(${jsonencode(local.granted_roles)})"
  }
}

resource "google_service_account_iam_member" "crossplane" {
  service_account_id = google_service_account.provisioner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.crossplane_service_account}"
}
