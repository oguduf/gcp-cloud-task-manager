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
  description = "Zone for the VM."
  type        = string
  default     = "us-east1-b"
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

variable "subnet_cidr" {
  description = "Primary range of the VM subnet."
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
