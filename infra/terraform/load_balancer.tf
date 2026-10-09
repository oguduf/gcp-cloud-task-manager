# The public frontend is a Google-managed global resource, not a VM in a
# "public subnet". The existing subnet becomes private when the VM loses its
# external IP. This single-VM backend is not highly available.
resource "google_compute_global_address" "lb" {
  name         = "${var.name}-lb-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

resource "google_compute_instance_group" "app" {
  name      = "${var.name}-ig"
  zone      = var.zone
  network   = google_compute_network.vpc.id
  instances = [google_compute_instance.vm.id]

  named_port {
    name = "http"
    port = 80
  }
}

resource "google_compute_health_check" "app" {
  name               = "${var.name}-health"
  check_interval_sec = 10
  timeout_sec        = 5

  http_health_check {
    port         = 80
    request_path = "/healthz"
  }
}

resource "google_compute_backend_service" "app" {
  name                  = "${var.name}-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.app.id]

  backend {
    group           = google_compute_instance_group.app.self_link
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
  }

  log_config {
    enable      = true
    sample_rate = 0.1
  }
}

resource "google_compute_url_map" "app" {
  name            = "${var.name}-routes"
  default_service = google_compute_backend_service.app.id
}

resource "google_compute_target_http_proxy" "app" {
  name    = "${var.name}-http-proxy"
  url_map = google_compute_url_map.app.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http"
  target                = google_compute_target_http_proxy.app.id
  ip_address            = google_compute_global_address.lb.address
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
}
