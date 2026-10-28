# Employee Admin Dashboard on a Regional MIG (GitHub Actions + OIDC)

A three-tier app served by a private regional managed instance group (MIG):
an **nginx frontend** (static dashboard + reverse proxy), a **Node/Express backend API**,
and **Firestore with MongoDB compatibility** as the database. A global external
Application Load Balancer routes public traffic to the MIG. The existing standalone
VM stays attached as a temporary backend during migration.

> **Security note: the dashboard has no authentication yet.** Anyone who can reach the load
> balancer IP can read and change employees. Identity-Aware Proxy on the load balancer is a
> planned follow-up. Do not put real employee data in it until then.

```mermaid
flowchart LR
  browser((Browser)) -- "HTTP :80" --> lb[External HTTP load balancer]
  subgraph VPC[Private subnet · regional MIG · min 2 zones]
    subgraph VM1[Private MIG instance 1]
      fe1["frontend (nginx)<br/>port 80"] -- "/api/* and /healthz<br/>http://backend:3000" --> be1["backend (Node/Express)"]
    end
    subgraph VM2[Private MIG instance 2+]
      fe2["frontend (nginx)<br/>port 80"] -- "/api/* and /healthz<br/>http://backend:3000" --> be2["backend (Node/Express)"]
    end
  end
  lb --> VM1
  lb --> VM2
  be1 -- "MONGODB-OIDC, TLS 443" --> fs[(Firestore<br/>employees collection)]
  be2 -- "MONGODB-OIDC, TLS 443" --> fs
```

Keyless end to end:
- GitHub Actions authenticates to Google Cloud with **Workload Identity Federation (OIDC)**.
  No service-account JSON key or SSH key is stored in GitHub.
- The app authenticates to Firestore with **MONGODB-OIDC** as the VM's service account.
  There is no database username or password anywhere.

```mermaid
flowchart LR
  subgraph GH[GitHub]
    repo[Repository<br/>push to main] --> runner[Actions runner<br/>id-token: write]
  end
  subgraph GCP[Google Cloud project]
    wif[Workload Identity Federation<br/>repo == yours && ref == main]
    sa[gh-deployer SA]
    ar[(Artifact Registry)]
    lb[External Application Load Balancer<br/>public HTTP IP]
    nat[Cloud NAT<br/>outbound only]
    fs[(Firestore<br/>MongoDB compat<br/>db: user-account)]
    subgraph MIG[Private regional MIG · min 2 instances]
      app[nginx frontend :80 -> Node backend :3000] -- ID token aud=FIRESTORE --> md[metadata server]
    end
  end
  users((Users)) -- HTTP :80 --> lb --> MIG
  runner -- "1 OIDC JWT" --> wif
  wif -- "2 impersonate" --> sa
  sa -- "3 short-lived token" --> runner
  runner -- "4 docker push" --> ar
  runner -- "5 clone release template and roll MIG" --> MIG
  MIG -- "pull images via NAT" --> nat --> ar
  app -- "8 MONGODB-OIDC, TLS 443" --> fs
```

## Layout

| Path | What it is |
|---|---|
| `backend/` | Express API (`src/`), tests (`test/`), seed script (`scripts/seed.js`), Dockerfile |
| `frontend/` | Static dashboard (`public/`, vanilla ES modules, no build step), `nginx.conf`, Dockerfile |
| `.github/workflows/deploy-gce.yml` | App: test → build two immutable images → push to Artifact Registry → roll the regional MIG → smoke test |
| `.github/workflows/ci.yml` | Backend tests on pull requests (no GCP auth) |
| `.github/workflows/terraform.yml` | Infra: plan on PRs (posted as a comment) → approve → apply on `main` |
| `infra/bootstrap/` | Run once by hand: state bucket, GitHub OIDC trust, `tf-plan` / `tf-apply` service accounts |
| `infra/terraform/` | App infrastructure: private subnet, regional MIG and temporary legacy VM backend, external load balancer, Cloud NAT, Firestore, Artifact Registry, IAM, monitoring |
| `infra/vm-startup.sh` | Startup helper retained for the legacy VM during cutover |
| `infra/mig-startup.sh` | Starts the nginx and Node containers on each private MIG instance and sends container logs to Cloud Logging |
| `deploy/docker-compose.yml`, `deploy/deploy.sh` | Legacy VM deployment files retained for migration rollback; the release workflow updates the MIG |
| `docker-compose.yaml` | Local development only: MongoDB + backend + frontend on http://localhost:8080 |

## CI/CD

