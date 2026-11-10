locals {
  # Found by provisioning and tearing down data planes with nothing more.
  base_provisioner_permissions = [
    # In-cluster deployment builds push to one repository per data plane. Its
    # IAM policy grants the data plane's build service account write access.
    "artifactregistry.repositories.create",
    "artifactregistry.repositories.get",
    "artifactregistry.repositories.getIamPolicy",
    "artifactregistry.repositories.setIamPolicy",
    "artifactregistry.repositories.update",
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
    # cert-manager gets roles/dns.admin on the data plane's zones only.
    "dns.managedZones.getIamPolicy",
    "dns.managedZones.list",
    "dns.managedZones.setIamPolicy",
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
    "servicedirectory.namespaces.create",
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
    # The sandbox hosts' grant is on the bucket's smithbox/ managed folder.
    "storage.managedFolders.create",
    "storage.managedFolders.delete",
    "storage.managedFolders.get",
    "storage.managedFolders.getIamPolicy",
    "storage.managedFolders.list",
    "storage.managedFolders.setIamPolicy",
    "storage.objects.delete",
    "storage.objects.list",
  ]

  # With byo_iam, this module creates the data plane service accounts, so the
  # provisioner does not create, update, delete or set the IAM policy of
  # service accounts at the project level. It keeps get, list and
  # getIamPolicy, and gets setIamPolicy on the byo_iam accounts only.
  byo_iam_removed_permissions = [
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.update",
    "iam.serviceAccounts.setIamPolicy",
  ]

  # These permissions are not in the provisioner role but in roles of their
  # own, each bound with an IAM condition on the
  # resource name. Data plane resources are named langsmith-<hash>-<key> and
  # data plane secrets ls-<data plane>-<key>, so the provisioner can create,
  # change or delete only those, not other resources of these kinds in the
  # project.
  #
  # Each permission here was checked in a test project on 2026-11-09: a
  # langsmith- name was allowed and any other name denied. A condition that
  # uses an attribute the resource does not provide never grants access, so
  # kinds whose IAM checks carry no resource name (Artifact Registry
  # repositories, Cloud DNS, Cloud SQL databases, Service Directory,
  # servicenetworking) stay in the provisioner role.
  #
  # Creating a subnet or Cloud Router checks compute.networks.updatePolicy on
  # its network, and creating a global address checks compute.networks.use, so
  # the network fence also keeps the provisioner from adding them to a network
  # that is not LangSmith's. The use permissions are checked against the
  # subnet, address or network that a new resource refers to.
  name_fenced_roles = {
    CloudSql = {
      title       = "Cloud SQL"
      expression  = "resource.name.extract(\"/instances/{name}\").startsWith(\"langsmith-\")"
      permissions = ["cloudsql.instances.create", "cloudsql.instances.delete", "cloudsql.instances.update"]
    }
    Gke = {
      title = "GKE"
      # Node pool changes are checked against their cluster.
      expression  = "resource.name.extract(\"/clusters/{name}\").startsWith(\"langsmith-\")"
      permissions = ["container.clusters.create", "container.clusters.delete", "container.clusters.update"]
    }
    ForwardingRules = {
      title      = "forwarding rules"
      expression = "resource.name.extract(\"/forwardingRules/{name}\").startsWith(\"langsmith-\")"
      permissions = [
        "compute.forwardingRules.create",
        "compute.forwardingRules.delete",
        "compute.forwardingRules.pscCreate",
        "compute.forwardingRules.pscDelete",
        "compute.forwardingRules.pscSetLabels",
        "compute.forwardingRules.pscUpdate",
        "compute.forwardingRules.setLabels",
      ]
    }
    Networks = {
      title      = "VPC networks"
      expression = "resource.name.extract(\"/networks/{name}\").startsWith(\"langsmith-\")"
      permissions = [
        "compute.networks.addPeering",
        "compute.networks.create",
        "compute.networks.delete",
        "compute.networks.removePeering",
        "compute.networks.update",
        "compute.networks.updatePeering",
        "compute.networks.updatePolicy",
        "compute.networks.use",
      ]
    }
    Subnetworks = {
      title      = "subnets"
      expression = "resource.name.extract(\"/subnetworks/{name}\").startsWith(\"langsmith-\")"
      permissions = [
        "compute.subnetworks.create",
        "compute.subnetworks.delete",
        "compute.subnetworks.setPrivateIpGoogleAccess",
        "compute.subnetworks.update",
        "compute.subnetworks.use",
      ]
    }
    # Cloud Routers, and the Cloud NAT configured on them.
    Routers = {
      title       = "Cloud Routers"
      expression  = "resource.name.extract(\"/routers/{name}\").startsWith(\"langsmith-\")"
      permissions = ["compute.routers.create", "compute.routers.delete", "compute.routers.update"]
    }
    # Regional addresses, and the global address of the private services
    # access range: both names end in /addresses/<name>.
    Addresses = {
      title      = "addresses"
      expression = "resource.name.extract(\"/addresses/{name}\").startsWith(\"langsmith-\")"
      permissions = [
        "compute.addresses.create",
        "compute.addresses.createInternal",
        "compute.addresses.delete",
        "compute.addresses.deleteInternal",
        "compute.addresses.setLabels",
        "compute.addresses.use",
        "compute.addresses.useInternal",
        "compute.globalAddresses.create",
        "compute.globalAddresses.createInternal",
        "compute.globalAddresses.delete",
        "compute.globalAddresses.deleteInternal",
        "compute.globalAddresses.setLabels",
      ]
    }
    RedisClusters = {
      title       = "Memorystore for Redis Cluster"
      expression  = "resource.name.extract(\"/clusters/{name}\").startsWith(\"langsmith-\")"
      permissions = ["redis.clusters.create", "redis.clusters.delete", "redis.clusters.update"]
    }
    # Creating a policy checks no permission on its network, so the provisioner
    # can still create a langsmith- policy in any network in the project.
    ConnectionPolicies = {
      title      = "service connection policies"
      expression = "resource.name.extract(\"/serviceConnectionPolicies/{name}\").startsWith(\"langsmith-\")"
      permissions = [
        "networkconnectivity.serviceConnectionPolicies.create",
        "networkconnectivity.serviceConnectionPolicies.delete",
        "networkconnectivity.serviceConnectionPolicies.update",
      ]
    }
    # Buckets, their objects and managed folders. Cloud Storage resource names
    # have _ in place of the project.
    Storage = {
      title      = "Cloud Storage"
      expression = "resource.name.startsWith(\"projects/_/buckets/langsmith-\")"
      permissions = [
        "storage.buckets.create",
        "storage.buckets.delete",
        "storage.buckets.setIamPolicy",
        "storage.buckets.update",
        "storage.managedFolders.create",
        "storage.managedFolders.delete",
        "storage.managedFolders.setIamPolicy",
        "storage.objects.delete",
      ]
    }
    # Secret Manager names hold the project number, and versions are
    # <secret>/versions/<n>, so the condition matches the secret ID.
    SecretManager = {
      title       = "Secret Manager"
      expression  = "resource.name.extract(\"/secrets/{name}\").startsWith(\"ls-\")"
      permissions = ["secretmanager.secrets.create", "secretmanager.secrets.delete", "secretmanager.versions.add"]
    }
  }

  name_fenced_permissions = flatten([for role in values(local.name_fenced_roles) : role.permissions])

  provisioner_removed_permissions = concat(
    var.byo_iam ? local.byo_iam_removed_permissions : [],
    local.name_fenced_permissions,
  )

  provisioner_permissions = sort(setsubtract(local.base_provisioner_permissions, local.provisioner_removed_permissions))

  # The project roles the data plane compositions grant: to the GKE node and
  # sandbox host service accounts, the in-cluster workloads, and the control
  # plane's Crossplane service account for its access to the cluster. The
  # provisioner may grant only these.
  granted_roles = [
    "roles/artifactregistry.reader",
    "roles/cloudsql.admin",
    "roles/cloudsql.client",
    # The app logs in to Cloud SQL as its IAM database user.
    "roles/cloudsql.instanceUser",
    "roles/container.admin",
    "roles/container.defaultNodeServiceAccount",
    "roles/redis.dbConnectionUser",
    "roles/secretmanager.secretAccessor",
  ]

  apis = toset([
    "artifactregistry.googleapis.com",
    "binaryauthorization.googleapis.com",
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

# Without byo_iam, the data plane compositions grant the data plane service
# accounts their project roles. With byo_iam, this module makes those grants,
# so the role and its binding are not created.
resource "google_project_iam_custom_role" "project_iam_granter" {
  count = var.byo_iam ? 0 : 1

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
# creates. IAM checks on a service account carry only its numeric unique ID,
# not its email, and the provisioner creates these accounts, so no condition
# can single them out and this role is unconditional. The provisioner can only
# create and grant within the limits above. With byo_iam, the provisioner gets
# actAs on the node service accounts only, so the role and its binding are not
# created.
resource "google_project_iam_custom_role" "service_account_user" {
  count = var.byo_iam ? 0 : 1

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

resource "google_project_iam_custom_role" "name_fenced" {
  for_each = local.name_fenced_roles

  project     = var.project_id
  role_id     = "${var.custom_role_id_prefix}Named${each.key}"
  title       = "LangSmith BYOC provisioner: ${each.value.title}"
  description = "Creates, changes and deletes ${each.value.title} resources of LangSmith BYOC data planes. The binding limits it to data plane names."
  stage       = "BETA"
  permissions = each.value.permissions

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "name_fenced" {
  for_each = local.name_fenced_roles

  project = var.project_id
  role    = google_project_iam_custom_role.name_fenced[each.key].name
  member  = "serviceAccount:${google_service_account.provisioner.email}"

  condition {
    title       = "langsmith-data-plane-names"
    description = "LangSmith data plane ${each.value.title} resources only"
    expression  = each.value.expression
  }
}

resource "google_project_iam_member" "service_account_user" {
  count = var.byo_iam ? 0 : 1

  project = var.project_id
  role    = google_project_iam_custom_role.service_account_user[0].name
  member  = "serviceAccount:${google_service_account.provisioner.email}"
}

resource "google_project_iam_member" "project_iam_granter" {
  count = var.byo_iam ? 0 : 1

  project = var.project_id
  role    = google_project_iam_custom_role.project_iam_granter[0].name
  member  = "serviceAccount:${google_service_account.provisioner.email}"

  condition {
    title       = "data-plane-roles-only"
    description = "Grant only the roles LangSmith data planes use"
    expression  = "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(${jsonencode(local.granted_roles)})"
  }
}

# These resources had no count before byo_iam. The moved blocks keep the
# addresses of existing deployments, so byo_iam = false plans no change.
moved {
  from = google_project_iam_custom_role.project_iam_granter
  to   = google_project_iam_custom_role.project_iam_granter[0]
}

moved {
  from = google_project_iam_custom_role.service_account_user
  to   = google_project_iam_custom_role.service_account_user[0]
}

moved {
  from = google_project_iam_member.service_account_user
  to   = google_project_iam_member.service_account_user[0]
}

moved {
  from = google_project_iam_member.project_iam_granter
  to   = google_project_iam_member.project_iam_granter[0]
}

resource "google_service_account_iam_member" "crossplane" {
  service_account_id = google_service_account.provisioner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.crossplane_service_account}"
}

# ---------------------------------------------------------------------------
# Bring your own IAM (byo_iam = true)
#
# This module creates the data plane service accounts and their project role
# grants. The data plane compositions find the accounts by account ID, so the
# IDs below are a contract with LangSmith. All data planes in the project share
# the accounts.
#
# The control plane still creates the Workload Identity bindings and the
# workload's Token Creator grant on itself: the project's workload identity
# pool exists only after the first GKE cluster. So the provisioner gets
# getIamPolicy and setIamPolicy on these accounts, and actAs on the two that
# GKE node pools run as.
# ---------------------------------------------------------------------------

locals {
  byo_iam_service_accounts = var.byo_iam ? {
    "langsmith-workload" = {
      display_name = "LangSmith workload"
      description  = "LangSmith application workloads in the data plane GKE clusters"
      roles        = ["roles/cloudsql.client", "roles/cloudsql.instanceUser", "roles/redis.dbConnectionUser"]
      act_as       = false
    }
    # Secret Manager access is the conditional grant below.
    "langsmith-external-secrets" = {
      display_name = "LangSmith External Secrets"
      description  = "External Secrets Operator in the data plane GKE clusters"
      roles        = []
      act_as       = false
    }
    # The data plane compositions grant roles/dns.admin on each data plane's
    # DNS zones, not on the project.
    "langsmith-cert-manager" = {
      display_name = "LangSmith cert-manager"
      description  = "cert-manager DNS-01 challenges in the data plane GKE clusters"
      roles        = []
      act_as       = false
    }
    # Plus <prefix>PostgresSetup below. Together they replace
    # roles/cloudsql.admin, which the compositions grant without byo_iam.
    "langsmith-postgres-setup" = {
      display_name = "LangSmith Postgres setup"
      description  = "Sets up the data plane Cloud SQL databases"
      roles        = ["roles/cloudsql.viewer"]
      act_as       = false
    }
    "langsmith-node" = {
      display_name = "LangSmith GKE nodes"
      description  = "Nodes of the data plane GKE clusters"
      roles        = ["roles/artifactregistry.reader", "roles/container.defaultNodeServiceAccount"]
      act_as       = true
    }
    "langsmith-sandbox-host" = {
      display_name = "LangSmith sandbox GKE nodes"
      description  = "Sandbox nodes of the data plane GKE clusters"
      roles        = ["roles/artifactregistry.reader", "roles/container.defaultNodeServiceAccount", "roles/redis.dbConnectionUser"]
      act_as       = true
    }
  } : {}

  # Keyed "<account ID>/<role>".
  byo_iam_project_roles = merge([
    for name, sa in local.byo_iam_service_accounts : {
      for role in sa.roles : "${name}/${role}" => { account = name, role = role }
    }
  ]...)

  # These grants are limited to the data plane resources by name. Each was checked in a test project on 2026-11-09:
  # cloudsql.instances.get, connect (the Cloud SQL connectors) and login (IAM
  # database authentication), and redis.clusters.connect, were allowed on a
  # langsmith- instance or cluster and denied on any other.
  byo_iam_role_conditions = {
    "roles/cloudsql.client"        = local.name_fenced_roles.CloudSql.expression
    "roles/cloudsql.instanceUser"  = local.name_fenced_roles.CloudSql.expression
    "roles/cloudsql.viewer"        = local.name_fenced_roles.CloudSql.expression
    "roles/redis.dbConnectionUser" = local.name_fenced_roles.RedisClusters.expression
  }

  # The postgres-setup Job lists and creates database users and sets the
  # postgres password (gcloud sql users list, create, set-password). IAM
  # checks of Cloud SQL users carry no instance name, so these permissions
  # reach every instance in the project. They replace roles/cloudsql.admin,
  # which could also change, export or delete any instance. The Job reads its
  # instance through roles/cloudsql.viewer, limited by name above.
  postgres_setup_permissions = [
    "cloudsql.users.create",
    "cloudsql.users.list",
    "cloudsql.users.update",
  ]

  # Kubernetes API requests to GKE are authorized by IAM with an empty
  # resource name, so a condition on the cluster name alone denies them on
  # every cluster. The condition below limits the GKE API (getting
  # credentials, changing or deleting a cluster) and the clusters' DNS-based
  # endpoints, which LangSmith uses, to langsmith- clusters. Through a
  # cluster's IP-based endpoint, Kubernetes requests are still allowed on
  # every cluster in the project that the control plane can reach.
  crossplane_container_admin_condition = "${local.name_fenced_roles.Gke.expression} || resource.name == \"\""
}

resource "google_service_account" "byo_iam" {
  for_each = local.byo_iam_service_accounts

  project      = var.project_id
  account_id   = each.key
  display_name = each.value.display_name
  description  = each.value.description

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "byo_iam" {
  for_each = local.byo_iam_project_roles

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.byo_iam[each.value.account].email}"

  dynamic "condition" {
    for_each = contains(keys(local.byo_iam_role_conditions), each.value.role) ? [local.byo_iam_role_conditions[each.value.role]] : []

    content {
      title       = "langsmith-data-plane-names"
      description = "LangSmith data plane resources only"
      expression  = condition.value
    }
  }
}

resource "google_project_iam_custom_role" "postgres_setup" {
  count = var.byo_iam ? 1 : 0

  project     = var.project_id
  role_id     = "${var.custom_role_id_prefix}PostgresSetup"
  title       = "LangSmith BYOC Postgres setup"
  description = "Creates the database users of LangSmith BYOC data planes and sets the postgres password"
  stage       = "BETA"
  permissions = local.postgres_setup_permissions

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "postgres_setup" {
  count = var.byo_iam ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.postgres_setup[0].name
  member  = "serviceAccount:${google_service_account.byo_iam["langsmith-postgres-setup"].email}"
}

# External Secrets reads only the data plane secrets, whose IDs start with
# "ls-". The role grants only secretmanager.versions.access, which IAM
# evaluates on the secret version.
resource "google_project_iam_member" "byo_iam_external_secrets" {
  count = var.byo_iam ? 1 : 0

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.byo_iam["langsmith-external-secrets"].email}"

  condition {
    title       = "langsmith-data-plane-secrets"
    description = "LangSmith data plane secrets"
    expression  = "resource.name.extract(\"/secrets/{name}/\").startsWith(\"ls-\")"
  }
}

# The control plane's Crossplane service account reaches the data plane GKE
# clusters through this role, limited as described at
# crossplane_container_admin_condition.
resource "google_project_iam_member" "byo_iam_crossplane_container_admin" {
  count = var.byo_iam ? 1 : 0

  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${var.crossplane_service_account}"

  condition {
    title       = "langsmith-data-plane-clusters"
    description = "LangSmith data plane GKE clusters, and Kubernetes API requests"
    expression  = local.crossplane_container_admin_condition
  }
}

resource "google_project_iam_custom_role" "service_account_iam_manager" {
  count = var.byo_iam ? 1 : 0

  project     = var.project_id
  role_id     = "${var.custom_role_id_prefix}ServiceAccountIamManager"
  title       = "LangSmith BYOC service account IAM manager"
  description = "Manages Workload Identity and Token Creator grants on the data plane service accounts"
  stage       = "BETA"
  permissions = [
    "iam.serviceAccounts.getIamPolicy",
    "iam.serviceAccounts.setIamPolicy",
  ]

  depends_on = [google_project_service.apis]
}

resource "google_service_account_iam_member" "byo_iam_iam_manager" {
  for_each = local.byo_iam_service_accounts

  service_account_id = google_service_account.byo_iam[each.key].name
  role               = google_project_iam_custom_role.service_account_iam_manager[0].name
  member             = "serviceAccount:${google_service_account.provisioner.email}"
}

# GKE node pools run as these accounts, which needs actAs on them.
resource "google_service_account_iam_member" "byo_iam_service_account_user" {
  for_each = { for name, sa in local.byo_iam_service_accounts : name => sa if sa.act_as }

  service_account_id = google_service_account.byo_iam[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.provisioner.email}"
}
