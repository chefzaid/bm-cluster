# Bare-Metal Cluster

Setup for a bare-Metal (BM) cluster providing main DevOps and infrastructure tools necessary for web apps development, deployment, observability, and basic security.

## 🛠 Technologies Used

### Infrastructure & DevOps
*   **Orchestration**: Kubernetes (K3s - Lightweight Kubernetes)
*   **Storage**: Longhorn (distributed block storage)
*   **Ingress**: Nginx Ingress Controller
*   **Containerization**: Docker
*   **CI/CD**: Jenkins (K8s-native build agents)
*   **GitOps**: ArgoCD
*   **Code Quality**: SonarQube
*   **Artifacts**: Nexus Repository Manager OSS
*   **Source Control**: GitLab
*   **Monitoring**: Prometheus, Grafana
*   **Logging**: ELK Stack (Elasticsearch, Logstash, Kibana)
*   **Cluster Maintenance**: Kubernetes Descheduler (manual trigger mode)
*   **DB Management UI**: DBGate (PostgreSQL/Redis/MongoDB)
*   **NoSQL Database**: MongoDB
*   **Secrets Management**: HashiCorp Vault + External Secrets Operator
*   **Automation**: Ansible

> **Note on Nexus**:
>
> *   Jenkins Maven/NPM credentials are now sourced from Vault (`secret/infra/jenkins`) and synced through External Secrets.
> *   **Setup Required**:
>     1.  Login to Nexus (`https://nexus.swirlit.dev`), retrieve admin password: `kubectl exec -n infra deployment/nexus -- cat /nexus-data/admin.password`
>     2.  Create repositories: Maven `maven-public` (Group proxying Central), NPM `npm-group`, Docker hosted on port 5000.
>     3.  Update Vault secret `secret/infra/jenkins` with correct Nexus credentials and allow External Secrets to refresh.

## 🏗 Infrastructure Architecture

The cluster uses Nginx ingress for HTTPS traffic management and namespace isolation (`infra` + `application`).

### Traffic Flow (Platform View)
1.  **Client/Browser** connects to **Nginx Ingress Controller** over HTTPS.
2.  Ingress routes infrastructure hosts (Keycloak, Jenkins, SonarQube, Nexus, GitLab, ArgoCD, Grafana, Kibana, Longhorn, Vault, DBGate).
3.  App traffic routing and app workload manifests are owned by the application repository.

### Secrets Flow (Vault)
1. Vault stores infrastructure secrets under `secret/infra/*`.
2. External Secrets Operator authenticates to Vault using Kubernetes auth.
3. `ExternalSecret` resources sync Vault values into namespace-scoped Kubernetes Secrets consumed by workloads.
4. No credential values are stored in repository YAML.

### Centralized Logging (ELK Stack)
*   **Logstash** collects logs from:
    *   **TCP input** (port 5000): application logs (JSON).
    *   **Kafka input**: order events from `order_topic` and `order_result_topic`.
*   **Elasticsearch** stores logs in `app-logs-*` indices.
*   **Kibana** provides search/visualization (`https://kibana.swirlit.dev`).

## 📦 Current Deployment

### Service Access

> Ingress public IP: **`51.68.232.240`**  
> Internal ClusterIP values below reflect the current cluster state and may change if services are recreated.

#### Infrastructure Services

| Service | Endpoint | Access | Use |
|---------|----------|--------|-----|
| **GitLab** | `https://gitlab.swirlit.dev` | Public | Source code hosting and Git remote (`root` + initial password from pod) |
| **Jenkins** | `https://jenkins.swirlit.dev` | Public | CI/CD pipelines |
| **ArgoCD** | `https://argocd.swirlit.dev` | Public | GitOps sync and app delivery |
| **Nexus** | `https://nexus.swirlit.dev` | Public | Artifact repository |
| **SonarQube** | `https://sonarqube.swirlit.dev` | Public | Code quality and static analysis |
| **Keycloak** | `https://keycloak.swirlit.dev` | Public | OIDC provider (admin credential from Vault) |
| **Grafana** | `https://grafana.swirlit.dev` | Public | Dashboards and monitoring UI |
| **Kibana** | `https://kibana.swirlit.dev` | Public | Log search and visualization |
| **Longhorn UI** | `https://longhorn.swirlit.dev` | Public | Persistent volume management |
| **Vault** | `https://vault.swirlit.dev` | Public | Secrets manager (source of truth for infrastructure credentials) |
| **DBGate** | `https://dbgate.swirlit.dev` | Public | Web DB admin for PostgreSQL, Redis, and MongoDB |
| **PostgreSQL** | `10.43.129.209:5432` | Internal | Primary DB, also used for Keycloak |
| **MongoDB** | `mongodb.infra.svc.cluster.local:27017` | Internal | Document database for infrastructure/application workloads |
| **Redis** | `10.43.206.215:6379` | Internal | Cache backend for application services |
| **Kafka** | `kafka.infra.svc.cluster.local:9092` | Internal | Event bus |
| **Zookeeper** | `zookeeper.infra.svc.cluster.local:2181` | Internal | Coordination service for Kafka |
| **Elasticsearch** | `10.43.167.56:9200` | Internal | Log storage/indexing backend |
| **Logstash** | `10.43.57.31:5000` | Internal | Log/event ingestion pipeline |
| **Prometheus** | `10.43.43.138:9090` | Internal | Metrics scraping and storage |
| **Ingress (NGINX)** | `51.68.232.240:443` | Public | HTTPS entrypoint and host/path routing |

