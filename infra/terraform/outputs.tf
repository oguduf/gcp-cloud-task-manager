output "app_url" {
  description = "Public load-balancer URL. HTTPS is active only when domain_name is configured and DNS points at the load-balancer IP."
  value       = var.domain_name == "" ? "http://${google_compute_global_address.lb.address}" : "https://${var.domain_name}"
}

output "mongo_url" {
  description = "Firestore (MongoDB compatibility) connection string. Contains no credentials."
  value       = local.mongo_url
}

output "deployer_service_account" {
  description = "Must equal the GitHub variable GCP_DEPLOYER_SA."
  value       = google_service_account.deployer.email
}

output "vm_name" {
  description = "Must equal the GitHub variable GCE_VM_NAME."
  value       = google_compute_instance.vm.name
}

output "mig_name" {
  description = "Regional managed instance group serving the application."
  value       = google_compute_region_instance_group_manager.app.name
}

output "instance_template_name" {
  description = "Baseline template cloned by the GitHub Actions application deployment workflow."
  value       = google_compute_instance_template.app.name
}

output "load_balancer_ip" {
  description = "Public global load-balancer IPv4 address."
  value       = google_compute_global_address.lb.address
}

output "monitoring_dashboard" {
  description = "Cloud Monitoring dashboard resource name."
  value       = google_monitoring_dashboard.app.id
}
