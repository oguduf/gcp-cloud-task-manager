# Migration plan: standalone VM to regional MIG

## State and resource safety

The Terraform root uses the existing GCS backend with prefix `profile-app/main`. Keep both unchanged. The checkout has ignored local variable files and `.terraform` directories; no Terraform state file is tracked. A local listing does not confirm remote state contents, so inspect the live state with the configured backend before approving an infrastructure plan.

## Staged cutover

1. Review the current state and plan. Verify the existing Firestore database, GCS state bucket, load-balancer IP, VM, and instance group are still managed as expected.
2. Create the template, regional MIG, autoscaler, monitoring resources, and attach the MIG as a second backend. Keep the existing VM and its backend. This preserves the working route while the new group boots.
3. Build SHA-tagged frontend and backend images, create a release template, and roll the MIG. Verify at least two healthy MIG backends, `/healthz`, `/api/health`, and the dashboard through the public load balancer.
4. Observe logs, dashboard, and alerts. If the release fails, direct the MIG to the previous template or rerun the prior successful deployment. The legacy VM remains available during this period.
5. In a later reviewed Terraform change, remove the old VM backend, instance group, and standalone VM only after the new path is stable. Confirm the plan removes only intended resources and preserves the global IP, load balancer, database, and remote state.

## Rollback

The first migration does not need to remove the old VM. If the MIG is unhealthy, remove the MIG backend from the backend service through a reviewed Terraform change or temporarily route traffic to the legacy backend, then diagnose startup, Artifact Registry access, Firestore IAM, and health-check logs. Keep the old VM and its deployment artifacts until rollback is no longer needed.

Do not use `terraform destroy` as a migration or rollback mechanism.
