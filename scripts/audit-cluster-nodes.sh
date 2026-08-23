#!/bin/bash
set -euo pipefail
# Never expose SSH-agent or command details through inherited tracing.
set +x

TARGETS="${LYNIS_REMOTE_TARGETS:-}"
SSH_USER="${LYNIS_SSH_USER:-${USER:-}}"
SSH_PORT="${LYNIS_SSH_PORT:-22}"
IDENTITY_FILE="${LYNIS_IDENTITY_FILE:-}"
REPORT_ROOT="${LYNIS_REPORT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/bm-cluster/lynis-reports}"
NON_INTERACTIVE=false
SKIP_CONTROL_PLANE=false
SUDO=()

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Audit the K3s control plane and worker hosts with the control plane's Lynis copy.

Interactive usage (run on the control plane):
  ./scripts/audit-cluster-nodes.sh

Automation usage:
  ./scripts/audit-cluster-nodes.sh \
    --targets ubuntu@10.0.0.12,ubuntu@10.0.0.13 \
    --identity-file ~/.ssh/id_ed25519 \
    --non-interactive

Options:
  --targets CSV          Worker SSH hosts (default: discover worker InternalIPs with kubectl)
  --ssh-user USER        Default SSH user when a target omits user@ (default: current user)
  --ssh-port PORT        SSH port shared by worker targets (default: 22)
  --identity-file PATH   SSH private key (default: SSH agent/config)
  --report-dir PATH      Protected report root (default: ~/.local/state/bm-cluster/lynis-reports)
  --skip-control-plane   Audit only remote workers
  --non-interactive      Fail instead of prompting
  -h, --help             Show this help

Workers need SSH key authentication and either root access or passwordless sudo.
Lynis is copied to a worker temporarily, executed, and removed after its reports
are retrieved. It is not installed persistently on worker nodes.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets)          shift; [[ $# -gt 0 ]] || error "Missing value for --targets"; TARGETS="$1" ;;
        --targets=*)        TARGETS="${1#*=}" ;;
        --ssh-user)         shift; [[ $# -gt 0 ]] || error "Missing value for --ssh-user"; SSH_USER="$1" ;;
        --ssh-user=*)       SSH_USER="${1#*=}" ;;
        --ssh-port)         shift; [[ $# -gt 0 ]] || error "Missing value for --ssh-port"; SSH_PORT="$1" ;;
        --ssh-port=*)       SSH_PORT="${1#*=}" ;;
        --identity-file)    shift; [[ $# -gt 0 ]] || error "Missing value for --identity-file"; IDENTITY_FILE="$1" ;;
        --identity-file=*)  IDENTITY_FILE="${1#*=}" ;;
        --report-dir)       shift; [[ $# -gt 0 ]] || error "Missing value for --report-dir"; REPORT_ROOT="$1" ;;
        --report-dir=*)     REPORT_ROOT="${1#*=}" ;;
        --skip-control-plane) SKIP_CONTROL_PLANE=true ;;
        --non-interactive)  NON_INTERACTIVE=true ;;
        -h|--help)          usage; exit 0 ;;
        *)                  error "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

