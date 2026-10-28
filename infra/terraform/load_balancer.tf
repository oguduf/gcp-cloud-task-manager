# The public frontend is a Google-managed global resource, not a VM in a
# "public subnet". The existing subnet becomes private when the VM loses its
# external IP. This single-VM backend is not highly available.
resource "google_compute_global_address" "lb" {
  name         = "${var.name}-lb-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

# Legacy backend retained through migration; the old VM and its instance group
# remain managed until the MIG cutover is verified.
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

  # Keep the existing VM backend online through cutover. Remove it only after
  # the regional MIG is healthy and serving a verified application release.
  backend {
    group           = google_compute_instance_group.app.self_link
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
  }

  backend {
    group           = google_compute_region_instance_group_manager.app.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  connection_draining_timeout_sec = 60
}

resource "google_compute_url_map" "app" {
  name            = "${var.name}-routes"
  default_service = google_compute_backend_service.app.id
}

resource "google_compute_url_map" "http_redirect" {
  count = var.domain_name == "" ? 0 : 1
  name  = "${var.name}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

resource "google_compute_target_http_proxy" "app" {
  name    = "${var.name}-http-proxy"
  url_map = var.domain_name == "" ? google_compute_url_map.app.id : google_compute_url_map.http_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http"
  target                = google_compute_target_http_proxy.app.id
  ip_address            = google_compute_global_address.lb.address
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
}

resource "google_compute_managed_ssl_certificate" "app" {
  count = var.domain_name == "" ? 0 : 1
  name  = "${var.name}-managed-cert"

  managed {
    domains = [var.domain_name]
  }
}

resource "google_compute_ssl_policy" "app" {
  count           = var.domain_name == "" ? 0 : 1
  name            = "${var.name}-tls-policy"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "app" {
  count            = var.domain_name == "" ? 0 : 1
  name             = "${var.name}-https-proxy"
  url_map          = google_compute_url_map.app.id
  ssl_certificates = [google_compute_managed_ssl_certificate.app[0].id]
  ssl_policy       = google_compute_ssl_policy.app[0].id
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.domain_name == "" ? 0 : 1
  name                  = "${var.name}-https"
  target                = google_compute_target_https_proxy.app[0].id
  ip_address            = google_compute_global_address.lb.address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
}
