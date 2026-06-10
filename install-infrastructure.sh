#!/bin/bash
# ==============================================================================
# install-infrastructure.sh
# Installs prerequisites and deploys infra components
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$SCRIPT_DIR/deployments"
VAULT_BOOTSTRAP_SCRIPT="$SCRIPT_DIR/scripts/configure-vault.sh"
SECURITY_HARDEN_SCRIPT="$SCRIPT_DIR/scripts/configure-node-security.sh"
AUTO_APPROVE=false
SERVER_IP="${SERVER_IP:-51.68.232.240}"
SERVER_EXPOSURE="${SERVER_EXPOSURE:-internet}"

for arg in "$@"; do
    case "$arg" in
        -y|--yes|--auto-approve)
            AUTO_APPROVE=true
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--yes]"
            exit 1
            ;;
    esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

ask_with_default() {
    local prompt="$1"
    local default_choice="${2:-N}"
    local answer="" suffix=""

    if [[ "$default_choice" == "Y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    if [[ "$AUTO_APPROVE" == "true" ]]; then
        [[ "$default_choice" == "Y" ]]
        return
    fi

    read -rp "$(echo -e "${YELLOW}$prompt $suffix${NC} ")" answer
    answer="${answer:-$default_choice}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

normalize_server_exposure() {
    local exposure="${1,,}"

    case "$exposure" in
        internet|internet-exposed|public|external)
            echo "internet"
            ;;
        local|local-only|private|internal|lan)
            echo "local"
            ;;
        *)
            return 1
            ;;
    esac
}

ask_server_exposure() {
    local default_exposure raw_answer normalized
    default_exposure="$(normalize_server_exposure "$1")" || error "Invalid SERVER_EXPOSURE value: $1"

    if [[ "$AUTO_APPROVE" == "true" ]]; then
        echo "$default_exposure"
        return 0
    fi

    while true; do
        read -rp "$(echo -e "${YELLOW}Will this server be internet-exposed or local-only? [internet/local]${NC} ")" raw_answer
        raw_answer="${raw_answer:-$default_exposure}"
        if normalized="$(normalize_server_exposure "$raw_answer")"; then
            echo "$normalized"
            return 0
        fi
        warn "Please answer 'internet' or 'local'."
    done
}

ensure_tls_secret() {
    local namespace="$1"
    local secret_name="$2"
    shift 2
    local domains=("$@")

    if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
        warn "TLS secret '$secret_name' already exists in namespace '$namespace', reusing it."
        return 0
    fi

    local tmpdir openssl_config cert key
    tmpdir="$(mktemp -d)"
    openssl_config="$tmpdir/openssl.cnf"
    cert="$tmpdir/tls.crt"
    key="$tmpdir/tls.key"

    {
        echo "[req]"
        echo "distinguished_name = req_distinguished_name"
        echo "x509_extensions = v3_req"
        echo "prompt = no"
        echo ""
        echo "[req_distinguished_name]"
        echo "CN = ${domains[0]}"
        echo ""
        echo "[v3_req]"
        echo "subjectAltName = @alt_names"
        echo ""
        echo "[alt_names]"
        local i=1
        for domain in "${domains[@]}"; do
            echo "DNS.$i = $domain"
            i=$((i + 1))
        done
    } > "$openssl_config"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key" \
        -out "$cert" \
        -config "$openssl_config" >/dev/null 2>&1

    kubectl create secret tls "$secret_name" \
        --cert="$cert" \
        --key="$key" \
        -n "$namespace" >/dev/null

    rm -rf "$tmpdir"
    info "Created TLS secret '$secret_name' in namespace '$namespace'."
}

check_dns_records() {
    local hosts=(
        "keycloak.swirlit.dev"
        "jenkins.swirlit.dev"
        "sonarqube.swirlit.dev"
        "nexus.swirlit.dev"
        "argocd.swirlit.dev"
        "grafana.swirlit.dev"
        "kibana.swirlit.dev"
        "gitlab.swirlit.dev"
        "longhorn.swirlit.dev"
        "vault.swirlit.dev"
        "dbgate.swirlit.dev"
    )

    for host in "${hosts[@]}"; do
        local resolved
        resolved="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1 || true)"
        if [[ "$resolved" != "$SERVER_IP" ]]; then
            warn "DNS check: $host -> ${resolved:-<missing>} (expected $SERVER_IP)"
        fi
    done
}

