#!/usr/bin/env bash
# Run on a prepared application target host, never on the shared platform.
set -euo pipefail
set +x
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/platform.env
source "$ROOT/config/platform.env"

usage() {
    cat <<'EOF'
Usage: install-application-cluster.sh --config FILE --environment int|uat|prod
       [--output-kubeconfig FILE]

Run on the selected prepared Ubuntu target host with Python/PyYAML, curl,
jq, OpenSSL, nftables, Tailscale and passwordless sudo. Installs pinned K3s
and a persistent firewall guard for its private control/overlay ports.
The subsequent configure-deployment-environments.py command installs the app
foundation and registers it with central Argo CD. It never installs a second
GitLab, Argo CD, Vault, database, Longhorn or monitoring platform.

The target's API address must be its existing Tailscale address. Configure
tailnet grants for central services/API access before running this command.
No ambient kubeconfig is read or overwritten. Existing unrelated K3s is refused.
EOF
}
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
inventory="" environment="" output=""
while (( $# )); do
    case "$1" in
        --config|--environment|--output-kubeconfig)
            (( $# >= 2 )) || die "Missing value for $1"
            case "$1" in
                --config) inventory="$2" ;;
                --environment) environment="$2" ;;
                --output-kubeconfig) output="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ -n "$inventory" && -n "$environment" ]] || { usage >&2; exit 2; }
command -v python3 >/dev/null || die "Required command not found: python3"
python3 -c 'import yaml' || die "Install python3-yaml first"
# Reject local targets before checking remote tooling or touching host state.
python3 - "$ROOT" "$inventory" "$environment" <<'PYMODE'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from lib.deployment_environments import environment_context, load_inventory
target = environment_context(load_inventory(sys.argv[2]), sys.argv[3])
if target["mode"] == "local":
    raise SystemExit("Local environments reuse the installed platform; run configure-deployment-environments.py instead of installing K3s")
PYMODE
for command in curl jq openssl tailscale sudo ip nft; do
    command -v "$command" >/dev/null || die "Required command not found: $command"
done
sudo -n true || die "Passwordless sudo is required"
work="$(mktemp -d /tmp/application-cluster-install.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
python3 - "$ROOT" "$inventory" "$environment" "$work/node-firewall.nft" > "$work/settings.json" <<'PY'
import importlib.util, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1] + "/scripts")
from lib.deployment_environments import environment_context, load_inventory
inventory = load_inventory(sys.argv[2])
target = environment_context(inventory, sys.argv[3])
target["platformDomain"] = inventory["platform"]["domain"]
spec = importlib.util.spec_from_file_location('registration', sys.argv[1] + '/scripts/configure-deployment-environments.py')
registration = importlib.util.module_from_spec(spec); spec.loader.exec_module(registration)
Path(sys.argv[4]).write_text(registration.node_firewall(target["podCIDR"]))
print(json.dumps({"target": target, "platform": inventory["platform"]}))
PY
cluster_name="$(jq -r .target.clusterName "$work/settings.json")"
server="$(jq -r .target.server "$work/settings.json")"
private_ip="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname)' "$server")"
gateway="$(jq -r .platform.gateway.address "$work/settings.json")"
pod_cidr="$(jq -r .target.podCIDR "$work/settings.json")"
registry_host="$(jq -r .platform.services.registry.host "$work/settings.json")"
registry_endpoint="$(jq -r .platform.services.registry.mirrorEndpoint "$work/settings.json")"
[[ "$server" == "https://$private_ip:6443" ]] || die "Bootstrap requires an explicit Tailscale IPv4 API address on port 6443"
tailscale status --json > "$work/tailscale.json"
jq -e --arg address "$private_ip" '.BackendState == "Running" and (.Self.TailscaleIPs | index($address) != null)' \
    "$work/tailscale.json" >/dev/null || die "Selected API address is not this host's running Tailscale identity"
jq -e --arg address "$gateway" '.Peer | any(.[]; .Online == true and (.TailscaleIPs | index($address) != null))' \
    "$work/tailscale.json" >/dev/null || die "The platform gateway must be an online peer in the same tailnet"
ip route get "$gateway" | head -1 | grep -Eq 'dev tailscale0([[:space:]]|$)' || die "The gateway is not routed over tailscale0"
python3 - "$work/settings.json" "$private_ip" <<'PY'
import ipaddress,json,sys
data=json.load(open(sys.argv[1])); address=ipaddress.ip_address(sys.argv[2])
if not any(address in ipaddress.ip_network(cidr) for cidr in data['target']['nodeCIDRs']):
    raise SystemExit('Local Tailscale address is outside the target nodeCIDRs')
PY
jq '{environment:.target.environment,clusterName:.target.clusterName,podCIDR:.target.podCIDR,platformDomain:.target.platformDomain}' \
    "$work/settings.json" > "$work/identity.json"
state=/etc/rancher/k3s/application-cluster.json
installed=false
if sudo test -f /etc/rancher/k3s/k3s.yaml || systemctl is-active --quiet k3s; then
    installed=true
    sudo test -f "$state" || die "Existing K3s has no application-cluster identity; refusing to convert it"
fi
if sudo test -f "$state"; then
    # Private temporary files intentionally remain owned by the invoking user.
    # shellcheck disable=SC2024
    sudo cat "$state" > "$work/installed.json"
    jq -e --slurpfile expected "$work/identity.json" '. == $expected[0]' "$work/installed.json" >/dev/null || \
        die "Existing application cluster identity differs; do not reuse another environment's host"
