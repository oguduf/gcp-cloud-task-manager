# Profile app on a GCE VM (GitHub Actions + OIDC)

Node.js app on a single Compute Engine VM (Docker Compose), with
**Firestore with MongoDB compatibility** as the database.

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
    iap[Identity-Aware Proxy<br/>:22 only]
    fs[(Firestore<br/>MongoDB compat<br/>db: user-account)]
    subgraph VM[Compute Engine VM - SA profile-app-vm]
      app[my-app :80] -- ID token aud=FIRESTORE --> md[metadata server]
    end
  end
  users((Users)) -- HTTP :80 --> app
  runner -- "1 OIDC JWT" --> wif
  wif -- "2 impersonate" --> sa
  sa -- "3 short-lived token" --> runner
  runner -- "4 docker push" --> ar
  runner -- "5 ssh/scp via IAP" --> iap
  iap -- "6 sudo deploy.sh" --> VM
  VM -- "7 pull image" --> ar
  app -- "8 MONGODB-OIDC, TLS 443" --> fs
```

## Layout

| Path | What it is |
|---|---|
| `.github/workflows/deploy-gce.yml` | App: build → push to Artifact Registry → deploy over IAP SSH → smoke test |
| `.github/workflows/terraform.yml` | Infra: plan on PRs (posted as a comment) → approve → apply on `main` |
| `infra/bootstrap/` | Run once by hand: state bucket, GitHub OIDC trust, `tf-plan` / `tf-apply` service accounts |
| `infra/terraform/` | App infrastructure, applied by the pipeline: APIs, VPC/subnet/firewall, static IP, Firestore, Artifact Registry, deployer + VM service accounts and IAM, VM |
| `infra/vm-startup.sh` | VM startup script that installs Docker + compose plugin |
| `deploy/docker-compose.yml` | What runs on the VM (`/opt/profile-app`) |
| `deploy/deploy.sh` | Runs on the VM: writes `.env` (image + Firestore URL from instance metadata), pulls, `compose up`, health + DB check |
| `docker-compose.yaml` | Local development only: a MongoDB container + mongo-express |

## CI/CD

```mermaid
flowchart LR
  pr[Pull request<br/>infra/terraform/**] --> plan1[terraform plan<br/>tf-plan, read-only] --> comment[Plan posted<br/>as PR comment]
  merge[Merge to main] --> plan2[terraform plan<br/>tf-plan] --> gate{{Approve in<br/>environment 'infra'}} --> apply[terraform apply<br/>saved plan, tf-apply]
  push[Push to main<br/>app/** or deploy/**] --> deploy[deploy-gce.yml<br/>gh-deployer]
```

Each job logs in with its own Workload Identity provider and service account:

| Job | Provider accepts tokens from | Service account | Can |
|---|---|---|---|
| Terraform plan | PRs in this repo, or `main` | `tf-plan` | read the project and the state (plan runs with `-lock=false`) |
| Terraform apply | `main` **and** environment `infra` | `tf-apply` | create/change everything in `infra/terraform` |
| App deploy | `main` | `gh-deployer` | push images, SSH to the one VM |

Each provider stamps its tokens with `attribute.purpose`, and each service account trusts
only its own purpose, so a pull-request token can never be used to apply or deploy.

## Setup (once)

1. **Push this folder to a GitHub repo.**
2. **Bootstrap** (Cloud Shell or your machine, as a project Owner, about 2 minutes):
   ```bash
   cd infra/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # set project_id and github_repo
   terraform init && terraform apply
   ```
3. **Configure GitHub** with the GitHub CLI logged in:
   ```bash
   terraform output -raw gh_setup_commands | bash
   ```
   This sets all repository variables (none are secrets), protects `main` so changes go through
   pull requests, and creates the `infra` environment with you as the required reviewer.
   Required reviewers and branch protection on a **private** repo need a paid GitHub plan
   (Pro/Team); they are free on public repos.
4. **First infrastructure apply:** run the **Terraform** workflow (Actions tab → Run workflow),
   read the plan in the run summary, then approve the `apply` job.
5. **First app deploy:** run the **Build & deploy to GCE** workflow. Later pushes deploy by themselves.

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

![Networking diagram](docs/networking-diagram.svg)

| Resource | Name | Settings |
|---|---|---|
| VPC | `profile-app-vpc` | custom subnet mode (no default-network open rules) |
| Subnet | `profile-app-subnet` | `10.10.0.0/24`, `us-east1`, Private Google Access on |
| Firewall | `profile-app-allow-http` | ingress `tcp:80` from `0.0.0.0/0` → VM service account |
| Firewall | `profile-app-allow-iap-ssh` | ingress `tcp:22` from `35.235.240.0/20` (IAP) → VM service account |
| Firewall | implied | deny all other ingress, allow all egress |
| Address | `profile-app-vm-ip` | regional static external IP on nic0; VM internal IP `10.10.0.10` |

Docker only publishes host `:80 → my-app:3000`. The database is a managed service reached
outbound on TLS 443, so it needs no inbound firewall rule.

## Database: Firestore with MongoDB compatibility

- Enterprise-edition Firestore database `user-account` in `us-east1`, created by Terraform (`infra/terraform/firestore.tf`).
- The app still uses the official `mongodb` Node.js driver (6.x). Only the connection string changed:
  ```
  mongodb://<uid>.<location>.firestore.goog:443/user-account?loadBalanced=true&tls=true&retryWrites=false
    &authMechanism=MONGODB-OIDC&authMechanismProperties=ENVIRONMENT:gcp,TOKEN_RESOURCE:FIRESTORE
  ```
- The connection string holds no secret. It is stored as the VM metadata key `mongo-url`, and
  `deploy.sh` copies it into `.env`.
- The VM service account has `roles/datastore.user`, limited by an IAM condition to this one database.
- Local development is unchanged: `docker compose up` (root `docker-compose.yaml`), then `node app/server.js`.
  Without `MONGO_URL` set, the app falls back to `mongodb://admin:password@localhost:27017`.

## Operating

- Browse the data in the console under **Firestore → user-account → Firestore Studio**, or with
  `mongosh` using the same connection string from a machine with `roles/datastore.user`.
- Roll back: re-run an older workflow run, or on the VM set `APP_IMAGE` in `/opt/profile-app/.env` to an older tag and `docker compose up -d`.
