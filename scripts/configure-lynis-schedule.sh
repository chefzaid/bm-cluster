#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo "sudo is required to configure the Lynis schedule." >&2
    exit 1
  }
  exec sudo -- "$0" "$@"
fi

command -v lynis >/dev/null 2>&1 || {
  echo "Lynis must be installed before configuring its schedule." >&2
  exit 1
}
command -v systemctl >/dev/null 2>&1 || {
  echo "systemd is required to configure the Lynis schedule." >&2
  exit 1
}

install_managed_file() {
  local destination="$1"
  local mode="$2"
  local temporary_file

  temporary_file="$(mktemp)"
  cat > "$temporary_file"
  install -D -o root -g root -m "$mode" "$temporary_file" "$destination"
  rm -f "$temporary_file"
}

install_managed_file /usr/local/sbin/bm-cluster-lynis-monthly 0750 <<'RUNNER'
#!/bin/bash
set -euo pipefail

umask 0077
archive_dir=/var/log/lynis-reports
canonical_report=/var/log/lynis-report.dat
canonical_log=/var/log/lynis.log
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

install -d -o root -g root -m 0700 "$archive_dir"
working_dir="$(mktemp -d "$archive_dir/.run.XXXXXX")"
# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  rm -rf -- "$working_dir"
}
trap cleanup EXIT

report_file="$working_dir/lynis-report.dat"
log_file="$working_dir/lynis.log"
output_file="$working_dir/lynis-output.txt"

set +e
lynis audit system --cronjob --no-colors \
  --log-file "$log_file" \
  --report-file "$report_file" \
  > "$output_file" 2>&1
audit_status=$?
set -e

if [[ ! -s "$report_file" ]]; then
  echo "Lynis did not produce a structured report." >&2
  exit "${audit_status:-1}"
fi

# Replace the canonical files only after a complete report exists. Filebeat
# follows the canonical report; timestamped copies provide host-side evidence.
install -o root -g root -m 0600 "$report_file" "$canonical_report"
install -o root -g root -m 0600 "$log_file" "$canonical_log"
install -o root -g root -m 0600 "$report_file" "$archive_dir/lynis-${timestamp}-report.dat"
install -o root -g root -m 0600 "$log_file" "$archive_dir/lynis-${timestamp}.log"
install -o root -g root -m 0600 "$output_file" "$archive_dir/lynis-${timestamp}.txt"

# Retain a rolling twelve months of local reports. Elasticsearch applies the
# same 365-day retention independently after Filebeat ingestion.
find "$archive_dir" -maxdepth 1 -type f -name 'lynis-*' -mtime +365 -delete

exit "$audit_status"
RUNNER

install_managed_file /etc/systemd/system/bm-cluster-lynis.service 0644 <<'SERVICE'
[Unit]
Description=BM Cluster monthly Lynis security audit
Documentation=man:lynis(8)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bm-cluster-lynis-monthly
UMask=0077
Nice=10
IOSchedulingClass=idle
PrivateTmp=true
ProtectHome=read-only
SERVICE

install_managed_file /etc/systemd/system/bm-cluster-lynis.timer 0644 <<'TIMER'
[Unit]
Description=Run the BM Cluster Lynis audit monthly

[Timer]
OnCalendar=*-*-15 03:00:00
Persistent=true
AccuracySec=1min
Unit=bm-cluster-lynis.service

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now bm-cluster-lynis.timer >/dev/null
echo "Lynis timer configured for the 15th of every month at 03:00 local time."
