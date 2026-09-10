# Networking

The first control plane owns public ingress. Additional control planes and
workers communicate over one private node transport. Adding servers provides
datastore redundancy; public DNS continues to target the first host.

## Private node network

| Transport | Use when | Prepare |
| --- | --- | --- |
| OVHcloud vRack | Every node is an eligible OVHcloud Dedicated Server | Activated vRack, attached interfaces, unused RFC1918 subnet and unique node addresses |
| Tailscale | Nodes span providers, locations or unrelated LANs | Tailnet and a temporary personal API access token |

The [installer](installation.md) and [node assistant](node-enrollment.md) share
the account wizard and transport setup. They validate the account, prepare the
private interface, prove private SSH, and then apply UFW. Keep provider console
or rescue access available while configuring a new network.

### OVHcloud vRack

Activate the vRack and record every server's service name, private NIC name or
MAC, and assigned private address. Attach servers manually in the OVHcloud
Control Panel, or let the wizard attach their interfaces through the API.
Host configuration uses Netplan or ifupdown and preserves the public route.

For unattended installation on a prepared vRack:

```bash
export K3S_NODE_TRANSPORT=vrack
export K3S_PRIVATE_ADDRESS=10.40.0.10
export K3S_PRIVATE_INTERFACE=eno2
export K3S_NODE_NETWORK_CIDR=10.40.0.0/24
export K3S_CONTROL_PLANE_IPS=10.40.0.11,10.40.0.12
export K3S_WORKER_IPS=10.40.0.20
export K3S_CONTROL_PLANE_SSH_USER=admin K3S_WORKER_SSH_USER=admin
```

Use `K3S_PRIVATE_INTERFACE_MAC` to verify the expected NIC and
`K3S_VRACK_VLAN_ID` for a tagged vRack VLAN when needed. Final node counts and
scheduling remain [installer inputs](installation.md#unattended-installation).

API-managed attachment additionally uses `OVH_VRACK_AUTOMATE_ACCOUNT=true`,
`OVH_API_ENDPOINT`, `OVH_VRACK_SERVICE_NAME`,
`OVH_CONTROL_PLANE_SERVICE_NAME`, `OVH_APPLICATION_KEY`,
`OVH_APPLICATION_SECRET` and `OVH_CONSUMER_KEY`. The temporary credentials need:

```text
GET  /vrack
GET  /vrack/*
POST /vrack/*/dedicatedServerInterface
GET  /dedicated/server/*/networking
```

The wizard prints the regional credential page and verifies access before
making changes. Revoke temporary credentials after enrollment.

### Tailscale

Create a short-lived personal API token in the tailnet's **Settings > Keys**
page using an account allowed to manage its devices and policy. The wizard
accepts a `tskey-api-` token and issues one-use tagged device keys itself. See
the [Tailscale API documentation](https://tailscale.com/docs/reference/tailscale-api).

```bash
export K3S_NODE_TRANSPORT=tailscale
export TAILSCALE_TAILNET='example.com' # '-' uses the token's tailnet
export TAILSCALE_MESH_NAME=bm-cluster
export TAILSCALE_NODE_HOSTNAME=bm-control-plane
read -rsp 'Tailscale personal API token: ' TAILSCALE_API_TOKEN
echo
export TAILSCALE_API_TOKEN
```

The configurator merges this cluster's role tags and grants into the existing
policy, installs Tailscale on each target, and discovers its private address.
K3s binds to `tailscale0` with trusted node CIDR `100.64.0.0/10`. Control planes
and workers have separate grants; etcd traffic is limited to control planes.
Unset and revoke the API token after enrollment.

To provision just the mesh, run `./scripts/configure-tailscale.sh --fleet`.
For K3s membership, use `./add-node.sh` so installation and security are also
reconciled.

## Exposure boundaries

| Node | Inbound access |
| --- | --- |
| First control plane | Local or internet exposure; public HTTP/HTTPS is restricted to Cloudflare networks in the managed public configuration |
| Additional control plane | Private SSH from the first control plane, private Kubernetes API and etcd peers; no public ServiceLB advertisement |
| Worker | Private SSH from the first control plane and required K3s/Longhorn peer traffic; no inbound server API, etcd or public ingress |

Added nodes use default-deny inbound UFW. Both host input and forwarded
Docker/Kubernetes traffic are restricted on non-cluster interfaces for IPv4
and IPv6; outbound connections and their replies remain available. Private
SSH must originate from the exact trusted control-plane address before the
provider-facing path is closed. See [host security](security.md) for controls
and audits, and [node enrollment](node-enrollment.md) for role-specific setup.

## Service DNS and registry routing

CoreDNS resolves `<service>.internal.<your-domain>` to the matching Service in
`infra`, preserving additional DNS labels for headless services. Curated aliases route
services such as Longhorn into their own namespaces. Application-owned
services use canonical Kubernetes DNS names. The private zone is cluster-only;
Cloudflare does not publish it, and ordinary host resolvers cannot use it.

K3s/containerd routes `registry.<your-domain>` to the fixed internal Registry
service endpoint. Cluster automation uses internal GitLab/API routes, while
the Dependency Proxy uses canonical `gitlab.<your-domain>` HTTPS. Kubernetes
API clients retain `kubernetes.default.svc`, which matches the server certificate.
Public Docker clients use `registry.<your-domain>` over HTTPS.

## Cloudflare

Public host inventories live in [config/platform.env](../config/platform.env).
The configurator reconciles proxied DNS, Origin CA TLS, DNSSEC, WAF/cache rules
and Keycloak-backed Access for administration. Both the apex and `www` records
are published; the website repository owns the redirect and application Ingress.
Node administration has a separate unproxied hostname controlled by
`CLOUDFLARE_NODE_DNS_LABEL`.

```bash
./scripts/configure-cloudflare.sh --zone example.com
```

The script prompts for a scoped Cloudflare **User API Token** and prints the
required permissions. For automation, supply `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_ACCESS_ALLOWED_EMAILS` and `CLOUDFLARE_ACCESS_TEAM_NAME`. Complete
registrar nameserver delegation and DNSSEC prerequisites before unattended
setup; interactive setup pauses with the required registrar values.

Registry clients cannot answer browser bot challenges. Reconciliation disables
basic Bot Fight Mode, which has no hostname exceptions, and skips Super Bot
Fight Mode only for the Registry hostname. Other WAF, rate-limit and TLS
controls remain enabled. The token therefore needs **Bot Management Read** and
**Edit**, in addition to the other permissions printed by the configurator.
