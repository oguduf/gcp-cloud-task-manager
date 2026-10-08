#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time GCP setup for deploying the profile app to a single Compute Engine VM
# from GitHub Actions using keyless OIDC (Workload Identity Federation).
#
# Run it once from Cloud Shell or any machine with gcloud logged in as a
# project Owner:
#   PROJECT_ID=my-project GITHUB_REPO=my-org/my-repo ./infra/bootstrap.sh
#
# It is safe to re-run: every "create" tolerates "already exists".
# -----------------------------------------------------------------------------
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${GITHUB_REPO:?set GITHUB_REPO (owner/repo)}"
REGION="${REGION:-us-east1}"
ZONE="${ZONE:-us-east1-b}"
AR_REPO="${AR_REPO:-profile-app}"
VM_NAME="${VM_NAME:-profile-app-vm}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
POOL_ID="${POOL_ID:-github-pool}"
PROVIDER_ID="${PROVIDER_ID:-github-provider}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
SECRET_ID="${SECRET_ID:-mongo-root-password}"
NETWORK="${NETWORK:-profile-app-vpc}"
SUBNET="${SUBNET:-profile-app-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.10.0.0/24}"
VM_INTERNAL_IP="${VM_INTERNAL_IP:-10.10.0.10}"

DEPLOYER_SA_NAME="gh-deployer"
VM_SA_NAME="profile-app-vm"
DEPLOYER_SA="${DEPLOYER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
VM_SA="${VM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# run a gcloud "create"; treat "already exists" as success, fail on anything else
ignore_exists() {
  local out
  if ! out="$("$@" 2>&1)"; then
    if grep -q "already exists" <<<"$out"; then echo "   (already exists, skipping)"; else echo "$out" >&2; return 1; fi
  fi
}

gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

echo ">> Enabling APIs"
gcloud services enable \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  oslogin.googleapis.com

echo ">> Artifact Registry repo"
ignore_exists gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker --location="$REGION" \
  --description="Profile app images"

echo ">> Service accounts"
ignore_exists gcloud iam service-accounts create "$DEPLOYER_SA_NAME" \
  --display-name="GitHub Actions deployer (OIDC)"
ignore_exists gcloud iam service-accounts create "$VM_SA_NAME" \
  --display-name="Profile app VM runtime"

echo ">> Mongo root password in Secret Manager"
if ! gcloud secrets describe "$SECRET_ID" >/dev/null 2>&1; then
  openssl rand -hex 24 | tr -d '\n' | \
    gcloud secrets create "$SECRET_ID" --replication-policy=automatic --data-file=-
fi

echo ">> VM service account permissions (pull images, read secret, write logs)"
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" --location="$REGION" \
  --member="serviceAccount:${VM_SA}" --role="roles/artifactregistry.reader" >/dev/null
gcloud secrets add-iam-policy-binding "$SECRET_ID" \
  --member="serviceAccount:${VM_SA}" --role="roles/secretmanager.secretAccessor" >/dev/null
for role in roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${VM_SA}" --role="$role" --condition=None >/dev/null
done

echo ">> Network: dedicated VPC + subnet"
# Custom-mode VPC: no auto-created subnets in every region, and none of the
# permissive default-network rules (default-allow-ssh/rdp/icmp from 0.0.0.0/0).
ignore_exists gcloud compute networks create "$NETWORK" \
  --subnet-mode=custom --bgp-routing-mode=regional
# Private Google Access lets the VM keep reaching Artifact Registry / Secret Manager
# if you later remove its public IP (then add Cloud NAT for Docker Hub pulls).
ignore_exists gcloud compute networks subnets create "$SUBNET" \
  --network="$NETWORK" --region="$REGION" --range="$SUBNET_RANGE" \
  --enable-private-ip-google-access

echo ">> Firewall rules (target = the VM's service account, not a network tag)"
# Everything else inbound hits the VPC's implied deny-all ingress rule.
# SSH only from Google's IAP range - no public port 22.
ignore_exists gcloud compute firewall-rules create profile-app-allow-iap-ssh \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:22 \
  --source-ranges=35.235.240.0/20 --target-service-accounts="$VM_SA" --priority=1000