### K8s Namespaces

| Namespace | Contents |
|-----------|----------|
| `infra` | PostgreSQL, MongoDB, Kafka, Zookeeper, Redis, Keycloak, Prometheus, Grafana, Jenkins, SonarQube, Nexus, GitLab, ArgoCD, Vault, External Secrets Operator, Nginx Ingress, ELK (Elasticsearch, Logstash, Kibana), DBGate, Descheduler addon |
| `application` | Application services (owned/deployed from the application repo) |
| `longhorn-system` | Longhorn storage manager |

## 🚀 Quick Start (Fresh Server)

### Prerequisites
- Ubuntu 22.04+ server with 8+ CPUs, 16+ GB RAM, 100+ GB disk
- Sudo access

### Automated Installation (Recommended)

Use the combined one-click script:

```bash
chmod +x install-infrastructure.sh
chmod +x scripts/configure-vault.sh scripts/configure-node-security.sh
./install-infrastructure.sh
```

The installer now asks whether the host is internet-exposed or local-only. Internet-exposed servers automatically get the host security suite (UFW, Fail2ban, CrowdSec with the nftables firewall bouncer, Lynis); local-only servers skip it. The remaining installer prompts still run feature-by-feature (prereqs, K3s, Longhorn, ingress, Vault/ESO, data stores, platform services including DBGate, Descheduler addon, ArgoCD).

### Manual Installation

#### 1. Install System Dependencies
```bash
sudo apt install -y openjdk-21-jdk maven docker.io ansible open-iscsi nfs-common curl jq openssl
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
sudo usermod -aG docker $USER
sudo systemctl enable --now iscsid
```

#### 1.1 Apply Host Security Tooling (Recommended for Internet-Exposed Servers)
```bash
chmod +x scripts/configure-node-security.sh
./scripts/configure-node-security.sh --apply --server-exposure internet
```

This config is written directly by the script: Fail2ban uses the `systemd` backend with UFW actions for `sshd`, and CrowdSec uses the nftables firewall bouncer with local API credentials generated or preserved on the host.

#### 2. Install Kubernetes
```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

#### 3. Install Helm & Longhorn
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace \
    --set defaultSettings.defaultReplicaCount=1
kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

#### 4. Install Nginx Ingress (Helm)
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace infra --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.enableHttp=true
```

#### 5. Deploy Infrastructure
```bash
kubectl create namespace infra

# Create TLS secret for infrastructure ingress
kubectl create secret tls swirlit-dev-tls --cert=tls.crt --key=tls.key -n infra --dry-run=client -o yaml | kubectl apply -f -

# Install Vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault hashicorp/vault -n infra \
    --set injector.enabled=false \
    --set server.ha.enabled=true \
    --set server.ha.raft.enabled=true \
    --set server.ha.replicas=1 \
    --set server.dataStorage.storageClass=longhorn
# Includes Vault ingress/RBAC + ExternalSecrets + auto-unseal CronJob resources
kubectl apply -f deployments/vault.yaml

# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets -n infra --set installCRDs=true

# Configure Vault and seed secret values
chmod +x scripts/configure-vault.sh
./scripts/configure-vault.sh infra

for f in postgres kafka redis mongodb keycloak monitoring elk jenkins sonarqube nexus gitlab dbgate ingress; do
    kubectl apply -f deployments/${f}.yaml
done

# Install descheduler addon resources (policy + RBAC only, no automatic run)
kubectl apply -f deployments/descheduler.yaml
```

#### 6. Install ArgoCD (Helm)
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n infra \
    --set server.service.type=ClusterIP \
    --set configs.params."server\.insecure"=true \
    --set redis.enabled=true
