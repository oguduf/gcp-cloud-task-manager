# Firestore Enterprise edition with the MongoDB-compatible API.
resource "google_firestore_database" "db" {
  name        = var.firestore_database_id
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  database_edition                    = "ENTERPRISE"
  mongodb_compatible_data_access_mode = "DATA_ACCESS_MODE_ENABLED"

  delete_protection_state = var.protect_database ? "DELETE_PROTECTION_ENABLED" : "DELETE_PROTECTION_DISABLED"
  deletion_policy         = var.protect_database ? "ABANDON" : "DELETE"

  depends_on = [google_project_service.apis]
}

locals {
  # No username or password: the driver fetches an ID token for the VM's service
  # account from the metadata server (audience FIRESTORE).
  mongo_url = join("", [
    "mongodb://${google_firestore_database.db.uid}.${google_firestore_database.db.location_id}.firestore.goog:443/",
    google_firestore_database.db.name,
    "?loadBalanced=true&tls=true&retryWrites=false",
    "&authMechanism=MONGODB-OIDC",
    "&authMechanismProperties=ENVIRONMENT:gcp,TOKEN_RESOURCE:FIRESTORE",
  ])
}
