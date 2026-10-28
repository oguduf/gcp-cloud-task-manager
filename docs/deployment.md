# Deployment

## One-time bootstrap and GitHub configuration

1. Keep the existing GCS backend and its state. Do not edit the `backend "gcs"` prefix or bucket as part of this migration.
2. Update and review the bootstrap Terraform plan. Its changes add a project custom role for the app release identity and publish new repository variables: `GCP_MIG_NAME`, `GCP_TEMPLATE_PREFIX`, `GCP_LB_IP_NAME`, `GCP_BACKEND_SERVICE`, and optional `GCP_DOMAIN_NAME`. The human identity running bootstrap must be allowed to create project custom roles. Apply bootstrap only after reviewing its plan; this project configuration never stores a service-account key.
3. Refresh the repository Actions variables from `terraform output github_variables`. Set `GCP_DOMAIN_NAME` only if you own the domain and intend to configure managed TLS. Create an `infra` environment with a required reviewer.
4. Optional GitHub Actions variables for Terraform input are `GCP_MACHINE_TYPE`, `GCP_ZONES` (JSON list), `GCP_MIG_MIN_REPLICAS`, `GCP_MIG_MAX_REPLICAS`, `GCP_AUTOSCALING_CPU_TARGET`, `GCP_ALERT_5XX_THRESHOLD`, `GCP_ALERT_CPU_THRESHOLD`, `GCP_ALERT_BACKEND_ERROR_RATE`, and `GCP_ALERT_NOTIFICATION_CHANNELS` (JSON list of existing channel resource names). Defaults are suitable for a small lab. Connect a Monitoring notification channel by its existing resource name if notifications are required.

## Infrastructure migration

1. Inspect the current remote state and run a plan against the existing backend. Confirm the Firestore database is retained, the GCS backend is unchanged, the old standalone VM remains, and the old instance group remains a backend during cutover.
2. Review every replacement/deletion in the plan. The first migration adds the instance template, regional MIG, autoscaler, monitoring resources, and a second backend. It must not delete the old VM or Firestore database.
3. Merge the reviewed infrastructure change. The Terraform GitHub workflow plans and pauses for approval in `infra`; approve only the exact reviewed plan.
4. If Artifact Registry has no `bootstrap` frontend and backend images, new MIG instances will fail their initial image pulls and remain unhealthy until the deploy workflow publishes real images. This is expected during first-time cutover: the retained legacy VM remains a backend. Immediately after the MIG is created, run **Build & deploy to GCE** manually from `main`. It builds and pushes SHA-tagged frontend and backend images, clones the Terraform baseline template with both immutable image references, starts a proactive rolling update, waits for stability, verifies at least two healthy MIG instances, then tests `/healthz`, `/api/health` (Firestore), and the dashboard through the public load balancer.
5. Confirm the dashboard and uptime check show data. After a successful observation period, open a separate Terraform change to remove the legacy standalone VM and its instance-group backend. Review that plan carefully before applying.
6. Enable `AUTO_DEPLOY=true` only after the first manual application deployment succeeds.

## Release and rollback

Each release uses the Git commit SHA for the container image and a SHA-suffixed instance-template name. The deploy workflow is the only owner of release template versions and MIG rollout; Terraform owns the baseline template and MIG shape and ignores the live MIG template version and autoscaled size to avoid resetting releases/scaling. When infrastructure changes require a new baseline template, run the app deployment workflow after the infrastructure apply so the MIG receives that baseline configuration.

For rollback, rerun the previous successful deployment workflow or start a MIG rolling update to a retained prior SHA template. Confirm backend health and exercise the public health and data endpoints. Keep old templates until the rollback window closes; do not delete them as part of the deploy job.

## Local validation

From `infra/terraform`, run `terraform fmt -recursive -check`, `terraform init -backend=false`, and `terraform validate`. From `app`, run `npm ci` and `npm test`. These checks do not deploy resources. Live health, IAM, managed certificate issuance, monitoring metric availability, and Firestore calls require deployment in GCP.