# ---------- Combined pre-flight checks -----------------------------------------
[[ $EUID -eq 0 ]] && error "Do not run as root. The script uses sudo when needed."

info "============================================="
info " Infrastructure Installer"
info "============================================="
echo ""
echo "This script will:"
echo "  - Prompt you for each install feature group one by one"
echo "  - Install only selected components"
echo "  - Apply host security tooling automatically for internet-exposed servers"
echo ""

ask_with_default "Proceed with installation and deployment?" "Y" || { info "Aborted."; exit 0; }

step "Select features to install (answer each prompt)"
SERVER_EXPOSURE="$(ask_server_exposure "$SERVER_EXPOSURE")"
if [[ "$SERVER_EXPOSURE" == "internet" ]]; then
    APPLY_HOST_SECURITY=true
    info "Internet-exposed mode selected: enabling UFW, Fail2ban, CrowdSec, and Lynis."
else
    APPLY_HOST_SECURITY=false
    info "Local-only mode selected: skipping internet-facing host security tooling."
fi

if command -v k3s &>/dev/null; then
    warn "K3s detected: $(k3s --version | head -1)"
    K3S_DEFAULT="N"
else
    K3S_DEFAULT="Y"
fi

ask_with_default "Install/upgrade system prerequisites (Java/Maven/Docker/Ansible/Node/etc.)?" "Y" && INSTALL_PREREQS=true || INSTALL_PREREQS=false
ask_with_default "Install or reinstall K3s control plane?" "$K3S_DEFAULT" && INSTALL_K3S=true || INSTALL_K3S=false
ask_with_default "Install/upgrade Longhorn and make it default storage class?" "Y" && INSTALL_LONGHORN=true || INSTALL_LONGHORN=false
ask_with_default "Install/upgrade NGINX ingress controller?" "Y" && INSTALL_INGRESS=true || INSTALL_INGRESS=false
ask_with_default "Install/upgrade Vault + External Secrets and bootstrap secrets?" "Y" && INSTALL_VAULT_STACK=true || INSTALL_VAULT_STACK=false
ask_with_default "Deploy/upgrade core data stores (Postgres, Kafka, Redis, MongoDB)?" "Y" && DEPLOY_DATA_STORES=true || DEPLOY_DATA_STORES=false
ask_with_default "Deploy/upgrade platform services (Keycloak, monitoring, ELK, Jenkins, SonarQube, Nexus, GitLab, DBGate, ingress rules)?" "Y" && DEPLOY_PLATFORM_SERVICES=true || DEPLOY_PLATFORM_SERVICES=false
ask_with_default "Install/upgrade Descheduler addon resources (manual trigger only)?" "Y" && INSTALL_DESCHEDULER=true || INSTALL_DESCHEDULER=false
ask_with_default "Install/upgrade ArgoCD?" "Y" && INSTALL_ARGOCD=true || INSTALL_ARGOCD=false

if [[ "$DEPLOY_PLATFORM_SERVICES" == "true" && "$DEPLOY_DATA_STORES" != "true" ]]; then
    warn "Platform services depend on data stores; enabling data store deployment."
    DEPLOY_DATA_STORES=true
fi

if [[ "$DEPLOY_DATA_STORES" == "true" && "$INSTALL_VAULT_STACK" != "true" ]]; then
    warn "Data stores require Vault-synced secrets; enabling Vault + External Secrets install."
    INSTALL_VAULT_STACK=true
fi

RUN_K8S_FEATURES=false
if [[ "$INSTALL_K3S" == "true" || "$INSTALL_LONGHORN" == "true" || "$INSTALL_INGRESS" == "true" || "$INSTALL_VAULT_STACK" == "true" || "$DEPLOY_DATA_STORES" == "true" || "$DEPLOY_PLATFORM_SERVICES" == "true" || "$INSTALL_DESCHEDULER" == "true" || "$INSTALL_ARGOCD" == "true" ]]; then
    RUN_K8S_FEATURES=true
fi

NEEDS_HELM=false
if [[ "$INSTALL_LONGHORN" == "true" || "$INSTALL_INGRESS" == "true" || "$INSTALL_VAULT_STACK" == "true" || "$INSTALL_ARGOCD" == "true" ]]; then
    NEEDS_HELM=true
fi

