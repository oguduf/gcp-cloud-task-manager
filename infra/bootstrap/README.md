# Bootstrap

This Terraform root creates the GitHub Actions Workload Identity Federation (WIF) pool/providers and service accounts, required APIs, and the Terraform state bucket.

## First-time setup

GitHub Actions cannot create the first WIF provider because it needs WIF to authenticate. Run this root once from Cloud Shell or another trusted machine authenticated as a project administrator:

1. Ensure `terraform.tfvars` contains the target `project_id` and `github_repo` (copy `terraform.tfvars.example` and edit it if needed).
2. Run `terraform init -backend=false`, then `terraform plan` and review the IAM changes, then `terraform apply`.
3. After the bucket is created, migrate the local bootstrap state into it: `terraform init -migrate-state -backend-config="bucket=PROJECT_ID-tfstate" -backend-config="prefix=profile-app/bootstrap"`. Replace `PROJECT_ID` with the actual project ID.
4. Configure the GitHub repository variables from the Terraform `github_variables` output, including `GCP_PROJECT_ID`, `GCP_WIF_PROVIDER_TF_PLAN`, `GCP_TF_PLAN_SA`, `GCP_WIF_PROVIDER_TF_APPLY`, `GCP_TF_APPLY_SA`, and `TF_STATE_BUCKET`.
5. Enable required reviewers on the GitHub `infra` environment before enabling applies.

The manually dispatched workflow is for later review and maintenance of the bootstrap. It only runs from `main` and uses WIF, so it cannot perform the initial bootstrap.

## State and credentials

Bootstrap state is stored in GCS under prefix `profile-app/bootstrap`. The GitHub Actions workflows use short-lived GitHub OIDC tokens; do not create or store service-account key files.
