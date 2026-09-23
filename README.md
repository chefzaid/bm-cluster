# Private Cloud Platform

Build and operate your organization's private cloud on bare-metal infrastructure.
This K3s platform brings application delivery, identity, networking, storage,
databases, observability, security, and Odoo together under your own domain.
Automated installation and GitOps keep the platform repeatable as your
infrastructure grows.

The installer collects your company name and presents the intranet as
**`<company name> Cloud`**. Your domain, node, and delivery identity are also
installation inputs; no company name is built in. See
[organization settings](docs/installation.md#organization-and-installation-identity)
for interactive setup, unattended inputs, and preservation of existing settings.

Application repositories own their runtime manifests, pipelines, secrets
contracts and Argo CD Applications. The platform discovers supported workloads
through Kubernetes metadata; it has no application repository inventory.
Use [`add-repos.sh`](docs/repository-onboarding.md) to import repositories and
configure selected applications from their own onboarding declarations.

Deploy application workloads in the **`apps` Kubernetes namespace** to enable
automatic discovery by **SonarQube, Prometheus/Grafana, and ELK/Kibana**. The
platform creates per-application metrics and logs dashboards and discovers source
projects for Sonar analysis. See the [namespace and discovery requirements](docs/application-onboarding.md#namespace-and-automatic-discovery)
for deployment settings, the Sonar scanner contract, and optional metrics endpoints.

## Topology

```mermaid
flowchart TB
    accTitle: Cluster architecture and application ownership
    accDescr: Public traffic enters through Cloudflare. Default ingress uses the first control plane; the optional HA profile uses replicated tunnel connectors and ingress on every control plane. Applications and platform services use internal data services and persistent storage.
    Client["Browser or API client"] --> CF["Cloudflare<br/>DNS, edge TLS, and Access for admin UIs"]
    subgraph Cluster["K3s cluster"]
        Ingress["Traefik ingress<br/>Default: first control plane<br/>HA: Tunnel and ingress per control plane"]
        Apps["apps<br/>Externally managed applications"]
        Corp["corp<br/>Odoo"]
        Platform["infra<br/>Delivery, identity, and observability services"]
        Data["infra: internal data services<br/>PostgreSQL, MongoDB, Redis, Kafka, Elasticsearch"]
        Storage["Longhorn<br/>Persistent volumes"]
        Ingress --> Apps
        Ingress --> Corp
        Ingress --> Platform
        Apps --> Data
        Corp --> Data
        Platform --> Data
        Corp -->|filestore| Storage
        Platform -->|persistent service data| Storage
        Data --> Storage
    end
    CF --> Ingress
```

The default public entry point is the first control plane. Nodes communicate
over a private network, with one control plane or an odd embedded-etcd quorum
plus optional workers. The opt-in [HA profile](docs/high-availability.md) adds
replicated Tunnel ingress and shared-service quorums after explicit data
migrations. HA requires additional physical hosts; adding nodes alone does not
enable it. Each application repository configures and verifies its own
availability. Persistent singleton tools still have
an outage while their writer and volume recover safely.

| Namespace | Responsibility |
|---|---|
| `infra` | Shared platform services, managed here |
| `apps` | External applications, managed by their repositories |
| `corp` | Corporate applications; Odoo is managed here |
| `gitlab-runners` | Isolated CI job workloads |
| `longhorn-system` | Persistent storage management |
| `kube-system` | Kubernetes networking and system components |

Vault supplies credentials through External Secrets. Argo CD reconciles desired
state from GitLab. PostgreSQL, MongoDB, Redis, Kafka, Elasticsearch, and
Prometheus remain internal services. [Networking](docs/networking.md) explains
private transport, service DNS, and public exposure.

See the [node topology](docs/networking.md#node-topology) and
[application and platform CI/CD flows](docs/delivery.md#pipelines-and-outputs)
for the deployment view.

## Services and URLs

Homepage at `https://intranet.<your-domain>` is the service directory, including
internal components and application-owned entries. Replace `<your-domain>`
below with the domain supplied during installation. Administrative UIs
use the access controls described in [security and identity](docs/security.md).

| Service | URL | Purpose |
|---|---|---|
| Odoo | `https://odoo.<your-domain>` | ERP and CRM |
| Homepage | `https://intranet.<your-domain>` | Service catalog and cluster status |
| GitLab | `https://gitlab.<your-domain>` | Source, CI, artifacts, and packages |
| Container Registry | `https://registry.<your-domain>/v2/` | OCI image API; browse images in GitLab |
| Argo CD | `https://argocd.<your-domain>` | GitOps delivery |
| SonarQube | `https://sonarqube.<your-domain>` | Source quality analysis |
| Grafana | `https://grafana.<your-domain>` | Metrics and security dashboards |
| Kibana | `https://kibana.<your-domain>` | Logs and audit dashboards |
| Keycloak | `https://keycloak.<your-domain>/auth/admin/master/console/` | Identity administration |
| Vault | `https://vault.<your-domain>` | Secrets and policies |
| Longhorn | `https://longhorn.<your-domain>` | Volumes, snapshots, and backups |
| Portainer | `https://portainer.<your-domain>` | Kubernetes management |
| DBGate | `https://dbgate.<your-domain>` | PostgreSQL, MongoDB, and Redis administration |
| Kafbat UI | `https://kafka.<your-domain>` | Kafka administration |
| Trivy reports | `https://grafana.<your-domain>/d/trivy-security/trivy-security-reports` | Current workload and cluster findings |
| Lynis reports | `https://kibana.<your-domain>/app/dashboards#/view/lynis-security-audits` | Host audit history |

Supporting components include K3s/CoreDNS/ServiceLB, Traefik Ingress, Longhorn,
External Secrets, the Descheduler, Prometheus/Alertmanager, node exporter,
kube-state-metrics, Elasticsearch/Logstash/Fluent Bit/Filebeat, and Trivy
Operator. Host controls use UFW, Fail2ban, CrowdSec, and Lynis according to node
role and exposure.

## Repository layout

The root commands install the cluster, add nodes and onboard repositories.
`config/` owns defaults and host inputs; `k8s/` owns desired platform resources;
`scripts/` owns automation; `ansible/` provides unattended entry points.
`tests/` contains only deployment and recovery safety checks.

See the [directory map and maintenance rules](docs/structure.md) for every
directory's purpose, where to make changes and why the remaining tests exist.

## Documentation

| Task | Guide |
|---|---|
| Install the cluster | [Installation](docs/installation.md) |
| Choose private transport and exposure | [Networking](docs/networking.md) |
| Add control planes or workers | [Node enrollment](docs/node-enrollment.md) |
| Prepare and activate availability across hosts | [High availability](docs/high-availability.md) |
| Install or reconcile through Ansible | [Ansible](docs/ansible.md) |
| Understand CI, registries, and GitOps | [Delivery](docs/delivery.md) |
| Add, synchronize and deploy repositories | [Repository onboarding](docs/repository-onboarding.md) |
| Author an app's setup declaration | [Onboarding contract](docs/application-onboarding.md) |
| Configure automatic and manual source analysis | [Sonar discovery](docs/sonar-discovery.md) |
| Discover per-application Grafana and Kibana dashboards | [Application observability](docs/application-observability.md) |
| Monitor, maintain storage, back up, or validate changes | [Operations](docs/operations.md) |
| Manage host policy, SSO, and credentials | [Security and identity](docs/security.md) |
| Migrate an existing controller and private images | [Platform migration](docs/platform-migration.md) |
| Maintain platform image versions and recovery | [Container images](docs/security-images.md) |
| Operate and recover Vault | [Vault](docs/vault.md) |
| Maintain UI themes | [Platform themes](docs/platform-themes.md) |

Guides describe maintained behavior and link to its owning source. Git history
retains past fixes and migrations.

## License

[GNU General Public License v3.0](LICENSE).