# ---------- Prerequisites section ----------------------------------------------
if [[ "$INSTALL_PREREQS" == "true" ]]; then
    step "Installing system prerequisites..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        openjdk-21-jdk \
        maven \
        docker.io \
        ansible \
        open-iscsi \
        nfs-common \
        curl \
        jq \
        git \
        openssl \
        > /dev/null

    if ! command -v node &>/dev/null || [[ "$(node -v)" != v24* ]]; then
        info "Installing Node.js 24..."
        curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - > /dev/null 2>&1
        sudo apt-get install -y -qq nodejs > /dev/null
    fi

    if ! groups "$USER" | grep -q docker; then
        info "Adding $USER to docker group (re-login required for non-sudo docker)..."
        sudo usermod -aG docker "$USER"
    fi

    sudo systemctl enable --now iscsid > /dev/null 2>&1

    export MAVEN_OPTS="-Dhttp.proxyHost= -Dhttps.proxyHost="
    grep -q "MAVEN_OPTS" ~/.bashrc 2>/dev/null || \
        echo 'export MAVEN_OPTS="-Dhttp.proxyHost= -Dhttps.proxyHost="' >> ~/.bashrc
else
    warn "Skipping system prerequisites."
fi

if [[ "$RUN_K8S_FEATURES" == "true" ]]; then
    if [[ "$INSTALL_K3S" == "true" ]]; then
        info "Installing K3s (disabling Traefik, using Nginx Ingress instead)..."
        curl -sfL https://get.k3s.io | sh -s - \
            --disable traefik \
            --write-kubeconfig-mode 644
    fi

    if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
        mkdir -p ~/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
        sudo chown "$USER":"$USER" ~/.kube/config
    fi
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    grep -q "KUBECONFIG" ~/.bashrc 2>/dev/null || \
        echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
fi

if [[ "$NEEDS_HELM" == "true" ]] && ! command -v helm &>/dev/null; then
    info "Installing Helm 3..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash > /dev/null 2>&1
fi

if [[ "$APPLY_HOST_SECURITY" == "true" ]]; then
    if [[ -x "$SECURITY_HARDEN_SCRIPT" ]]; then
        step "Applying host security tooling for internet-exposed server..."
        "$SECURITY_HARDEN_SCRIPT" --apply --server-exposure "$SERVER_EXPOSURE"
    else
        warn "Host security script not found at $SECURITY_HARDEN_SCRIPT"
    fi
fi

