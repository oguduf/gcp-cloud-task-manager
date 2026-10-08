#!/usr/bin/env bash
# Runs ON THE VM (as root, via the GitHub Actions IAP SSH step).
# Usage: sudo bash deploy.sh <full-image-ref> [secret-id]
set -euo pipefail

IMAGE="${1:?usage: deploy.sh <image> [secret-id]}"
SECRET_ID="${2:-mongo-root-password}"
APP_DIR=/opt/profile-app
REGISTRY_HOST="${IMAGE%%/*}"            # e.g. us-east1-docker.pkg.dev

# Docker is installed by the VM startup script; wait for it on a fresh VM.
for _ in $(seq 1 60); do docker compose version >/dev/null 2>&1 && break; sleep 5; done
docker compose version >/dev/null

install -d -m 750 "$APP_DIR"
install -m 640 /tmp/profile-app/docker-compose.yml "$APP_DIR/docker-compose.yml"
cd "$APP_DIR"

# The VM's own service account pulls the image (roles/artifactregistry.reader).
gcloud auth configure-docker "$REGISTRY_HOST" --quiet >/dev/null 2>&1

# Mongo password comes from Secret Manager - never from GitHub.
MONGO_PWD="$(gcloud secrets versions access latest --secret="$SECRET_ID")"

umask 077
cat > .env <<ENV
APP_IMAGE=${IMAGE}
MONGO_DB_USERNAME=admin
MONGO_DB_PWD=${MONGO_PWD}
ENV

docker compose pull --quiet
docker compose up -d --remove-orphans
docker image prune -f >/dev/null

# Wait for the app to answer locally before reporting success.
for _ in $(seq 1 30); do
  if curl -fsS http://localhost/healthz >/dev/null 2>&1; then
    echo "Deployed ${IMAGE}"
    docker compose ps
    rm -rf /tmp/profile-app
    exit 0
  fi
  sleep 2
done

echo "App did not become healthy" >&2
docker compose logs --tail=100 my-app >&2
exit 1