```mermaid
flowchart LR
  pr[Pull request<br/>infra/terraform/**] --> plan1[terraform plan<br/>tf-plan, read-only] --> comment[Plan posted<br/>as PR comment]
  merge[Merge to main] --> plan2[terraform plan<br/>tf-plan] --> gate{{Approve in<br/>environment 'infra'}} --> apply[terraform apply<br/>saved plan, tf-apply]
  prb[Pull request<br/>backend/**] --> ci[ci.yml<br/>backend tests]
  push[Push to main<br/>backend/** frontend/** deploy/**] --> test[backend tests] --> deploy[build images<br/>roll regional MIG]
```

Each job logs in with its own Workload Identity provider and service account:

| Job | Provider accepts tokens from | Service account | Can |
|---|---|---|---|
| Terraform plan | PRs in this repo, or `main` | `tf-plan` | read the project and the state (plan runs with `-lock=false`) |
| Terraform apply | `main` **and** environment `infra` | `tf-apply` | create/change everything in `infra/terraform` |
| App deploy | `main` | `gh-deployer` | push images and roll the regional MIG |

Each provider stamps its tokens with `attribute.purpose`, and each service account trusts
only its own purpose, so a pull-request token can never be used to apply or deploy.

## Setup (once)

1. **Push this folder to a GitHub repo.**
2. **Bootstrap** (Cloud Shell or your machine, with permission to create the
   resources and IAM grants in `infra/bootstrap`):
   ```bash
   cd infra/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # set project_id and github_repo
   # On a local machine only: gcloud auth application-default login
   terraform init
   terraform plan
   terraform apply                                  # only after reviewing the plan
   ```
   On Windows PowerShell, use `Copy-Item .\terraform.tfvars.example .\terraform.tfvars`
   instead of `cp`. `terraform.tfvars` is ignored by Git. `terraform init`
   installs providers; **only `terraform apply` creates the Workload Identity
   Pool/providers, service accounts, state bucket, and IAM bindings**. Keep the
   bootstrap state safe so future changes do not attempt to recreate them.
   The bootstrap uses its own `github-task-manager` Workload Identity Pool.
   Do not point this repo at an existing pool owned by another repository.
3. **Configure GitHub**: run `terraform output github_variables` in
   `infra/bootstrap` and add each entry under repository **Settings → Secrets
   and variables → Actions → Variables**. The output contains the actual
   project number and resource names; do not use placeholder values. If you
   use the GitHub CLI and want the additional branch/environment policy changes,
   review this generated script before running it:
   ```bash
   terraform output -raw gh_setup_commands
   ```
   Before merging to `main`, create the `infra` GitHub environment with a
   required reviewer. The Terraform apply job must not run without this gate.
   The optional script sets repository variables (none are secrets), protects
   `main` so changes go through pull requests, and configures that environment.
   Cloud Build's GitHub repository connection is
   separate and does not create this GitHub Actions OIDC trust.
   Required reviewers and branch protection on a **private** repo need a paid GitHub plan
   (Pro/Team); they are free on public repos.
4. **Merge `dev` into `main`.** GitHub only offers these manual workflows after
   their files exist on the default branch. The Terraform workflow runs on the
   merge; read its plan in the run summary, then approve the `apply` job.
5. **First app deploy:** after Terraform succeeds, manually run **Build & deploy
   to GCE** from `main`. The automatic deploy job stays skipped until you set
   the repository Actions variable `AUTO_DEPLOY` to `true`. Set it only after
   the first manual deployment succeeds; later pushes to `main` then deploy.

Optional but recommended: commit `infra/terraform/.terraform.lock.hcl` (create it with
`terraform init -backend=false` in that folder) so CI always uses the same provider versions.

### Changing infrastructure

Open a pull request that changes `infra/terraform/`. The plan appears as a comment on the PR.
Merge it, then approve the `apply` job in the run. Apply uses the exact plan you approved;
if the state changed in between, Terraform refuses and nothing is changed.

### Tearing down

The pipeline never destroys. From your machine:
```bash
cd infra/terraform && terraform init -backend-config="bucket=<project>-tfstate"
terraform destroy -var project_id=<project> -var wif_pool_name=<GCP_WIF_POOL value>
cd ../bootstrap && terraform destroy   # remove prevent_destroy on the bucket first
```
A deleted Workload Identity Pool ID stays reserved for 30 days.

## Networking

GCP's external Application Load Balancer has a public global IP; it is **not
inside a public subnet**. The `profile-app-subnet` is private and hosts the
regional MIG instances. During cutover, the existing standalone VM remains a
second backend. Firestore is a managed service outside the VPC, reached from the
private subnet through Private Google Access.