# ---------- Infrastructure section ---------------------------------------------
if [[ "$RUN_K8S_FEATURES" == "true" ]]; then
    command -v kubectl &>/dev/null || error "kubectl not found."
    command -v openssl &>/dev/null || error "openssl not found."
    kubectl cluster-info &>/dev/null || error "Cannot reach K8s cluster."
    [[ "$NEEDS_HELM" != "true" ]] || command -v helm &>/dev/null || error "helm not found."

    if [[ "$INSTALL_K3S" == "true" ]]; then
        kubectl wait --for=condition=Ready node --all --timeout=120s
    fi

    step "Creating infra namespace..."
    kubectl create namespace infra 2>/dev/null || true

    if [[ "$SERVER_EXPOSURE" == "internet" ]]; then
        step "Publishing host security policy record..."
        kubectl apply -f "$DEPLOY_DIR/host-security-config.yaml"
    fi

    if [[ "$INSTALL_INGRESS" == "true" || "$INSTALL_VAULT_STACK" == "true" || "$DEPLOY_PLATFORM_SERVICES" == "true" ]]; then
        step "Ensuring HTTPS TLS secret..."
        ensure_tls_secret infra swirlit-dev-tls \
            keycloak.swirlit.dev \
            jenkins.swirlit.dev \
            sonarqube.swirlit.dev \
            nexus.swirlit.dev \
            argocd.swirlit.dev \
            grafana.swirlit.dev \
            kibana.swirlit.dev \
            gitlab.swirlit.dev \
            longhorn.swirlit.dev \
            vault.swirlit.dev \
            dbgate.swirlit.dev
    fi

    if [[ "$INSTALL_LONGHORN" == "true" ]]; then
        if helm list -n longhorn-system 2>/dev/null | grep -q longhorn; then
            warn "Longhorn already installed, keeping existing release."
        else
            step "Installing Longhorn..."
            helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
            helm repo update > /dev/null 2>&1
            helm install longhorn longhorn/longhorn \
                --namespace longhorn-system \
                --create-namespace \
                --set defaultSettings.defaultReplicaCount=1 \
                --wait --timeout 300s
        fi

        kubectl patch storageclass longhorn -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
        kubectl patch storageclass local-path -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
        kubectl wait --for=condition=ready pod -l app=longhorn-manager \
            -n longhorn-system --timeout=180s
    fi

    if [[ "$INSTALL_INGRESS" == "true" ]]; then
        step "Installing Nginx Ingress Controller..."
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        if helm list -n infra 2>/dev/null | grep -q ingress-nginx; then
            helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
                --namespace infra \
                --set controller.service.type=LoadBalancer \
                --set controller.service.enableHttp=true \
                --wait --timeout 120s
        else
            helm install ingress-nginx ingress-nginx/ingress-nginx \
                --namespace infra \
                --set controller.service.type=LoadBalancer \
                --set controller.service.enableHttp=true \
                --wait --timeout 120s
        fi
    fi

    if [[ "$INSTALL_VAULT_STACK" == "true" ]]; then
        step "Installing HashiCorp Vault..."
        helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install vault hashicorp/vault \
            --namespace infra \
            --set injector.enabled=false \
            --set server.ha.enabled=true \
            --set server.ha.raft.enabled=true \
            --set server.ha.replicas=1 \
            --set server.dataStorage.storageClass=longhorn

        step "Installing External Secrets Operator..."
        helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install external-secrets external-secrets/external-secrets \
            --namespace infra \
            --set installCRDs=true \
            --wait --timeout 300s

        step "Applying unified Vault manifests (ingress, RBAC, secret sync, auto-unseal)..."
        kubectl apply -f "$DEPLOY_DIR/vault.yaml"

        kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 -n infra --timeout=300s
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets -n infra --timeout=180s

        [[ -x "$VAULT_BOOTSTRAP_SCRIPT" ]] || chmod +x "$VAULT_BOOTSTRAP_SCRIPT"
        step "Bootstrapping Vault auth/policies and seeding secrets..."
        "$VAULT_BOOTSTRAP_SCRIPT" infra

        for es in postgres-secret mongodb-secret sonarqube-db-credentials grafana-admin-secret keycloak-admin-secret keycloak-realm-config jenkins-maven-settings jenkins-npm-config dbgate-auth-secret; do
            kubectl wait --for=condition=Ready externalsecret/"$es" -n infra --timeout=180s 2>/dev/null || warn "ExternalSecret '$es' is still reconciling."
        done
    fi

    if [[ "$DEPLOY_DATA_STORES" == "true" ]]; then
        step "Deploying core data stores..."
        kubectl apply -f "$DEPLOY_DIR/postgres.yaml"
        kubectl apply -f "$DEPLOY_DIR/kafka.yaml"
        kubectl apply -f "$DEPLOY_DIR/redis.yaml"
        kubectl apply -f "$DEPLOY_DIR/mongodb.yaml"

        kubectl wait --for=condition=ready pod -l app=postgres  -n infra --timeout=180s
        kubectl wait --for=condition=ready pod -l app=redis     -n infra --timeout=120s
        kubectl wait --for=condition=ready pod -l app=mongodb   -n infra --timeout=180s
        kubectl wait --for=condition=ready pod -l app=zookeeper -n infra --timeout=180s
        kubectl wait --for=condition=ready pod -l app=kafka     -n infra --timeout=180s
    fi

    if [[ "$DEPLOY_PLATFORM_SERVICES" == "true" ]]; then
        step "Deploying platform services..."
        for f in keycloak.yaml monitoring.yaml elk.yaml jenkins.yaml sonarqube.yaml nexus.yaml gitlab.yaml dbgate.yaml ingress.yaml; do
            kubectl apply -f "$DEPLOY_DIR/$f"
        done

        kubectl wait --for=condition=ready pod -l app=keycloak      -n infra --timeout=180s 2>/dev/null || warn "Keycloak still starting..."
        kubectl wait --for=condition=ready pod -l app=jenkins        -n infra --timeout=180s 2>/dev/null || warn "Jenkins still starting..."
        kubectl wait --for=condition=ready pod -l app=elasticsearch  -n infra --timeout=180s 2>/dev/null || warn "Elasticsearch still starting..."
        kubectl wait --for=condition=ready pod -l app=kibana         -n infra --timeout=180s 2>/dev/null || warn "Kibana still starting..."
        kubectl wait --for=condition=ready pod -l app=logstash       -n infra --timeout=180s 2>/dev/null || warn "Logstash still starting..."
        kubectl wait --for=condition=ready pod -l app=gitlab         -n infra --timeout=900s 2>/dev/null || warn "GitLab still starting..."
        kubectl wait --for=condition=ready pod -l app=dbgate         -n infra --timeout=180s 2>/dev/null || warn "DBGate still starting..."
    fi

    if [[ "$INSTALL_DESCHEDULER" == "true" ]]; then
        step "Installing Descheduler addon resources (manual-run mode)..."
        kubectl apply -f "$DEPLOY_DIR/descheduler.yaml"
    fi

    if [[ "$INSTALL_ARGOCD" == "true" ]]; then
        step "Installing ArgoCD..."
        if helm list -n infra 2>/dev/null | grep -q argocd; then
            helm upgrade argocd argo/argo-cd \
                --namespace infra \
                --set server.service.type=ClusterIP \
                --set configs.params."server\\.insecure"=true \
                --set redis.enabled=true \
                --wait --timeout 300s
        else
            helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
            helm repo update > /dev/null 2>&1
            helm install argocd argo/argo-cd \
                --namespace infra \
                --set server.service.type=ClusterIP \
                --set configs.params."server\\.insecure"=true \
                --set redis.enabled=true \
                --wait --timeout 300s
        fi
    fi
