locals {
  provisioner_roles = toset([
    "roles/cloudsql.admin",
    "roles/compute.admin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/networkconnectivity.consumerNetworkAdmin",
    "roles/redis.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/servicedirectory.editor",
    "roles/servicenetworking.networksAdmin",
    "roles/storage.admin",
  ])

  apis = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
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
  description  = "Impersonated by the LangSmith control plane to provision BYOC data planes"
}

resource "google_project_iam_member" "provisioner" {
  for_each = local.provisioner_roles

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.provisioner.email}"
}

resource "google_service_account_iam_member" "crossplane" {
  service_account_id = google_service_account.provisioner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.crossplane_service_account}"
}

resource "google_service_account_iam_member" "control_plane" {
  for_each = var.control_plane_service_accounts

  service_account_id = google_service_account.provisioner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${each.key}"
}
