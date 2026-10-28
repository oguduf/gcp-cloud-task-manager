# Monitoring and logging

The Cloud Monitoring dashboard is provisioned by Terraform. It includes load-balancer request rate, 5xx response rate, p95 backend latency, per-instance CPU, public uptime, autoscaler recommended size, and a logs-based application error count.

The private MIG startup script configures Docker's `gcplogs` driver for the frontend and backend containers, sending their stdout/stderr to Cloud Logging with VM/container metadata. Compute Engine and load-balancer metrics are collected by Google Cloud.

Alert policies cover HTTP 5xx volume, high CPU, load-balancer backend errors, application error logs, and public endpoint uptime. Thresholds are Terraform variables. Notification channels are intentionally not invented: create or select a channel in Cloud Monitoring, then pass its full existing resource name with `alert_notification_channels`.

Newly created dashboards and alerts can take time to show data. External Application Load Balancer metrics are sampled in one-minute batches, and Cloud Logging metrics begin receiving data only after matching logs arrive. Validate filters in Metrics Explorer and Logs Explorer after deployment. The public uptime check tests `/healthz`; it does not prove Firestore is healthy. The deployment smoke test separately calls `/api/health` to check the data path.

Troubleshooting:

- No app logs: inspect the container state and logs on the VM with `docker ps -a` and `docker logs employee-backend` / `docker logs employee-frontend`, then verify the VM service account's `roles/logging.logWriter` grant.
- No app error metric: inspect backend entries in Logs Explorer and confirm the severity/JSON fields match the logs-based metric filter.
- No load-balancer metrics: send traffic first, then wait for metric sampling; verify the backend service logging is enabled.
- No public uptime: verify DNS (for HTTPS), certificate status, forwarding rule, firewall source ranges, MIG health, and `/healthz`.
- Alert delivery missing: verify a notification channel is configured on the alert policy and test the channel from the console.
