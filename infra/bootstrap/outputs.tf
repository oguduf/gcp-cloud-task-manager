locals {
  github_variables = {
    GCP_PROJECT_ID   = var.project_id
    GCP_REGION       = var.region
    GCP_ZONE         = var.zone
    TF_STATE_BUCKET  = google_storage_bucket.tfstate.name
    GCP_WIF_POOL     = google_iam_workload_identity_pool.github.name
    GCP_WIF_PROVIDER = google_iam_workload_identity_pool_provider.github["deploy"].name

    GCP_WIF_PROVIDER_TF_PLAN  = google_iam_workload_identity_pool_provider.github["tf-plan"].name
    GCP_WIF_PROVIDER_TF_APPLY = google_iam_workload_identity_pool_provider.github["tf-apply"].name
    GCP_TF_PLAN_SA            = google_service_account.tf_plan.email
    GCP_TF_APPLY_SA           = google_service_account.tf_apply.email

    # Created later by infra/terraform; names are fixed, so set them now.
    GCP_DEPLOYER_SA = "gh-deployer@${var.project_id}.iam.gserviceaccount.com"
    GCP_AR_REPO     = var.app_name
    GCE_VM_NAME     = "${var.app_name}-vm"
  }
}

output "github_variables" {
  description = "GitHub Actions repository variables (none are secrets)."
  value       = local.github_variables
}

output "gh_setup_commands" {
  description = "Paste into a shell with the GitHub CLI logged in: sets all variables, protects the main branch and creates the approval-gated environment."
  value = join("\n", concat(
    [for k, v in local.github_variables : "gh variable set ${k} -R ${var.github_repo} -b '${v}'"],
    [
      "",
      "# Protect ${var.main_branch}: changes arrive through pull requests (where the plan is posted).",
      "gh api -X PUT repos/${var.github_repo}/branches/${var.main_branch}/protection --input - <<'JSON'",
      "{\"required_status_checks\":null,\"enforce_admins\":false,\"required_pull_request_reviews\":{\"required_approving_review_count\":0},\"restrictions\":null}",
      "JSON",
      "",
      "# Environment '${var.apply_environment}': every terraform apply waits for your approval; only protected branches can use it.",
      "gh api -X PUT repos/${var.github_repo}/environments/${var.apply_environment} -F 'reviewers[][type]=User' -F \"reviewers[][id]=$(gh api user -q .id)\" -F 'deployment_branch_policy[protected_branches]=true' -F 'deployment_branch_policy[custom_branch_policies]=false'",
    ],
  ))
}

output "state_bucket" {
  description = "Bucket holding the infra/terraform state."
  value       = google_storage_bucket.tfstate.name
}
