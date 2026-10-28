# Security controls

- GitHub Actions authenticates with Workload Identity Federation. No long-lived service-account JSON keys are used.
- The deploy identity can write to the application Artifact Registry repository and receives a bootstrap-managed custom Compute Engine role for template creation, MIG rollout, and health reads. Review that permission list when release operations change.
- The VM runtime uses a dedicated service account with Firestore data access, Artifact Registry image read, log write, and metric write permissions. It uses Application Default Credentials from the Compute Engine metadata server.
- MIG VMs have no external IPs. The subnet enables Private Google Access. Cloud NAT handles outbound public package repositories only. Firestore remains Google-managed outside the VPC.
- Ingress to app port 80 is limited to Google load-balancer and health-check source ranges. SSH is not open to the internet; IAP TCP forwarding is the administration path. Grant human OS Login and IAP roles only to authorized operators.
- Shielded VM features and OS Login are enabled. Use immutable SHA image references. Do not put secrets in metadata, Terraform variables committed to Git, images, or logs.
- Firestore database deletion protection remains an explicit variable. Before applying, inspect the plan to ensure it does not recreate or destroy the existing database.

For production, use a domain and HTTPS, verify the exact Firestore IAM condition against live access patterns, consider restricted Firestore API endpoints and VPC Service Controls for stronger egress controls, establish secret handling for any future credentials, and configure log retention and data recovery objectives.
