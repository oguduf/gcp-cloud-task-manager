data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_compute_instance" "vm" {
  name         = "${var.name}-vm"
  zone         = var.zone
  machine_type = var.machine_type

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    network_ip = var.vm_internal_ip
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"] # IAM roles decide what it can do
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = file("${path.module}/../vm-startup.sh") # installs Docker
    mongo-url      = local.mongo_url                         # read by deploy/deploy.sh; holds no secret
  }

  lifecycle {
    # A newer debian-12 image must not replace a running VM.
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }

  depends_on = [
    google_compute_router_nat.private,
    google_project_iam_member.vm_logging,
    google_artifact_registry_repository_iam_member.vm_pull,
  ]
}

# New immutable template and regional MIG coexist with the existing VM during
# migration. The application workflow creates SHA-named copies of this template
# and rolls the MIG forward; Terraform owns the baseline MIG configuration.
resource "google_compute_instance_template" "app" {
  name_prefix  = "${var.name}-template-"
  machine_type = var.machine_type
  description  = "Baseline employee dashboard template; releases use immutable SHA-suffixed copies."
  tags         = ["${var.name}-app"]

  disk {
    source_image = data.google_compute_image.debian.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-balanced"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config: instances only receive private addresses.
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin     = "TRUE"
    startup-script     = file("${path.module}/../mig-startup.sh")
    app-backend-image  = "${var.region}-docker.pkg.dev/${var.project_id}/${var.name}/employee-backend:${var.initial_image_tag}"
    app-frontend-image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.name}/employee-frontend:${var.initial_image_tag}"
    mongo-url          = local.mongo_url
    mongo-db-name      = var.firestore_database_id
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_compute_router_nat.private,
    google_project_iam_member.vm_logging,
    google_artifact_registry_repository_iam_member.vm_pull,
  ]
}

resource "google_compute_region_instance_group_manager" "app" {
  name                      = "${var.name}-mig"
  region                    = var.region
  base_instance_name        = var.name
  distribution_policy_zones = var.zones
  target_size               = var.mig_min_replicas

  version {
    instance_template = google_compute_instance_template.app.self_link
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app.id
    initial_delay_sec = 600
  }

  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    # Regional MIG surge must be zero or at least one extra per configured zone.
    max_surge_fixed       = length(var.zones)
    max_unavailable_fixed = 0
  }

  lifecycle {
    # Autoscaler and the app release workflow own live size and template version.
    ignore_changes = [target_size, version]
  }

  depends_on = [google_compute_router_nat.private]
}
