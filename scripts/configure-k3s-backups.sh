#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURE_OFFSITE_BACKUPS="${CONFIGURE_OFFSITE_BACKUPS:-false}"
BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-}"
BACKUP_S3_ACCESS_KEY="${BACKUP_S3_ACCESS_KEY:-}"
BACKUP_S3_SECRET_KEY="${BACKUP_S3_SECRET_KEY:-}"
BACKUP_REPOSITORY_PASSWORD="${BACKUP_REPOSITORY_PASSWORD:-}"
RUN_BACKUP_NOW="${RUN_BACKUP_NOW:-true}"
backup_environment=""

cleanup() {
  [[ -z "$backup_environment" || ! -f "$backup_environment" ]] || rm -f -- "$backup_environment"
  BACKUP_S3_ACCESS_KEY=""
  BACKUP_S3_SECRET_KEY=""
  BACKUP_REPOSITORY_PASSWORD=""
  unset BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY BACKUP_REPOSITORY_PASSWORD 2>/dev/null || true
}
trap cleanup EXIT

command -v sudo >/dev/null || { echo "sudo is required." >&2; exit 1; }
command -v k3s >/dev/null || { echo "K3s is not installed." >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
[[ "$CONFIGURE_OFFSITE_BACKUPS" =~ ^(true|false)$ ]] || { echo "CONFIGURE_OFFSITE_BACKUPS must be true or false." >&2; exit 1; }
[[ "$RUN_BACKUP_NOW" =~ ^(true|false)$ ]] || { echo "RUN_BACKUP_NOW must be true or false." >&2; exit 1; }

if ! command -v sqlite3 >/dev/null; then
  sudo apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
fi

if [[ "$CONFIGURE_OFFSITE_BACKUPS" == "true" ]]; then
  [[ "$BACKUP_S3_ENDPOINT" == https://* ]] || { echo "BACKUP_S3_ENDPOINT must use HTTPS." >&2; exit 1; }
  [[ -n "$BACKUP_S3_BUCKET" && -n "$BACKUP_S3_REGION" ]] || { echo "BACKUP_S3_BUCKET and BACKUP_S3_REGION are required." >&2; exit 1; }
  [[ -n "$BACKUP_S3_ACCESS_KEY" && -n "$BACKUP_S3_SECRET_KEY" ]] || { echo "S3 access credentials are required." >&2; exit 1; }
  [[ ${#BACKUP_REPOSITORY_PASSWORD} -ge 16 ]] || { echo "BACKUP_REPOSITORY_PASSWORD must contain at least 16 characters." >&2; exit 1; }
  if ! command -v restic >/dev/null; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic >/dev/null
  fi
  backup_environment="$(mktemp)"
  chmod 600 "$backup_environment"
  {
    printf 'RESTIC_REPOSITORY=s3:%s/%s/restic\n' "${BACKUP_S3_ENDPOINT%/}" "$BACKUP_S3_BUCKET"
    printf 'RESTIC_PASSWORD=%q\n' "$BACKUP_REPOSITORY_PASSWORD"
    printf 'AWS_ACCESS_KEY_ID=%q\n' "$BACKUP_S3_ACCESS_KEY"
    printf 'AWS_SECRET_ACCESS_KEY=%q\n' "$BACKUP_S3_SECRET_KEY"
    printf 'AWS_DEFAULT_REGION=%q\n' "$BACKUP_S3_REGION"
  } > "$backup_environment"
  sudo install -d -o root -g root -m 0700 /etc/bm-cluster
  sudo install -o root -g root -m 0600 "$backup_environment" /etc/bm-cluster/backup.env
fi

sudo install -d -o root -g root -m 0700 /var/backups/bm-cluster/k3s
sudo install -o root -g root -m 0750 "$REPO_ROOT/scripts/backup-k3s.sh" /usr/local/sbin/bm-k3s-backup
sudo install -o root -g root -m 0644 "$REPO_ROOT/config/systemd/bm-k3s-backup.service" /etc/systemd/system/bm-k3s-backup.service
sudo install -o root -g root -m 0644 "$REPO_ROOT/config/systemd/bm-k3s-backup.timer" /etc/systemd/system/bm-k3s-backup.timer
sudo systemctl daemon-reload
sudo systemctl enable --now bm-k3s-backup.timer >/dev/null
if [[ "$RUN_BACKUP_NOW" == "true" ]]; then
  sudo systemctl start bm-k3s-backup.service
fi

if [[ "$CONFIGURE_OFFSITE_BACKUPS" == "true" ]] && \
   kubectl get namespace longhorn-system >/dev/null 2>&1 && \
   kubectl get settings.longhorn.io backup-target -n longhorn-system >/dev/null 2>&1; then
  jq -n \
    --arg access "$BACKUP_S3_ACCESS_KEY" \
    --arg secret "$BACKUP_S3_SECRET_KEY" \
    --arg endpoint "$BACKUP_S3_ENDPOINT" \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:"bm-cluster-longhorn-backup",namespace:"longhorn-system"},type:"Opaque",stringData:{AWS_ACCESS_KEY_ID:$access,AWS_SECRET_ACCESS_KEY:$secret,AWS_ENDPOINTS:$endpoint,VIRTUAL_HOSTED_STYLE:"false"}}' \
    | kubectl apply -f - >/dev/null
  backup_target="s3://$BACKUP_S3_BUCKET@$BACKUP_S3_REGION/longhorn"
  kubectl patch settings.longhorn.io backup-target -n longhorn-system --type=merge \
    -p "$(jq -cn --arg value "$backup_target" '{value:$value}')" >/dev/null
  kubectl patch settings.longhorn.io backup-target-credential-secret -n longhorn-system --type=merge \
    -p '{"value":"bm-cluster-longhorn-backup"}' >/dev/null
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: bm-cluster-daily-backup
  namespace: longhorn-system
spec:
  cron: "15 3 * * *"
  task: backup
  groups:
    - bm-cluster
  retain: 14
  concurrency: 2
  labels:
    backup-policy: daily-off-node
EOF
  kubectl label volumes.longhorn.io -n longhorn-system --all \
    recurring-job-group.longhorn.io/bm-cluster=enabled --overwrite >/dev/null 2>&1 || true
  echo "K3s recovery archives and Longhorn volume backups are stored off-node in the configured private bucket."
elif [[ "$CONFIGURE_OFFSITE_BACKUPS" == "true" ]]; then
  echo "K3s off-node archive storage is configured. Rerun this script after Longhorn is installed to enable recurring volume backups."
else
  echo "K3s backups are enabled locally; no off-node destination is configured."
fi
