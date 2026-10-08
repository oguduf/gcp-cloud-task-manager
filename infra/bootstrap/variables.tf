variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository allowed to use these identities, as owner/repo."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/repo."
  }
}

variable "region" {
  description = "Region for the state bucket (and the app, passed on to GitHub variables)."
  type        = string
  default     = "us-east1"
}

variable "zone" {
  description = "Zone for the app VM (passed on to GitHub variables)."
  type        = string
  default     = "us-east1-b"
}

variable "app_name" {
  description = "Must match `name` in infra/terraform (used to derive the deploy variables)."
  type        = string
  default     = "profile-app"
}

variable "main_branch" {
  description = "The only branch that can deploy or apply Terraform."
  type        = string
  default     = "main"
}

variable "apply_environment" {
  description = "GitHub environment that gates terraform apply (create it with a required reviewer)."
  type        = string
  default     = "infra"
}

variable "state_bucket" {
  description = "Terraform state bucket name. Empty = <project_id>-tfstate."
  type        = string
  default     = ""
}

variable "wif_pool_id" {
  description = "Workload Identity Pool ID. Deleted pool IDs stay reserved for 30 days."
  type        = string
  default     = "github"
}
