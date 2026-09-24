# Private Cloud Platform

Build and operate your organization's private cloud on bare-metal infrastructure.
This K3s platform brings application delivery, identity, networking, storage,
databases, observability, security and Odoo together under your own domain.
Automated installation and GitOps keep the platform repeatable as it grows.

Supply your company name during installation to present the intranet as
**`<company name> Cloud`**. Company identity, domains and deployment settings are
configuration inputs; no organization is built into the platform.

## Get started

On the first Ubuntu control-plane host, review the
[installation prerequisites](docs/installation.md), then run:

```bash
./install-control-plane.sh
```

The installer guides setup and verifies the selected services. Open
`https://intranet.<your-domain>` for the service catalog. The
[installation guide](docs/installation.md) also covers unattended setup,
Ansible and reconfiguration.

## How it fits together

Cloudflare routes public traffic to Traefik. K3s runs shared platform services in
`infra`, application workloads in `apps`, and centrally managed Odoo in `corp`.
Longhorn supplies persistent storage; Vault and External Secrets supply credentials.
One shared GitLab provides source, CI and the registry; one central Argo CD
reconciles deployments from Git. Dedicated `int`, `uat` and `prod` application
clusters consume the shared platform services. Choose the destination in GitLab
CI; only application domains vary by environment. See
[deployment targets](docs/installation.md#application-deployment-clusters).

Application repositories own their manifests, pipelines and Argo CD Applications.
Use [`add-repos.sh`](docs/repository-onboarding.md) to import and onboard them.
The platform discovers local applications from Kubernetes metadata; the
[application contract](docs/application-onboarding.md) defines the integration.

Nodes communicate over a private network. Adding nodes and enabling service
availability are separate operations: see [networking](docs/networking.md) for
topology and [high availability](docs/high-availability.md) for capacity,
migration order and remaining limits.

## Guides

| Task | Start here |
| --- | --- |
| Install or reconcile the platform | [Installation](docs/installation.md) |
| Configure networking or expand the cluster | [Networking](docs/networking.md), [node enrollment](docs/node-enrollment.md) |
| Plan resilience and recovery | [High availability](docs/high-availability.md) |
| Import or deploy applications | [Repository onboarding](docs/repository-onboarding.md), [app-author contract](docs/application-onboarding.md) |
| Understand CI, images and GitOps | [Delivery](docs/delivery.md) |
| Check services, storage and backups | [Operations](docs/operations.md) |
| Inspect metrics, logs, scans and alerts | [Observability](docs/observability.md) |
| Manage access and credentials | [Security](docs/security.md) |
| Update images or UI themes | [Maintenance](docs/maintenance.md) |
| Migrate legacy ingress and private images | [Platform migration](docs/platform-migration.md) |
| Change platform source | [Repository structure](docs/structure.md) |

Each topic has one owning guide. Specialized recovery procedures are linked
from the relevant workflow; configuration defaults remain in their owning source.

## License

[GNU General Public License v3.0](LICENSE).