```

## 🔧 Post-Install Checklist (Infrastructure)

### 1. DNS Records in Cloudflare (Required)
Create these DNS records in your Cloudflare zone, all pointing to `51.68.232.240`:

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| A | `keycloak` | `51.68.232.240` | Proxied |
| A | `jenkins` | `51.68.232.240` | Proxied |
| A | `sonarqube` | `51.68.232.240` | Proxied |
| A | `nexus` | `51.68.232.240` | Proxied |
| A | `gitlab` | `51.68.232.240` | Proxied |
| A | `argocd` | `51.68.232.240` | Proxied |
| A | `grafana` | `51.68.232.240` | Proxied |
| A | `kibana` | `51.68.232.240` | Proxied |
| A | `longhorn` | `51.68.232.240` | Proxied |
| A | `vault` | `51.68.232.240` | Proxied |
| A | `dbgate` | `51.68.232.240` | Proxied |

### 2. Replace Temporary Self-Signed Cert with Cloudflare Origin Certificate
The scripts create `swirlit-dev-tls` automatically with a self-signed cert. Replace it with Cloudflare Origin cert:

1. Cloudflare Dashboard → **SSL/TLS** → **Origin Server** → **Create Certificate**
2. Hostnames: `keycloak.swirlit.dev`, `jenkins.swirlit.dev`, `sonarqube.swirlit.dev`, `nexus.swirlit.dev`, `gitlab.swirlit.dev`, `argocd.swirlit.dev`, `grafana.swirlit.dev`, `kibana.swirlit.dev`, `longhorn.swirlit.dev`, `vault.swirlit.dev`, `dbgate.swirlit.dev`, `*.swirlit.dev`
3. Save certificate and private key as local files (`tls.crt`, `tls.key`)
4. Apply them:

```bash
kubectl create secret tls swirlit-dev-tls --cert=tls.crt --key=tls.key -n infra --dry-run=client -o yaml | kubectl apply -f -
```

5. In Cloudflare SSL/TLS mode, select **Full (strict)**

### 3. Jenkins Setup (Required for CI/CD)
```bash
# Get initial admin password
kubectl exec -n infra deployment/jenkins -- cat /var/jenkins_home/secrets/initialAdminPassword

# Access Jenkins at https://jenkins.swirlit.dev
# 1. Install suggested plugins + "Kubernetes" plugin
# 2. Configure Kubernetes cloud:
#    - Manage Jenkins → Clouds → New Cloud → Kubernetes
#    - Kubernetes URL: https://kubernetes.default.svc
#    - Jenkins URL: http://jenkins.infra.svc.cluster.local:8080
#    - Jenkins tunnel: jenkins.infra.svc.cluster.local:50000
#    - Namespace: infra
# 3. Create a Pipeline job pointing to app repo
#    - SCM: Git → <application-repository-url>
#    - Script Path: Jenkinsfile
```

### 4. GitLab Setup (SCM)
```bash
# Access GitLab at https://gitlab.swirlit.dev
# First startup can take several minutes
kubectl wait --for=condition=ready pod -n infra -l app=gitlab --timeout=1200s

# Get initial root password (username is: root)
kubectl exec -n infra deployment/gitlab -- awk '/Password:/ {print $2}' /etc/gitlab/initial_root_password
```

### 5. ArgoCD Setup (GitOps)
```bash
# Get initial admin password
kubectl -n infra get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access ArgoCD at https://argocd.swirlit.dev
# Login with admin / <password from above>
# Two applications are pre-configured:
#   - Infrastructure application definitions are managed from the application repository
# ArgoCD auto-syncs on git push (self-heal enabled)
```

### 6. Rotate Infrastructure Secrets in Vault (Security)
```bash
# Read Vault root token (created by scripts/configure-vault.sh)
export VAULT_TOKEN="$(kubectl get secret -n infra vault-init -o jsonpath='{.data.root_token}' | base64 -d)"
export VAULT_ADDR="http://127.0.0.1:8200"
kubectl port-forward -n infra svc/vault-ui 8200:8200

