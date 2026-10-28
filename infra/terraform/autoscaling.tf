resource "google_compute_region_autoscaler" "app" {
  name   = "${var.name}-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.app.id

  autoscaling_policy {
    min_replicas    = var.mig_min_replicas
    max_replicas    = var.mig_max_replicas
    cooldown_period = 120

    cpu_utilization {
      target = var.autoscaling_cpu_target
    }
  }
}
