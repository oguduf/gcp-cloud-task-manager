locals {
  state_bucket = var.state_bucket != "" ? var.state_bucket : "${var.project_id}-tfstate"
  repo         = var.github_repo
  main_ref     = "refs/heads/${var.main_branch}"

  # One OIDC provider per job type. Each provider only accepts the GitHub tokens
  # meant for it, and stamps them with attribute.purpose, so a token accepted
  # for one job can never impersonate another job's service account.
  providers = {
    deploy = {
      id        = "github-deploy"
      condition = "assertion.repository == '${local.repo}' && assertion.ref == '${local.main_ref}'"
    }
    tf-plan = {
      id        = "github-tf-plan"
      condition = "assertion.repository == '${local.repo}' && (assertion.event_name == 'pull_request' || assertion.ref == '${local.main_ref}')"
    }
    tf-apply = {
      id        = "github-tf-apply"
      condition = "assertion.repository == '${local.repo}' && assertion.ref == '${local.main_ref}' && assertion.environment == '${var.apply_environment}'"
    }
  }

  # Plan can read state and manage only the dedicated lock objects below. PR code
  # remains unable to change infrastructure resources.
  tf_plan_roles = [
    "roles/viewer",
    "roles/iam.securityReviewer", # read IAM policies on project, SAs, VM, repo
  ]

  # Everything infra/terraform creates. This identity can grant IAM roles, so it
  # is only reachable from main, inside the approval-gated environment.
  tf_apply_roles = [
    "roles/serviceusage.serviceUsageAdmin",
    "roles/compute.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/artifactregistry.admin",
    "roles/datastore.owner",
    "roles/iap.admin",
  ]
}

# ---------------------------------------------------------------------------
# APIs needed before anything else can run
# ---------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "storage.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Terraform state bucket
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "tfstate" {
  name                        = local.state_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true # every state write is kept; roll back by restoring a version
  }

  lifecycle_rule {
    condition {
      with_state         = "ARCHIVED"
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Workload Identity Federation (GitHub OIDC)
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = var.wif_pool_id
  display_name              = "GitHub Actions"
  description               = "OIDC trust for ${var.github_repo}"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  for_each = local.providers

  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = each.value.id
  display_name                       = "GitHub ${each.key}"
  attribute_condition                = each.value.condition

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.purpose"    = "'${each.key}'"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  principal_set = {
    for k, _ in local.providers :
    k => "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.purpose/${k}"
  }
}

# ---------------------------------------------------------------------------
# Terraform service accounts
# ---------------------------------------------------------------------------
resource "google_service_account" "tf_plan" {
  account_id   = "tf-plan"
  display_name = "Terraform plan (GitHub Actions, read-only)"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "tf_apply" {
  account_id   = "tf-apply"
  display_name = "Terraform apply (GitHub Actions, approval-gated)"

  depends_on = [google_project_service.apis]
}

resource "google_service_account_iam_member" "tf_plan_wif" {
  service_account_id = google_service_account.tf_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.principal_set["tf-plan"]
}

resource "google_service_account_iam_member" "tf_apply_wif" {
  service_account_id = google_service_account.tf_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.principal_set["tf-apply"]
}

resource "google_project_iam_member" "tf_plan" {
  for_each = toset(local.tf_plan_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.tf_plan.member
}

resource "google_project_iam_member" "tf_apply" {
  for_each = toset(local.tf_apply_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.tf_apply.member
}

# GitHub's app deploy identity needs only these release operations. The custom
# role is owned by bootstrap so the approval-gated Terraform apply identity does
# not need persistent IAM role-administration permissions.
resource "google_project_iam_custom_role" "deployer_mig" {
  role_id     = "profileAppMigDeployer"
  title       = "Employee Dashboard MIG Deployer"
  description = "Create release templates and roll the employee dashboard regional MIG."
  permissions = [
    "compute.globalAddresses.get",
    "compute.globalOperations.get",
    "compute.globalOperations.list",
    "compute.instanceTemplates.create",
    "compute.instanceTemplates.get",
    "compute.instanceTemplates.list",
    "compute.instanceTemplates.useReadOnly",
    "compute.instances.get",
    "compute.instances.list",
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.list",
    "compute.instanceGroupManagers.update",
    "compute.regionOperations.get",
    "compute.regionOperations.list",
  ]
}

# Plan reads existing state and can create an initial state object only for the
# two Terraform prefixes below; apply can read and update state.
resource "google_storage_bucket_iam_member" "tf_plan_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.tf_plan.member
}

# A fresh GCS backend has no state object yet. Let plan create those two initial
# state objects, without granting it permission to overwrite or delete state.
resource "google_storage_bucket_iam_member" "tf_plan_state_initial" {
  for_each = toset([
    "profile-app/bootstrap/default.tfstate",
    "profile-app/main/default.tfstate",
  ])

  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.tf_plan.member

  condition {
    title       = "terraform-plan-state-create-${replace(each.value, "/", "-")}"
    description = "Allow the plan identity to create only this initial Terraform state object."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name == 'projects/_/buckets/${local.state_bucket}/objects/${each.value}'"
  }
}

# GCS state locking needs object access. Restrict plan to the two lock files
# used by the workflow state prefixes.
resource "google_storage_bucket_iam_member" "tf_plan_state_lock" {
  for_each = toset([
    "profile-app/bootstrap/default.tflock",
    "profile-app/main/default.tflock",
  ])

  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectUser"
  member = google_service_account.tf_plan.member

  condition {
    title       = "terraform-plan-lock-${replace(each.value, "/", "-")}"
    description = "Allow the plan identity to manage only this Terraform state lock object."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name == 'projects/_/buckets/${local.state_bucket}/objects/${each.value}'"
  }
}
resource "google_storage_bucket_iam_member" "tf_apply_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.tf_apply.member
}