```mermaid
flowchart LR
  browser[Browser] -- HTTP :80 --> lb[External Application Load Balancer]
  lb --> mig[Regional MIG · private VMs across zones]
  mig --> legacy[Legacy VM · temporary backend]
  mig -- "TLS :443 / Private Google Access" --> fs[(Firestore)]
  mig -- outbound only --> nat[Cloud NAT] --> internet[Docker and package downloads]
  github[GitHub Actions] -- OIDC + rolling update --> mig
```

| Resource | Name | Settings |
|---|---|---|
| VPC | `profile-app-vpc` | custom subnet mode (no default-network open rules) |
| Subnet | `profile-app-subnet` | private VM subnet `10.10.0.0/24`, `us-east1`, Private Google Access on |
| Load balancer | `profile-app-http` | public global HTTP `:80` → regional MIG and temporary legacy instance groups; `/healthz` check |
| Firewall | `profile-app-allow-http` | ingress `tcp:80` only from Google load-balancer and health-check ranges → VM service account |
| Firewall | `profile-app-allow-iap-ssh` | ingress `tcp:22` from `35.235.240.0/20` (IAP) → VM service account for administration |
| Firewall | implied | deny all other ingress, allow all egress |
| Address | `profile-app-lb-ip` | global static external IP on the load balancer; VM internal IP `10.10.0.10`, no external IP |
| Cloud NAT | `profile-app-nat` | outbound internet access for the private VM, not inbound access |

On each MIG instance, Docker publishes host `:80 → frontend:80`; the backend
(`:3000`) is reachable only from nginx over the private Docker network. The
database is a managed service reached outbound on TLS 443, so it needs no inbound
firewall rule. The old VM remains attached until at least two MIG instances pass
health and application/database smoke tests. Review the Terraform plan before
applying; the existing VM and Firestore database must not be replaced or deleted.

## Database: Firestore with MongoDB compatibility

- Enterprise-edition Firestore database `user-account` in `us-east1`, created by Terraform (`infra/terraform/firestore.tf`).
- The backend still uses the official `mongodb` Node.js driver (6.x). Only the connection string changed:
  ```
  mongodb://<uid>.<location>.firestore.goog:443/user-account?loadBalanced=true&tls=true&retryWrites=false
    &authMechanism=MONGODB-OIDC&authMechanismProperties=ENVIRONMENT:gcp,TOKEN_RESOURCE:FIRESTORE
  ```
- The connection string holds no secret. It is stored as the instance-template metadata key `mongo-url` and passed to the backend container at startup.
- The VM service account has `roles/datastore.user`, limited by an IAM condition to this one database.
- Employees live in the `employees` collection (string UUID `_id`, only whitelisted fields stored).
  Queries are exact-match filters only, with sorting done in the backend, to stay within what
  Firestore's MongoDB compatibility supports.
- Without `MONGO_URL` set, the backend falls back to `mongodb://admin:password@localhost:27017`.

## API

All routes are served through the frontend's nginx (`/api/*` and `/healthz` are proxied to the backend).
Every response carries an `X-Served-By` header, and the backend logs one JSON line per request.

| Method | Path | Description |
|---|---|---|
| GET | `/healthz` | Liveness for the load balancer: `200 ok`, no database call |
| GET | `/api/health` | Pings Firestore: `200 {status, database, instance}`, or `503` if unreachable |
| GET | `/api/meta` | Departments, statuses, instance name |
| GET | `/api/employees?department=&status=` | List (exact-match filters, max 1000, sorted by last then first name) |
| GET | `/api/employees/:id` | One employee, `404` if missing |
| POST | `/api/employees` | Create (`201`); `400 {error, fields}` on validation errors, `409` on duplicate email |
| PUT | `/api/employees/:id` | Partial update; same errors as create, plus `404` |
| DELETE | `/api/employees/:id` | Delete (`204`), `404` if missing |

Employee fields: `firstName`, `lastName` (1–60 chars), `email` (valid, lowercased, unique),
`department` (Engineering, Sales, Marketing, Finance, HR, Operations, Support), `role` (1–80),
`hireDate` (`YYYY-MM-DD`), `status` (`active` | `on_leave` | `inactive`, default `active`),
plus `id`, `createdAt`, `updatedAt` set by the server.

## Local development

Requires Docker Desktop.

```bash
docker compose up --build
docker compose exec backend npm run seed     # idempotent: adds ~10 sample employees
```

Open http://localhost:8080. MongoDB runs locally with `admin` / `password`.
Backend tests (Node 22): `cd backend && npm ci && npm test`.

## Operating

- Browse the data in the console under **Firestore → user-account → Firestore Studio**, or with
  `mongosh` using the same connection string from a machine with `roles/datastore.user`.
- Roll back: rerun a previous successful deployment workflow so the MIG rolls to its SHA-pinned images. Keep the associated Artifact Registry images available throughout the rollback window.
