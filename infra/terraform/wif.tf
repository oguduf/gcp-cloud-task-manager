# The Workload Identity Pool and its GitHub providers live in infra/bootstrap
# (the pipelines need them before this configuration can run).
# Here we only let the "deploy" provider's tokens impersonate the deployer SA.
resource "google_service_account_iam_member" "github_impersonates_deployer" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${var.wif_pool_name}/attribute.purpose/deploy"
}
