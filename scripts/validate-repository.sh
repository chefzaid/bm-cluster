#!/usr/bin/env bash
# One offline deployment gate; --live adds API dry-runs in the active context.
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=false
while (( $# )); do
    case "$1" in
        --live) LIVE=true ;;
        -h|--help)
            printf 'Usage: scripts/validate-repository.sh [--live]\n\nValidate deployment inputs, rendering and recovery safeguards.\n--live also uses Kubernetes server-side dry-run; it does not install resources.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
cd "$ROOT"
for command in git shellcheck python3 helm ansible-playbook node jq sqlite3 flock; do
    command -v "$command" >/dev/null || { printf 'Required validation tool is missing: %s\n' "$command" >&2; exit 1; }
done
python3 -c 'import yaml' || { printf 'Python PyYAML is required.\n' >&2; exit 1; }
WORK="$(mktemp -d /tmp/bm-cluster-validation.XXXXXX)"
trap 'rm -r -- "$WORK"' EXIT

mapfile -d '' -t candidates < <(git ls-files -z --cached --others --exclude-standard | LC_ALL=C sort -zu)
source_files=()
shell_scripts=()
for path in "${candidates[@]}"; do
    [[ -f "$path" ]] || continue
    source_files+=("$path")
    if [[ "$path" == *.sh ]]; then
        bash -n "$path"
        shell_scripts+=("$path")
    fi
done
printf '[PASS] Shell syntax\n'
shellcheck -x "${shell_scripts[@]}"
printf '[PASS] ShellCheck\n'

python3 scripts/validate-manifests.py --output "$WORK/rendered"
for playbook in ansible/*.yml; do
    ansible-playbook -i ansible/inventory --syntax-check "$playbook" > "$WORK/ansible.log" 2>&1 || {
        cat "$WORK/ansible.log" >&2
        exit 1
    }
done
printf '[PASS] Ansible playbook syntax\n'

# These suites exercise data-loss, secret-handling and physical fencing paths.
# The selection and reason for each exception are documented in docs/structure.md.
bash tests/test-k3s-backups.sh
for suite in test-postgres-ha.py test-kafka-ha.py test-vault-unseal.py test-vault-ha.py test-node-fencing.py; do
    python3 "tests/$suite"
done
printf '[PASS] Six deployment and recovery safety suites\n'

if [[ "$LIVE" == true ]]; then
    command -v kubectl >/dev/null || { printf 'kubectl is required for --live.\n' >&2; exit 1; }
    kubectl cluster-info >/dev/null
    for manifest in "$WORK"/rendered/*.yaml; do
        kubectl apply --dry-run=server -f "$manifest" >/dev/null
    done
    printf '[PASS] Kubernetes server-side dry-runs\n'
fi

git diff --check
if grep -IEq '((cfat|cfut)_[[:alnum:]]{20,}|tskey-(api|auth)-[[:alnum:]_-]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' "${source_files[@]}"; then
    printf 'Recognizable token or private key found in repository sources.\n' >&2
    exit 1
fi
printf '[PASS] Patch whitespace and recognizable credential scan\nValidation passed.\n'
