terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }

  # State lives in the bucket created by infra/bootstrap. The bucket name is
  # passed at init time (it differs per project):
  #   terraform init -backend-config="bucket=<project>-tfstate"
  # GitHub Actions does this with the TF_STATE_BUCKET variable.
  backend "gcs" {
    prefix = "profile-app/main"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  default_labels = {
    app        = "profile-app"
    managed-by = "terraform"
  }
}
