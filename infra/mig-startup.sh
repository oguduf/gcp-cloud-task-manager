#!/usr/bin/env bash
# Boot a private MIG instance, pull its immutable image, and collect app logs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MD="http://metadata.google.internal/computeMetadata/v1"
metadata() {
  curl --fail --silent --show-error -H 'Metadata-Flavor: Google' "$MD/$1"
}

apt-get update -y
apt-get install -y ca-certificates curl docker.io python3
systemctl enable --now docker

IMAGE="$(metadata instance/attributes/app-image)"
MONGO_URL="$(metadata instance/attributes/mongo-url)"
MONGO_DB_NAME="$(metadata instance/attributes/mongo-db-name)"
REGISTRY_HOST="${IMAGE%%/*}"
ACCESS_TOKEN="$(metadata instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
printf '%s' "$ACCESS_TOKEN" | docker login -u oauth2accesstoken --password-stdin "https://${REGISTRY_HOST}"
docker pull "$IMAGE"

install -d -m 0750 /opt/profile-app
install -d -m 0750 -o 1000 -g 1000 /var/log/profile-app
umask 077
printf 'MONGO_URL=%s\nMONGO_DB_NAME=%s\n' "$MONGO_URL" "$MONGO_DB_NAME" >/opt/profile-app/app.env

cat >/usr/local/sbin/run-profile-app <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
source /opt/profile-app/app.env
MD="http://metadata.google.internal/computeMetadata/v1"
IMAGE="$(curl --fail --silent --show-error -H 'Metadata-Flavor: Google' "$MD/instance/attributes/app-image")"
exec /usr/bin/docker run --name profile-app --publish 80:3000 \
  --add-host metadata:169.254.169.254 \
  --volume /var/log/profile-app:/var/log/profile-app \
  --env LOG_FILE=/var/log/profile-app/app.log \
  --env MONGO_URL="$MONGO_URL" --env MONGO_DB_NAME="$MONGO_DB_NAME" "$IMAGE"
RUN
chmod 0750 /usr/local/sbin/run-profile-app

cat >/etc/systemd/system/profile-app.service <<'UNIT'
[Unit]
Description=Profile application container
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/docker rm -f profile-app
ExecStart=/usr/local/sbin/run-profile-app
ExecStop=/usr/bin/docker stop profile-app
ExecStopPost=-/usr/bin/docker rm -f profile-app

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now profile-app.service

# The Ops Agent parses the app's structured JSON log file into Cloud Logging.
curl --fail --silent --show-error --location \
  https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
  -o /tmp/add-google-cloud-ops-agent-repo.sh
bash /tmp/add-google-cloud-ops-agent-repo.sh --also-install
install -d -m 0755 /etc/google-cloud-ops-agent/config.d
cat >/etc/google-cloud-ops-agent/config.yaml <<'YAML'
logging:
  receivers:
    profile_app:
      type: files
      include_paths:
        - /var/log/profile-app/app.log
      record_log_file_path: true
  processors:
    parse_profile_app_json:
      type: parse_json
  service:
    pipelines:
      profile_app:
        receivers: [profile_app]
        processors: [parse_profile_app_json]
YAML
systemctl restart google-cloud-ops-agent
