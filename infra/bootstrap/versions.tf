# One-time foundation for the CI/CD pipelines. Run this ONCE by hand, as a
# project Owner. Everything else (infra/terraform) is then applied by GitHub Actions.
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }

  # Optional, after the first apply: keep this state in the bucket it created.
  # Uncomment, set the bucket name, then `terraform init -migrate-state`.
  # backend "gcs" {
  #   bucket = "<project>-tfstate"
  #   prefix = "profile-app/bootstrap"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    app        = "profile-app"
    managed-by = "terraform-bootstrap"
  }
}
