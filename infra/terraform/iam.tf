# ---------------------------------------------------------------------------
# Service accounts
# ---------------------------------------------------------------------------
resource "google_service_account" "deployer" {
  account_id   = "gh-deployer"
  display_name = "GitHub Actions deployer (OIDC)"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "vm" {
  account_id   = "${var.name}-vm"
  display_name = "Profile app VM runtime"

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# VM runtime identity: pull images (artifact_registry.tf), use ONE Firestore
# database, write logs and metrics.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "vm_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = google_service_account.vm.member

  condition {
    title       = "only-${var.firestore_database_id}-db"
    description = "Read/write documents in the ${var.firestore_database_id} Firestore database only"
    expression  = "resource.name == \"projects/${var.project_id}/databases/${var.firestore_database_id}\""
  }
}

resource "google_project_iam_member" "vm_logging" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])

  project = var.project_id
  role    = each.value
  member  = google_service_account.vm.member
}

# ---------------------------------------------------------------------------
# Deployer identity (impersonated by GitHub Actions): push images
# (artifact_registry.tf) and sudo-SSH into this one VM through IAP.
# ---------------------------------------------------------------------------
resource "google_compute_instance_iam_member" "deployer_os_admin_login" {
  zone          = google_compute_instance.vm.zone
  instance_name = google_compute_instance.vm.name
  role          = "roles/compute.osAdminLogin"
  member        = google_service_account.deployer.member
}

resource "google_iap_tunnel_instance_iam_member" "deployer_iap" {
  zone     = google_compute_instance.vm.zone
  instance = google_compute_instance.vm.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = google_service_account.deployer.member
}

# OS Login on a VM that runs as a service account requires actAs on that SA.
resource "google_service_account_iam_member" "deployer_act_as_vm" {
  service_account_id = google_service_account.vm.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer.member
}

# `gcloud compute ssh` reads instance and project metadata.
resource "google_project_iam_member" "deployer_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = google_service_account.deployer.member
}
