# One-time foundation for GitHub Actions Workload Identity Federation.
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }

  # The bucket is created by this root. First apply from Cloud Shell with
  # `terraform init -backend=false`; then migrate state to the new GCS bucket.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    app        = "profile-app"
    managed-by = "terraform-bootstrap"
  }
}
