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

# Only Google's global external Application Load Balancer proxies and health
# checks may reach the VM on port 80. The VM has no external IP.
resource "google_compute_firewall" "allow_http" {
  name      = "${var.name}-allow-http"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 1000

  source_ranges           = ["35.191.0.0/16", "130.211.0.0/22"]
  target_service_accounts = [google_service_account.vm.email]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# A VM without an external IP still needs outbound access for OS updates and
# Docker downloads. Private Google Access on the subnet handles Firestore.
resource "google_compute_router" "private" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "private" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.private.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.subnet.id
    source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