# Rotate examples (run in another terminal with VAULT_ADDR/VAULT_TOKEN set)
vault kv patch secret/infra/postgres username='<NEW_USERNAME>' password='<NEW_PASSWORD>'
vault kv patch secret/infra/mongodb root_password='<NEW_PASSWORD>'
vault kv patch secret/infra/grafana admin_password='<NEW_PASSWORD>'
vault kv patch secret/infra/keycloak admin_password='<NEW_PASSWORD>'
```

### 7. Initial Credential Retrieval (Per Service)

Use this table for first-time setup credentials for every service that requires authentication:

| Service | Username (first login) | Password / Token retrieval | Notes |
|---|---|---|---|
| Vault | `root` token only | `base64 --decode <<< "$(kubectl get secret -n infra vault-init -o jsonpath='{.data.root_token}')" && echo` | Use token to login, create scoped tokens, then stop using root token. |
| PostgreSQL | `base64 --decode <<< "$(kubectl get secret -n infra postgres-secret -o jsonpath='{.data.POSTGRES_USER}')" && echo` | `base64 --decode <<< "$(kubectl get secret -n infra postgres-secret -o jsonpath='{.data.POSTGRES_PASSWORD}')" && echo` | Vault-backed via External Secrets. |
| MongoDB | `base64 --decode <<< "$(kubectl get secret -n infra mongodb-secret -o jsonpath='{.data.MONGO_INITDB_ROOT_USERNAME}')" && echo` | `base64 --decode <<< "$(kubectl get secret -n infra mongodb-secret -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}')" && echo` | Vault-backed via External Secrets. |
| Keycloak | `base64 --decode <<< "$(kubectl get secret -n infra keycloak-admin-secret -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}')" && echo` | `base64 --decode <<< "$(kubectl get secret -n infra keycloak-admin-secret -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}')" && echo` | Rotate after first login. |
| Grafana | `admin` | `base64 --decode <<< "$(kubectl get secret -n infra grafana-admin-secret -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}')" && echo` | Vault-backed via External Secrets. |
| Jenkins | `admin` | `kubectl exec -n infra deployment/jenkins -- cat /var/jenkins_home/secrets/initialAdminPassword` | Password is generated by Jenkins on first startup. |
| Nexus | `admin` | `kubectl exec -n infra deployment/nexus -- cat /nexus-data/admin.password` | Password file exists until changed. |
| GitLab | `root` | `kubectl exec -n infra deployment/gitlab -- awk '/Password:/ {print $2}' /etc/gitlab/initial_root_password` | Initial file can expire/rotate; set a permanent password. |
| DBGate | `base64 --decode <<< "$(kubectl get secret -n infra dbgate-auth-secret -o jsonpath='{.data.LOGIN}')" && echo` | `base64 --decode <<< "$(kubectl get secret -n infra dbgate-auth-secret -o jsonpath='{.data.PASSWORD}')" && echo` | DBGate is preconfigured with PostgreSQL, Redis, and MongoDB connections. |
| ArgoCD | `admin` | `base64 --decode <<< "$(kubectl -n infra get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')" && echo` | Delete/rotate initial secret after onboarding. |
| SonarQube | `admin` | `admin` | Default bootstrap credentials are static; change immediately after first login. |

### 8. Trigger Descheduler Manually

Descheduler is installed in **manual trigger mode only** (no CronJob and no always-running Deployment).  
Configured strategies: `LowNodeUtilization` and `RemoveDuplicates`.

```bash
# Launch a one-off descheduler run
kubectl create -f deployments/descheduler-run-job.yaml

# Watch completion
kubectl get jobs -n infra -l app=descheduler -w
```

## 🔀 Adding More Nodes

K8s makes it easy to scale horizontally:

```bash
# On the master node, get control-plane IP:
hostname -I | awk '{print $1}'

# On the master node, get the join token:
sudo cat /var/lib/rancher/k3s/server/node-token

# On the new worker node:
curl -sfL https://get.k3s.io | K3S_URL=https://<MASTER_NODE_IP>:6443 K3S_TOKEN=<TOKEN_FROM_MASTER> sh -

# Longhorn will automatically replicate data to new nodes.
# Increase replica count:
kubectl edit settings -n longhorn-system default-replica-count
# Change from 1 to 2 (or 3 for 3+ nodes)
```

## 🔒 Host Security Baseline

- Internet-exposed servers automatically install and configure UFW, Fail2ban, CrowdSec with the nftables bouncer, and Lynis via `scripts/configure-node-security.sh`.
- Local-only servers skip that internet-facing host security suite.
- Keep only required public ports open (`22`, `80`, `443`, `6443`, plus node-internal overlay ports).
- Rotate Vault-stored secrets regularly and restart workloads that consume rotated credentials.
- Keep Kubernetes/Helm chart versions updated and avoid running long-lived default credentials.

## 📊 Monitoring & Logging

- **Prometheus** scrapes metrics from application services.
- **Grafana** connects to Prometheus and Elasticsearch datasources (auto-provisioned). Import Spring Boot dashboard ID `12900` for JVM metrics.
- **ELK Stack**: Application logs are shipped to Logstash, stored in Elasticsearch, and searchable via Kibana.
- **Kibana**: Access at `https://kibana.swirlit.dev`. Create index pattern `app-logs-*` to browse logs.

## 🔄 Deployment Methods: Script vs Ansible

### Combined Script (`install-infrastructure.sh`)
**Best for**: Fresh bare-metal installs, single-server setups, quick bootstrapping.  
This single script performs both prerequisite installation and infrastructure deployment.

### Ansible (`ansible/deploy.yml`)
**Best for**: Multi-node deployments, repeatable provisioning, team environments.

```bash
ansible-playbook ansible/deploy.yml

# Local-only host (skips UFW, Fail2ban, CrowdSec, Lynis automation)
ansible-playbook ansible/deploy.yml -e server_exposure=local
```

Ansible excels when managing multiple servers (inventory-based), enforcing idempotent state, and integrating with existing automation.

## License
GPL 3.0
