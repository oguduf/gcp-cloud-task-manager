# Architecture

## Request and data flow

1. A user opens the public global external Application Load Balancer. Without a domain the endpoint is HTTP-only for development; with a domain and managed certificate, HTTP redirects to HTTPS.
2. The load balancer checks `/healthz` and sends requests to the old VM and regional MIG during migration. The old VM backend is removed only after the MIG has a verified release.
3. Each regional MIG VM runs an nginx frontend container and a Node API container on a private Docker network. At least two VM instances span configured zones and have private addresses only. Firewall ingress permits TCP 80 from Google load-balancer proxy and health-check ranges, and TCP 22 from the IAP range for approved administration.
4. The app authenticates to Firestore with Application Default Credentials from its dedicated VM service account. Firestore is a Google-managed regional service outside the VPC; Private Google Access provides the private VM's API path.
5. Cloud NAT permits outbound package downloads. The VM service account pulls the immutable frontend and backend images from Artifact Registry and writes logs/metrics.
6. Docker sends container logs to Cloud Logging. Cloud Monitoring provides a separate dashboard, uptime check, and alert policies.

## Components

| Tier | Components | Responsibility |
|---|---|---|
| Edge | Global external Application Load Balancer, global IP, optional managed certificate | Public entry point, TLS termination, health-based backend selection |
| Application | Regional MIG, instance template, nginx frontend container, Node API container | Stateless app processes, autohealing, autoscaling, rolling replacement |
| Data | Firestore Native database with MongoDB-compatible data access | Persistent employee data; managed outside the VPC |
| Delivery | GitHub Actions, OIDC/WIF, Artifact Registry | Build SHA-tagged images and roll out versioned templates |
| Operations | Docker Cloud Logging driver, Cloud Logging, Cloud Monitoring | Container logs, infrastructure metrics, dashboard, uptime and alerts |
| Network | Custom VPC/subnet, Private Google Access, Cloud NAT, firewall | Private VM connectivity and controlled ingress/egress |

See [architecture-diagram.svg](architecture-diagram.svg).

## Availability boundaries

The regional MIG minimum is two instances distributed across at least two zones. The autoscaler changes instance count based on average CPU; the MIG repairs instances failing the application health check. The managed database is regional. This is a training project, not a complete production SLO design: use load testing to tune machine size, autoscaling, and alert thresholds; configure Firestore backups/retention for recovery objectives; and assess multi-region needs separately.