else
    warn "All Kubernetes feature groups were skipped."
fi

info ""
info "============================================="
info " Infrastructure installation complete!"
info "============================================="

echo ""
echo "Installed versions:"
command -v java >/dev/null 2>&1 && echo "  Java: $(java -version 2>&1 | head -1)"
command -v mvn >/dev/null 2>&1 && echo "  Maven: $(mvn -version 2>&1 | head -1)"
command -v node >/dev/null 2>&1 && echo "  Node: $(node -v)"
command -v docker >/dev/null 2>&1 && echo "  Docker: $(docker --version)"
if command -v helm >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    LONGHORN_VERSION="$(helm list -n longhorn-system -o json 2>/dev/null | jq -r '.[0].app_version // "unknown"')"
    echo "  Longhorn: ${LONGHORN_VERSION}"
fi
echo ""
if [[ "$RUN_K8S_FEATURES" == "true" ]]; then
    echo "Service access (HTTPS via domain):"
    echo "  Keycloak   https://keycloak.swirlit.dev"
    echo "  Jenkins    https://jenkins.swirlit.dev"
    echo "  SonarQube  https://sonarqube.swirlit.dev"
    echo "  Grafana    https://grafana.swirlit.dev"
    echo "  Nexus      https://nexus.swirlit.dev"
    echo "  ArgoCD     https://argocd.swirlit.dev"
    echo "  Kibana     https://kibana.swirlit.dev"
    echo "  GitLab     https://gitlab.swirlit.dev"
    echo "  Longhorn   https://longhorn.swirlit.dev"
    echo "  Vault      https://vault.swirlit.dev"
    echo "  DBGate     https://dbgate.swirlit.dev"
    echo ""
    echo "Expected DNS target IP: $SERVER_IP"
    check_dns_records

    echo ""
    echo "Retrieve credentials:"
    echo "  Jenkins:  kubectl exec -n infra deployment/jenkins -- cat /var/jenkins_home/secrets/initialAdminPassword"
    echo "  ArgoCD:   kubectl -n infra get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo "  Nexus:    kubectl exec -n infra deployment/nexus -- cat /nexus-data/admin.password"
    echo "  GitLab:   kubectl exec -n infra deployment/gitlab -- grep 'Password:' /etc/gitlab/initial_root_password"
    echo "  MongoDB:  kubectl get secret -n infra mongodb-secret -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d"
    echo "  Vault:    kubectl get secret -n infra vault-init -o jsonpath='{.data.root_token}' | base64 -d"
    echo "  DBGate:   kubectl get secret -n infra dbgate-auth-secret -o go-template='{{printf \"%s\" (index .data \"LOGIN\" | base64decode)}}:{{printf \"%s\" (index .data \"PASSWORD\" | base64decode)}}'"
    echo "  Descheduler trigger: kubectl create -f deployments/descheduler-run-job.yaml"
    echo ""

    echo "Pod status:"
    kubectl get pods -n infra --no-headers 2>&1 | awk '{printf "  %-50s %s\n", $1, $2}'
fi