prompt() {
    local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
    read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

discover_worker_targets() {
    command -v kubectl >/dev/null 2>&1 || return 0
    kubectl get nodes \
        -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
        -o custom-columns='IP:.status.addresses[?(@.type=="InternalIP")].address' \
        --no-headers 2>/dev/null | awk 'NF && $1 != "<none>" {print $1}' | paste -sd, -
}

build_target() {
    local host="$1"
    if [[ "$host" == *@* || -z "$SSH_USER" ]]; then
        printf '%s' "$host"
    else
        printf '%s@%s' "$SSH_USER" "$host"
    fi
}

target_label() {
    local target="${1#*@}"
    target="${target//[^A-Za-z0-9_.-]/_}"
    [[ -n "$target" ]] || target="worker"
    printf '%s' "$target"
}

command -v lynis >/dev/null 2>&1 || error "Lynis is not installed; apply the control-plane security policy first."
command -v ssh >/dev/null 2>&1 || error "ssh is required."
command -v scp >/dev/null 2>&1 || error "scp is required."
command -v tar >/dev/null 2>&1 || error "tar is required."
[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || error "Invalid SSH port: $SSH_PORT"
[[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"
[[ -d /usr/share/lynis ]] || error "The packaged Lynis data directory is missing: /usr/share/lynis"

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root."
    SUDO=(sudo)
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        "${SUDO[@]}" -n true || error "Non-interactive auditing requires an active sudo credential or passwordless sudo."
    else
        "${SUDO[@]}" -v
    fi
fi

if [[ -z "$TARGETS" ]]; then
    TARGETS="$(discover_worker_targets)"
fi

if [[ "$NON_INTERACTIVE" != "true" ]]; then
    prompt SSH_USER "Default worker SSH user" "$SSH_USER"
    prompt SSH_PORT "Worker SSH port" "$SSH_PORT"
    prompt IDENTITY_FILE "SSH private key path (blank for agent/config)" "$IDENTITY_FILE"
    prompt TARGETS "Worker SSH hosts, comma-separated (blank for control-plane-only audit)" "$TARGETS"
fi

[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || error "Invalid SSH port: $SSH_PORT"
[[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report_dir="$REPORT_ROOT/$timestamp"
current_uid="$(id -u)"
current_gid="$(id -g)"
"${SUDO[@]}" install -d -o "$current_uid" -g "$current_gid" -m 0700 "$report_dir"

work_dir="$(mktemp -d)"
active_target=""
active_remote_dir=""
cleanup() {
    if [[ -n "$active_target" && "$active_remote_dir" == /tmp/bm-cluster-lynis.* ]]; then
        printf -v cleanup_dir '%q' "$active_remote_dir"
        ssh "${ssh_options[@]}" "$active_target" "rm -rf -- $cleanup_dir" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT
mkdir -m 0700 "$work_dir/lynis"
install -m 0755 "$(command -v lynis)" "$work_dir/lynis/lynis"
cp -a /usr/share/lynis/. "$work_dir/lynis/"
tar -C "$work_dir" -czf "$work_dir/lynis-remote.tar.gz" lynis

if [[ "$SKIP_CONTROL_PLANE" != "true" ]]; then
    local_label="$(printf '%s' "$(hostname -s)" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '_')"
    info "Auditing control plane '$local_label'..."
    "${SUDO[@]}" lynis audit system --cronjob --no-colors \
        --log-file "$report_dir/${local_label}.log" \
        --report-file "$report_dir/${local_label}-report.dat" \
        > "$report_dir/${local_label}.txt"
    "${SUDO[@]}" chown "$current_uid:$current_gid" \
        "$report_dir/${local_label}.log" "$report_dir/${local_label}-report.dat"
    chmod 0600 "$report_dir/${local_label}.txt"
    "${SUDO[@]}" chmod 0600 "$report_dir/${local_label}.log" "$report_dir/${local_label}-report.dat"
fi

ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
scp_options=(-q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$SSH_PORT")
if [[ -n "$IDENTITY_FILE" ]]; then
    ssh_options+=(-i "$IDENTITY_FILE")
    scp_options+=(-i "$IDENTITY_FILE")
fi

IFS=',' read -r -a hosts <<< "$TARGETS"
audit_failures=0
for host in "${hosts[@]}"; do
    host="${host#"${host%%[![:space:]]*}"}"
    host="${host%"${host##*[![:space:]]}"}"
    [[ -n "$host" ]] || continue
    target="$(build_target "$host")"
    [[ "$target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ || "$target" =~ ^[A-Za-z0-9._:-]+$ ]] || error "Invalid SSH target: $target"
    label="$(target_label "$target")"

    info "Checking passwordless audit access to $target..."
    remote_uid="$(ssh "${ssh_options[@]}" "$target" 'id -u')" || error "Cannot connect to $target with SSH key authentication."
    [[ "$remote_uid" =~ ^[0-9]+$ ]] || error "Could not determine the remote user ID for $target."
    remote_gid="$(ssh "${ssh_options[@]}" "$target" 'id -g')" || error "Could not determine the remote group ID for $target."
    [[ "$remote_gid" =~ ^[0-9]+$ ]] || error "Could not determine the remote group ID for $target."
    if [[ "$remote_uid" == "0" ]]; then
        remote_sudo=""
    else
        ssh "${ssh_options[@]}" "$target" 'sudo -n true' >/dev/null || error "Passwordless sudo is required on $target."
        remote_sudo="sudo -n"
    fi

    remote_dir="$(ssh "${ssh_options[@]}" "$target" 'mktemp -d /tmp/bm-cluster-lynis.XXXXXX')"
    [[ "$remote_dir" == /tmp/bm-cluster-lynis.* ]] || error "Could not create a safe audit directory on $target."
    active_target="$target"
    active_remote_dir="$remote_dir"
    printf -v quoted_dir '%q' "$remote_dir"
    printf -v quoted_archive '%q' "$remote_dir/lynis-remote.tar.gz"
    printf -v quoted_lynis '%q' "$remote_dir/lynis/lynis"
    printf -v quoted_log '%q' "$remote_dir/lynis.log"
    printf -v quoted_report '%q' "$remote_dir/lynis-report.dat"
    printf -v quoted_output '%q' "$remote_dir/lynis-output.txt"

    info "Running transient Lynis audit on $target..."
    scp "${scp_options[@]}" "$work_dir/lynis-remote.tar.gz" "$target:$remote_dir/lynis-remote.tar.gz"
    if ! ssh "${ssh_options[@]}" "$target" \
        "tar -xzf $quoted_archive -C $quoted_dir && rm -f -- $quoted_archive && $remote_sudo chown -R root:root $quoted_dir/lynis && cd $quoted_dir/lynis && $remote_sudo $quoted_lynis audit system --usecwd --cronjob --no-colors --log-file $quoted_log --report-file $quoted_report > $quoted_output; audit_status=\$?; $remote_sudo chown $remote_uid:$remote_gid $quoted_log $quoted_report 2>/dev/null || true; exit \$audit_status"; then
        warn "Lynis returned a failure for $target; retrieving any reports it produced."
        audit_failures=$((audit_failures + 1))
    fi

    retrieval_failed=false
    scp "${scp_options[@]}" "$target:$remote_dir/lynis-output.txt" "$report_dir/${label}.txt" || retrieval_failed=true
    scp "${scp_options[@]}" "$target:$remote_dir/lynis.log" "$report_dir/${label}.log" || retrieval_failed=true
    scp "${scp_options[@]}" "$target:$remote_dir/lynis-report.dat" "$report_dir/${label}-report.dat" || retrieval_failed=true
    if [[ "$retrieval_failed" == "true" ]]; then
        warn "One or more Lynis report files could not be retrieved from $target."
        audit_failures=$((audit_failures + 1))
    fi
    chmod 0600 "$report_dir/${label}.txt" "$report_dir/${label}.log" "$report_dir/${label}-report.dat" 2>/dev/null || true
    ssh "${ssh_options[@]}" "$target" "rm -rf -- $quoted_dir"
    active_target=""
    active_remote_dir=""
done

info "Lynis cluster audit complete. Protected reports: $report_dir"
[[ "$audit_failures" -eq 0 ]] || error "$audit_failures remote audit operation(s) failed; inspect the retrieved output."
