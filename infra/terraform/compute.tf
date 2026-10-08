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

    access_config {
      nat_ip       = google_compute_address.vm.address
      network_tier = "PREMIUM"
    }
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
    google_project_iam_member.vm_logging,
    google_artifact_registry_repository_iam_member.vm_pull,
  ]
}
