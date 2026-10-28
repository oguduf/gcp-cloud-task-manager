#!/usr/bin/env bash
# Start the nginx frontend and Node API containers on a private MIG instance.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MD="http://metadata.google.internal/computeMetadata/v1"
metadata() {
  curl --fail --silent --show-error -H 'Metadata-Flavor: Google' "$MD/$1"
}

apt-get update -y
apt-get install -y ca-certificates curl docker.io python3
systemctl enable --now docker

BACKEND_IMAGE="$(metadata instance/attributes/app-backend-image)"
FRONTEND_IMAGE="$(metadata instance/attributes/app-frontend-image)"
MONGO_URL="$(metadata instance/attributes/mongo-url)"
MONGO_DB_NAME="$(metadata instance/attributes/mongo-db-name)"
REGISTRY_HOST="${BACKEND_IMAGE%%/*}"
ACCESS_TOKEN="$(metadata instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
printf '%s' "$ACCESS_TOKEN" | docker login -u oauth2accesstoken --password-stdin "https://${REGISTRY_HOST}"
unset ACCESS_TOKEN

docker pull "$BACKEND_IMAGE"
docker pull "$FRONTEND_IMAGE"
docker network inspect employee-app >/dev/null 2>&1 || docker network create employee-app
docker rm -f employee-frontend employee-backend >/dev/null 2>&1 || true

# The backend is private to the Docker network. It uses its VM's metadata identity
# for Firestore MongoDB OIDC; nginx is the only container publishing host port 80.
docker run --detach --name employee-backend \
  --network employee-app --network-alias backend \
  --restart unless-stopped --log-driver=gcplogs \
  --add-host metadata:169.254.169.254 \
  --env MONGO_URL="$MONGO_URL" --env MONGO_DB_NAME="$MONGO_DB_NAME" \
  "$BACKEND_IMAGE"

docker run --detach --name employee-frontend \
  --network employee-app --publish 80:80 \
  --restart unless-stopped --log-driver=gcplogs \
  "$FRONTEND_IMAGE"

# The backend health endpoint confirms its Firestore connection; the MIG/LB
# health check uses /healthz so an API/database outage is visible separately.
for attempt in $(seq 1 60); do
  if curl --fail --silent http://127.0.0.1/api/health >/dev/null; then
    exit 0
  fi
  sleep 5
done

docker logs --tail 100 employee-backend >&2 || true
docker logs --tail 100 employee-frontend >&2 || true
exit 1