# The app, published by Docker on host port 80.
ignore_exists gcloud compute firewall-rules create profile-app-allow-http \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges=0.0.0.0/0 --target-service-accounts="$VM_SA" --priority=1000

echo ">> Static external IP (survives VM stop/recreate)"
ignore_exists gcloud compute addresses create "${VM_NAME}-ip" --region="$REGION" --network-tier=PREMIUM
VM_IP="$(gcloud compute addresses describe "${VM_NAME}-ip" --region="$REGION" --format='value(address)')"

echo ">> VM"
if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=20GB \
    --service-account="$VM_SA" --scopes=cloud-platform \
    --network="$NETWORK" --subnet="$SUBNET" \
    --private-network-ip="$VM_INTERNAL_IP" \
    --address="$VM_IP" \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --metadata=enable-oslogin=TRUE \
    --metadata-from-file=startup-script="${SCRIPT_DIR}/vm-startup.sh"
fi

echo ">> Workload Identity Federation (GitHub OIDC)"
ignore_exists gcloud iam workload-identity-pools create "$POOL_ID" \
  --location=global --display-name="GitHub Actions"
# Only tokens from YOUR repo, on the deploy branch, are accepted by this provider.
ignore_exists gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --location=global --workload-identity-pool="$POOL_ID" \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}' && assertion.ref=='refs/heads/${DEPLOY_BRANCH}'"

POOL_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
PROVIDER_NAME="${POOL_NAME}/providers/${PROVIDER_ID}"

# Let identities from the repo impersonate the deployer SA.
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_SA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.repository/${GITHUB_REPO}" >/dev/null

echo ">> Deployer SA permissions (least privilege)"
# push images to this one repo
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" --location="$REGION" \
  --member="serviceAccount:${DEPLOYER_SA}" --role="roles/artifactregistry.writer" >/dev/null
# sudo SSH via OS Login - on this VM only
gcloud compute instances add-iam-policy-binding "$VM_NAME" --zone="$ZONE" \
  --member="serviceAccount:${DEPLOYER_SA}" --role="roles/compute.osAdminLogin" >/dev/null
# open the IAP tunnel - on this VM only
gcloud iap tcp add-iam-policy-binding --zone="$ZONE" --instance="$VM_NAME" \
  --member="serviceAccount:${DEPLOYER_SA}" --role="roles/iap.tunnelResourceAccessor" >/dev/null
# OS Login on a VM that runs as a service account requires actAs on that SA
gcloud iam service-accounts add-iam-policy-binding "$VM_SA" \
  --member="serviceAccount:${DEPLOYER_SA}" --role="roles/iam.serviceAccountUser" >/dev/null
# gcloud compute ssh needs to read the instance / project metadata
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOYER_SA}" --role="roles/compute.viewer" --condition=None >/dev/null

cat <<OUT

=====================================================================
Done. Add these as GitHub repository VARIABLES
(Settings > Secrets and variables > Actions > Variables):

  GCP_PROJECT_ID     = ${PROJECT_ID}
  GCP_REGION         = ${REGION}
  GCP_ZONE           = ${ZONE}
  GCP_WIF_PROVIDER   = ${PROVIDER_NAME}
  GCP_DEPLOYER_SA    = ${DEPLOYER_SA}
  GCP_AR_REPO        = ${AR_REPO}
  GCE_VM_NAME        = ${VM_NAME}

Or with the GitHub CLI:
  gh variable set GCP_PROJECT_ID   -R ${GITHUB_REPO} -b "${PROJECT_ID}"
  gh variable set GCP_REGION       -R ${GITHUB_REPO} -b "${REGION}"
  gh variable set GCP_ZONE         -R ${GITHUB_REPO} -b "${ZONE}"
  gh variable set GCP_WIF_PROVIDER -R ${GITHUB_REPO} -b "${PROVIDER_NAME}"
  gh variable set GCP_DEPLOYER_SA  -R ${GITHUB_REPO} -b "${DEPLOYER_SA}"
  gh variable set GCP_AR_REPO      -R ${GITHUB_REPO} -b "${AR_REPO}"
  gh variable set GCE_VM_NAME      -R ${GITHUB_REPO} -b "${VM_NAME}"

No secrets or JSON keys are needed in GitHub.
App URL after first deploy: http://${VM_IP}
=====================================================================
OUT
