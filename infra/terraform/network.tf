# Dedicated custom-mode VPC: no auto subnets, none of the default network's
# open SSH/RDP/ICMP rules. Everything not allowed below hits the implied deny.
resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name}-subnet"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  # Lets the VM reach Google APIs if you later remove its public IP
  # (add Cloud NAT at that point for apt / Docker installs).
  private_ip_google_access = true
}

# SSH only from Google's IAP TCP-forwarding range - no public port 22.
resource "google_compute_firewall" "allow_iap_ssh" {
  name      = "${var.name}-allow-iap-ssh"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 1000

  source_ranges           = ["35.235.240.0/20"]
  target_service_accounts = [google_service_account.vm.email]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# The app (Docker publishes host :80 -> container :3000).
resource "google_compute_firewall" "allow_http" {
  name      = "${var.name}-allow-http"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 1000

  source_ranges           = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.vm.email]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# Survives VM stop / recreate, so the app URL never changes.
resource "google_compute_address" "vm" {
  name         = "${var.name}-vm-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  depends_on = [google_project_service.apis]
}