fi
systemctl is-active --quiet k3s-agent && die "This host is already a K3s worker"
sudo install -d -m 0755 /etc/rancher/k3s
sudo install -m 0600 "$work/identity.json" "$state"
sudo install -D -m 0644 "$work/node-firewall.nft" /etc/nftables.d/application-cluster.nft
cat > "$work/application-cluster-firewall.service" <<'EOF'
[Unit]
Description=Private application cluster control and overlay ports
Before=k3s.service k3s-agent.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet application_cluster
ExecStart=/usr/sbin/nft -f /etc/nftables.d/application-cluster.nft

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 0644 "$work/application-cluster-firewall.service" /etc/systemd/system/application-cluster-firewall.service
sudo systemctl daemon-reload
sudo systemctl enable application-cluster-firewall.service >/dev/null
sudo systemctl restart application-cluster-firewall.service
if [[ "$installed" == false ]]; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 https://get.k3s.io -o "$work/install-k3s.sh"
    sudo env INSTALL_K3S_VERSION="$DEFAULT_K3S_INSTALL_VERSION" sh "$work/install-k3s.sh" server \
        --disable traefik --disable local-storage --secrets-encryption --write-kubeconfig-mode 600 \
        --node-name "$cluster_name" --node-ip "$private_ip" --advertise-address "$private_ip" \
        --bind-address "$private_ip" --tls-san "$private_ip" --flannel-iface tailscale0 \
        --kubelet-arg "address=$private_ip" \
        --cluster-cidr "$pod_cidr" --kube-apiserver-arg 'api-audiences=https://kubernetes.default.svc.cluster.local,vault' \
        --node-label "bm-cluster.io/application-environment=$environment" \
        --node-label 'svccontroller.k3s.cattle.io/enablelb=true'
fi
# shellcheck disable=SC2024
sudo cat /etc/rancher/k3s/k3s.yaml > "$work/kubeconfig.yaml"
python3 - "$work/kubeconfig.yaml" "$server" "$cluster_name" <<'PY'
import sys,yaml
path,server,name=sys.argv[1:]; data=yaml.safe_load(open(path))
data['clusters'][0]['cluster']['server']=server
data['clusters'][0]['name']=name
data['users'][0]['name']=name
data['contexts'][0]={'name':name,'context':{'cluster':name,'user':name}}
data['current-context']=name
with open(path,'w') as stream: yaml.safe_dump(data,stream)
PY
export KUBECONFIG="$work/kubeconfig.yaml"
for attempt in $(seq 1 60); do
    kubectl get --raw=/readyz >/dev/null 2>&1 && break
    (( attempt < 60 )) || die "K3s API did not become Ready"
    sleep 2
done
if sudo test -f /etc/rancher/k3s/registries.yaml; then
    # Do not let the legacy mirror helper silently retain a changed endpoint.
    # shellcheck disable=SC2024
    sudo cat /etc/rancher/k3s/registries.yaml > "$work/registries.yaml"
    python3 - "$work/registries.yaml" "$registry_host" "$registry_endpoint" <<'PY'
import sys,yaml
path,host,endpoint=sys.argv[1:]; data=yaml.safe_load(open(path)) or {}
mirror=data.get('mirrors',{}).get(host)
if mirror is not None and mirror.get('endpoint') != [endpoint]:
    raise SystemExit('Existing registry mirror differs from inventory; migrate /etc/rancher/k3s/registries.yaml explicitly before retrying')
PY
fi
K3S_REGISTRY_HOST="$registry_host" K3S_REGISTRY_ENDPOINT="$registry_endpoint" \
    K3S_REMOVED_REGISTRY_HOSTS="" "$ROOT/scripts/configure-k3s-registry-mirror.sh"
"$ROOT/scripts/configure-k3s-apparmor.sh"
python3 - "$ROOT" "$work/settings.json" <<'PY' > "$work/foundation.json"
import importlib.util,json,sys
sys.path.insert(0,sys.argv[1]+'/scripts')
spec=importlib.util.spec_from_file_location('registration',sys.argv[1]+'/scripts/configure-deployment-environments.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
print(json.dumps({'apiVersion':'v1','kind':'List','items':module.namespace_foundation(json.load(open(sys.argv[2]))['target'])}))
PY
kubectl apply --server-side --field-manager application-cluster-bootstrap -f "$work/foundation.json"
kubectl wait --for=condition=Ready nodes --all --timeout=180s
if [[ -z "$output" ]]; then
    output="$HOME/.kube/$cluster_name.yaml"
fi
[[ ! -L "$output" ]] || die "Refusing a symlink kubeconfig destination"
if [[ -e "$output" ]]; then
    old_ca="$(kubectl --kubeconfig "$output" config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    new_ca="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    [[ -n "$old_ca" && "$old_ca" == "$new_ca" ]] || die "Output kubeconfig already belongs to a different cluster"
fi
install -d -m 0700 "$(dirname "$output")"
install -m 0600 "$work/kubeconfig.yaml" "$output"
printf 'Application K3s ready: %s. Private administrator kubeconfig: %s\n' "$cluster_name" "$output"
printf 'Transfer that file securely to the administration host, then run configure-deployment-environments.py.\n'
