variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "region" {
  description = "Region for the subnet, static IP, Artifact Registry and Firestore."
  type        = string
  default     = "us-east1"
}

variable "zone" {
  description = "Primary zone used for the legacy VM; the MIG uses zones."
  type        = string
  default     = "us-east1-b"
}

variable "zones" {
  description = "At least two zones in region for the regional MIG."
  type        = list(string)
  default     = ["us-east1-b", "us-east1-c", "us-east1-d"]
  validation {
    condition     = length(var.zones) >= 2
    error_message = "Provide at least two zones for a regional MIG."
  }
}

variable "name" {
  description = "Base name used for most resources."
  type        = string
  default     = "profile-app"
}

variable "machine_type" {
  description = "VM machine type."
  type        = string
  default     = "e2-small"
}

variable "mig_min_replicas" {
  description = "Minimum regional MIG instance count."
  type        = number
  default     = 2
  validation {
    condition     = var.mig_min_replicas >= 2
    error_message = "The regional MIG must have at least two instances."
  }
}

variable "mig_max_replicas" {
  description = "Maximum regional MIG instance count."
  type        = number
  default     = 4
  validation {
    condition     = var.mig_max_replicas >= 2
    error_message = "mig_max_replicas must be at least two."
  }
}

variable "autoscaling_cpu_target" {
  description = "Target average CPU utilization for MIG autoscaling."
  type        = number
  default     = 0.65
  validation {
    condition     = var.autoscaling_cpu_target > 0 && var.autoscaling_cpu_target <= 1
    error_message = "autoscaling_cpu_target must be greater than 0 and at most 1."
  }
}

variable "initial_image_tag" {
  description = "Bootstrap tag for the initial frontend and backend image references; the app workflow replaces both with commit SHA images."
  type        = string
  default     = "bootstrap"
}

variable "domain_name" {
  description = "Optional DNS name for managed HTTPS. Leave empty for documented HTTP-only development mode."
  type        = string
  default     = ""
}

variable "alert_5xx_threshold" {
  description = "Alert when 5xx responses exceed this count during the alignment window."
  type        = number
  default     = 5
}

variable "alert_cpu_threshold" {
  description = "Average CPU utilization alert threshold, from 0 to 1."
  type        = number
  default     = 0.85
}

variable "alert_backend_error_rate" {
  description = "Alert threshold for the backend error-rate metric."
  type        = number
  default     = 0.05
}

variable "alert_notification_channels" {
  description = "Existing Cloud Monitoring notification channel resource names. Configure in Console and pass IDs here; do not invent an email address."
  type        = list(string)
  default     = []
}

variable "subnet_cidr" {
  description = "Primary range of the private VM subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "vm_internal_ip" {
  description = "Fixed internal IP of the VM (must be inside subnet_cidr)."
  type        = string
  default     = "10.10.0.10"
}

variable "firestore_database_id" {
  description = "Firestore database ID. The app uses it as the MongoDB database name (MONGO_DB_NAME)."
  type        = string
  default     = "user-account"
}

variable "protect_database" {
  description = "true = enable Firestore delete protection and keep the database on terraform destroy."
  type        = bool
  default     = false
}

variable "wif_pool_name" {
  description = "Full name of the Workload Identity Pool created by infra/bootstrap (GitHub variable GCP_WIF_POOL), e.g. projects/123/locations/global/workloadIdentityPools/github."
  type        = string

  validation {
    condition     = can(regex("^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+$", var.wif_pool_name))
    error_message = "wif_pool_name must be the full pool name: projects/<number>/locations/global/workloadIdentityPools/<id>."
  }
}
