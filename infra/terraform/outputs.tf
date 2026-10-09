output "app_url" {
  description = "Public load-balancer URL of the app (after the first deploy)."
  value       = "http://${google_compute_global_address.lb.address}"
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
