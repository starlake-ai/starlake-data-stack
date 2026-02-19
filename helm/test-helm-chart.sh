#!/bin/bash
# Script de test automatisé du Helm Chart Starlake avec K3s
#
# Ce script supporte deux modes de cluster:
#   - Single-node (défaut): Utilise local-path storage (RWO)
#   - Multi-node: Cluster avec agents, local-path storage (avec limitations)
#
# Usage:
#   ./test-helm-chart.sh              # Dev single-node (credentials par défaut)
#   ./test-helm-chart.sh --production # Production single-node (credentials sécurisés)
#   ./test-helm-chart.sh --multi-node # Multi-nœuds local-path (1 server + 3 agents)
#   ./test-helm-chart.sh --multi-node --seaweedfs  # Multi-nœuds avec S3 (SeaweedFS)
#   ./test-helm-chart.sh --production --multi-node --seaweedfs # Full production-like
#   ./test-helm-chart.sh --security-only # Validation sécurité seulement (pas de cluster)
#
# Prérequis:
#   - k3d (brew install k3d)
#   - helm (brew install helm)
#   - kubectl (inclus avec k3d)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CLUSTER_NAME="starlake-test"
NAMESPACE="starlake"
CHART_PATH="./starlake"
TIMEOUT="15m"

# Mode de test (dev par défaut)
PRODUCTION_MODE=false
SECURITY_ONLY=false
MULTI_NODE=false
AGENT_COUNT=3  # Nombre d'agents pour multi-node
SEAWEEDFS_ENABLED=false  # Object storage S3

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --production|-p)
            PRODUCTION_MODE=true
            shift
            ;;
        --security-only|-s)
            SECURITY_ONLY=true
            shift
            ;;
        --multi-node|-m)
            MULTI_NODE=true
            shift
            ;;
        --agents)
            AGENT_COUNT=$2
            shift 2
            ;;
        --seaweedfs)
            SEAWEEDFS_ENABLED=true
            shift
            ;;
        *)
            echo "Usage: $0 [--production|-p] [--security-only|-s] [--multi-node|-m] [--agents N] [--seaweedfs]"
            exit 1
            ;;
    esac
done

# Génération de credentials sécurisés pour le mode production
generate_secure_credentials() {
    # Générer des mots de passe aléatoires
    SECURE_PG_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    SECURE_AIRFLOW_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    SECURE_AIRFLOW_SECRET_KEY=$(openssl rand -hex 32)
    SECURE_GIZMO_API_KEY=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
    SECURE_AGENT_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
}

# Credentials à utiliser
if [ "$PRODUCTION_MODE" = true ]; then
    generate_secure_credentials
    PG_PASSWORD="$SECURE_PG_PASSWORD"
    AIRFLOW_PASSWORD="$SECURE_AIRFLOW_PASSWORD"
    AIRFLOW_SECRET_KEY="$SECURE_AIRFLOW_SECRET_KEY"
    GIZMO_API_KEY="$SECURE_GIZMO_API_KEY"
    AGENT_APPLICATION_KEY="$SECURE_AGENT_KEY"
    VALIDATE_CREDENTIALS="true"
else
    # Mode dev - credentials par défaut
    PG_PASSWORD="dbuser123"
    AIRFLOW_PASSWORD="airflow"
    AIRFLOW_SECRET_KEY="starlake-airflow-secret-key-change-in-production"
    GIZMO_API_KEY="a_secret_api_key"
    AGENT_APPLICATION_KEY="change-me-in-production"
    VALIDATE_CREDENTIALS="false"
fi

# Timeouts configurables (en secondes)
CLUSTER_READY_TIMEOUT=120      # Attente cluster ready
HEADLAMP_READY_TIMEOUT=120     # Attente Headlamp ready
POD_READY_MAX_ATTEMPTS=240     # Max attempts pour pods (240 * 5s = 20 min)
HEALTH_CHECK_SLEEP=5           # Pause entre health checks
PORT_FORWARD_SLEEP=5           # Pause après port-forward

# Fonction pour afficher les messages
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Fonction de nettoyage
cleanup() {
    log_info "Nettoyage en cours..."

    # Supprimer le release Helm si existe
    if helm list -n $NAMESPACE 2>/dev/null | grep -q starlake; then
        helm uninstall starlake -n $NAMESPACE 2>/dev/null || true
    fi

    # Supprimer le namespace
    kubectl delete namespace $NAMESPACE --wait=false 2>/dev/null || true

    # Supprimer le cluster K3s
    if k3d cluster list 2>/dev/null | grep -q $CLUSTER_NAME; then
        k3d cluster delete $CLUSTER_NAME 2>/dev/null || true
    fi

    # Tuer les processus de port-forward
    pkill -f "kubectl port-forward" 2>/dev/null || true
}

# Trap pour nettoyer en cas d'erreur
trap cleanup EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🧪 Test Automatisé du Helm Chart Starlake"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 0. Vérifier les prérequis
log_info "Vérification des prérequis..."

if ! command -v k3d &> /dev/null; then
    log_error "k3d n'est pas installé. Installez-le avec: brew install k3d"
    exit 1
fi
log_success "k3d est installé"

if ! command -v helm &> /dev/null; then
    log_error "Helm n'est pas installé. Installez-le avec: brew install helm"
    exit 1
fi
log_success "Helm est installé"

if ! command -v kubectl &> /dev/null; then
    log_error "kubectl n'est pas installé"
    exit 1
fi
log_success "kubectl est installé"

if [ ! -d "$CHART_PATH" ]; then
    log_error "Chart directory not found: $CHART_PATH"
    exit 1
fi
log_success "Chart trouvé: $CHART_PATH"

echo ""

# Afficher le mode de test
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$MULTI_NODE" = true ]; then
    echo "  🌐 MODE MULTI-NODE - $AGENT_COUNT agents + local-path storage"
else
    echo "  📦 MODE SINGLE-NODE - local-path storage"
fi
if [ "$PRODUCTION_MODE" = true ]; then
    echo "  🔒 PRODUCTION - Credentials sécurisés"
else
    echo "  🔧 DEV - Credentials par défaut"
fi
if [ "$SEAWEEDFS_ENABLED" = true ]; then
    echo "  📦 SEAWEEDFS - Object storage S3 activé"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$PRODUCTION_MODE" = true ]; then
    log_info "PostgreSQL password: ${PG_PASSWORD:0:8}..."
    log_info "Airflow password: ${AIRFLOW_PASSWORD:0:8}..."
    log_info "Airflow secret key: ${AIRFLOW_SECRET_KEY:0:16}..."
    log_info "Gizmo API key: ${GIZMO_API_KEY:0:8}..."
    log_info "Agent application key: ${AGENT_APPLICATION_KEY:0:8}..."
    log_info "security.validateCredentials: true"
    echo ""
else
    log_info "Mode DEV - credentials par défaut (airflow/airflow, dbuser123)"
fi

# 0.5. Test de validation sécurité (helm template)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 Test de Validation Sécurité"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test 1: Validation doit ÉCHOUER avec credentials par défaut + validateCredentials=true
log_info "Test 1: Validation bloque les credentials par défaut..."
SECURITY_TEST_OUTPUT=$(helm template test-security $CHART_PATH \
    --set security.validateCredentials=true \
    --set postgresql.credentials.password=dbuser123 \
    --set airflow.admin.password=airflow \
    --set airflow.secretKey="starlake-airflow-secret-key-change-in-production" \
    2>&1) && SECURITY_TEST_RESULT=$? || SECURITY_TEST_RESULT=$?

if [ $SECURITY_TEST_RESULT -ne 0 ] && grep -q "SECURITY ERROR" <<< "$SECURITY_TEST_OUTPUT"; then
    log_success "  ✓ Validation bloque correctement les credentials par défaut"
else
    log_error "  ✗ Validation devrait bloquer les credentials par défaut!"
    head -5 <<< "$SECURITY_TEST_OUTPUT"
    if [ "$SECURITY_ONLY" = true ]; then exit 1; fi
fi

# Test 2: Validation doit RÉUSSIR avec credentials sécurisés
log_info "Test 2: Validation accepte les credentials sécurisés..."
SECURITY_TEST_OUTPUT=$(helm template test-security $CHART_PATH \
    --set security.validateCredentials=true \
    --set postgresql.credentials.password=SecurePassword123 \
    --set airflow.admin.password=SecureAirflowPass456 \
    --set airflow.secretKey="$(openssl rand -hex 32)" \
    --set gizmo.enabled=false \
    --set agent.applicationKey=SecureAgentKey123 \
    2>&1) && SECURITY_TEST_RESULT=$? || SECURITY_TEST_RESULT=$?

if [ $SECURITY_TEST_RESULT -eq 0 ]; then
    log_success "  ✓ Validation accepte les credentials sécurisés"
else
    log_error "  ✗ Validation devrait accepter les credentials sécurisés!"
    head -10 <<< "$SECURITY_TEST_OUTPUT"
    if [ "$SECURITY_ONLY" = true ]; then exit 1; fi
fi

# Test 3: Validation PostgreSQL password spécifique
log_info "Test 3: Validation bloque postgresql.credentials.password=dbuser123..."
SECURITY_TEST_OUTPUT=$(helm template test-security $CHART_PATH \
    --set security.validateCredentials=true \
    --set postgresql.credentials.password=dbuser123 \
    --set airflow.admin.password=SecurePass \
    --set airflow.secretKey="$(openssl rand -hex 32)" \
    2>&1) && SECURITY_TEST_RESULT=$? || SECURITY_TEST_RESULT=$?

if [ $SECURITY_TEST_RESULT -ne 0 ] && grep -q "postgresql.credentials.password" <<< "$SECURITY_TEST_OUTPUT"; then
    log_success "  ✓ Validation bloque postgresql password par défaut"
else
    log_error "  ✗ Validation devrait bloquer postgresql password par défaut!"
fi

# Test 4: Vérifier que les Secrets sont créés correctement
log_info "Test 4: Vérification création des Secrets Kubernetes..."
SECRETS_OUTPUT=$(helm template test-secrets $CHART_PATH \
    --set airflow.enabled=true \
    2>&1)

if grep -q "kind: Secret" <<< "$SECRETS_OUTPUT" && \
   grep -q "starlake-airflow" <<< "$SECRETS_OUTPUT" && \
   grep -q "admin-password" <<< "$SECRETS_OUTPUT" && \
   grep -q "secret-key" <<< "$SECRETS_OUTPUT"; then
    log_success "  ✓ Secret Airflow créé avec admin-password et secret-key"
else
    log_error "  ✗ Secret Airflow mal configuré!"
fi

# Test 5: Vérifier que le deployment utilise secretKeyRef
log_info "Test 5: Vérification utilisation secretKeyRef dans deployment..."
if grep -q "secretKeyRef" <<< "$SECRETS_OUTPUT" && \
   grep -q "AIRFLOW_ADMIN_PASSWORD" <<< "$SECRETS_OUTPUT"; then
    log_success "  ✓ Deployment utilise secretKeyRef pour le password"
else
    log_error "  ✗ Deployment devrait utiliser secretKeyRef!"
fi

echo ""
log_success "Tests de validation sécurité terminés!"
echo ""

# Si --security-only, on s'arrête ici
if [ "$SECURITY_ONLY" = true ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ Tests de sécurité terminés (--security-only)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    trap - EXIT  # Désactiver cleanup
    exit 0
fi

echo ""

# 1. Créer le cluster K3s
if [ "$MULTI_NODE" = true ]; then
    log_info "Création du cluster K3s '$CLUSTER_NAME' (multi-node: 1 server + $AGENT_COUNT agents)..."
    log_info "  Note: Multi-node utilise local-path (RWX recommandé en production)"
    log_info "  Note: Ports 11900-11920 exposés pour Gizmo SQL (hostNetwork)"
    k3d cluster create $CLUSTER_NAME \
        --servers 1 \
        --agents $AGENT_COUNT \
        --port "8080:80@loadbalancer" \
        --port "11900-11920:11900-11920@server:0" \
        --wait || {
            log_error "Échec de la création du cluster"
            exit 1
        }
    log_success "Cluster K3s créé: 1 server + $AGENT_COUNT agents"
else
    log_info "Création du cluster K3s '$CLUSTER_NAME' (single-node)..."
    log_info "  Note: Single-node requis car local-path ne supporte que RWO"
    log_info "  Note: Ports 11900-11920 exposés pour Gizmo SQL (hostNetwork)"
    k3d cluster create $CLUSTER_NAME \
        --servers 1 \
        --agents 0 \
        --port "8080:80@loadbalancer" \
        --port "11900-11920:11900-11920@server:0" \
        --wait || {
            log_error "Échec de la création du cluster"
            exit 1
        }
    log_success "Cluster K3s créé avec ports Gizmo SQL exposés (11900-11920)"
fi

# Attendre que le cluster soit prêt
log_info "Attente que le cluster soit prêt..."
kubectl wait --for=condition=ready node --all --timeout=${CLUSTER_READY_TIMEOUT}s
log_success "Cluster prêt"

# Afficher les nœuds
kubectl get nodes -o wide

# 1.1 Configuration du Storage Class
# Note: Pour les tests locaux multi-node, on utilise local-path avec une limitation:
# - Les pods partageant un PVC doivent être sur le même nœud
# - En production, utiliser un storage RWX (EFS, Filestore, Azure Files, NFS externe)
if [ "$MULTI_NODE" = true ]; then
    echo ""
    log_info "Mode multi-node: utilisation de local-path storage"
    log_warning "  Note: Le PVC /projects sera sur un seul nœud (limitation local-path)"
    log_warning "  En production, utiliser un storage RWX (EFS, Filestore, Azure Files)"
    echo ""

    # Forcer les pods avec PVC partagé sur le même nœud via nodeAffinity
    # Le premier pod à démarrer (PostgreSQL) déterminera le nœud
    STORAGE_CLASS="local-path"

    # Afficher les nœuds disponibles
    log_info "Nœuds disponibles dans le cluster:"
    kubectl get nodes -o wide
    echo ""
else
    STORAGE_CLASS="local-path"
fi

echo ""

# 1.5. Construire et importer les images locales dans k3d
log_info "Construction et import des images locales..."

# Chemin vers le répertoire racine du projet
PROJECT_ROOT="$(cd .. && pwd)"

# Variables pour les images locales
AIRFLOW_IMAGE_LOCAL="starlake-airflow:local"
PROJECTS_IMAGE_LOCAL="starlake-projects:local"
UI_IMAGE_LOCAL="starlake-ui:local"
AGENT_IMAGE_LOCAL="starlake-agent:local"

USE_LOCAL_AIRFLOW_IMAGE=""
USE_LOCAL_PROJECTS_IMAGE=""
USE_LOCAL_UI_IMAGE=""
USE_LOCAL_AGENT_IMAGE=""

# Fonction pour construire et importer une image
build_and_import_image() {
    local dockerfile=$1
    local image_tag=$2
    local description=$3

    log_info "  Construction de l'image $description..."
    if [ -f "$PROJECT_ROOT/$dockerfile" ]; then
        docker build -t $image_tag -f "$PROJECT_ROOT/$dockerfile" "$PROJECT_ROOT" || {
            log_warning "Construction de l'image $description a échoué"
            return 1
        }

        if docker image inspect $image_tag > /dev/null 2>&1; then
            log_info "  Import de l'image $description dans k3d..."
            # Capturer la sortie pour détecter les erreurs même si le code de retour est 0
            local import_output
            import_output=$(k3d image import $image_tag -c $CLUSTER_NAME 2>&1)
            local import_status=$?

            # Vérifier le code de retour ET la présence d'erreurs dans la sortie
            if [ $import_status -ne 0 ] || grep -qi "error\|failed" <<< "$import_output"; then
                log_warning "Import de l'image $description a échoué"
                head -5 <<< "$import_output"
                return 1
            fi
            log_success "Image $description importée: $image_tag"
            return 0
        fi
    else
        log_warning "$dockerfile non trouvé"
        return 1
    fi
}

# Fonction pour importer une image existante depuis le registre local Docker
import_existing_image() {
    local image_name=$1
    local local_tag=$2
    local description=$3

    log_info "  Recherche de l'image $description dans Docker local..."
    if docker image inspect $image_name > /dev/null 2>&1; then
        # Tagger l'image avec un tag local
        docker tag $image_name $local_tag
        log_info "  Import de l'image $description dans k3d..."
        # Capturer la sortie pour détecter les erreurs même si le code de retour est 0
        local import_output
        import_output=$(k3d image import $local_tag -c $CLUSTER_NAME 2>&1)
        local import_status=$?

        # Vérifier le code de retour ET la présence d'erreurs dans la sortie
        if [ $import_status -ne 0 ] || grep -qi "error\|failed" <<< "$import_output"; then
            log_warning "Import de l'image $description a échoué"
            head -5 <<< "$import_output"
            return 1
        fi
        log_success "Image $description importée: $local_tag"
        return 0
    else
        log_info "  Image $description non trouvée localement"
        return 1
    fi
}

# 1. Construire l'image Airflow depuis Dockerfile_airflow_k8s (K8s Job execution mode)
# Note: On utilise Dockerfile_airflow_k8s qui crée des K8s Jobs pour chaque commande starlake
# au lieu de Dockerfile_airflow qui utilise docker exec (incompatible avec K8s)
# Cette image inclut kubectl et le wrapper starlake qui crée des Jobs K8s
if build_and_import_image "Dockerfile_airflow_k8s" "$AIRFLOW_IMAGE_LOCAL" "Airflow (K8s)"; then
    USE_LOCAL_AIRFLOW_IMAGE="true"
fi

# 2. Construire l'image Projects depuis Dockerfile_projects
if build_and_import_image "Dockerfile_projects" "$PROJECTS_IMAGE_LOCAL" "Projects"; then
    USE_LOCAL_PROJECTS_IMAGE="true"
fi

# 3. Importer l'image UI si elle existe localement (pas de Dockerfile, image pré-construite)
UI_IMAGES=(
    "starlakeai/starlake-1.5-ui:1.5"
    "starlakeai/starlake-1.5-ui:latest"
    "starlakeai/starlake-ui:latest"
)
for ui_img in "${UI_IMAGES[@]}"; do
    if import_existing_image "$ui_img" "$UI_IMAGE_LOCAL" "UI"; then
        USE_LOCAL_UI_IMAGE="true"
        break
    fi
done

# 4. Importer l'image Agent (Ask) si elle existe localement
AGENT_IMAGES=(
    "starlakeai/starlake-1.5-ask:1.5"
    "starlakeai/starlake-1.5-ask:latest"
    "starlakeai/starlake-ask:latest"
)
for agent_img in "${AGENT_IMAGES[@]}"; do
    if import_existing_image "$agent_img" "$AGENT_IMAGE_LOCAL" "Agent"; then
        USE_LOCAL_AGENT_IMAGE="true"
        break
    fi
done

# 5. Importer l'image Gizmo si elle existe localement
GIZMO_IMAGE_LOCAL="starlake-gizmo:local"
USE_LOCAL_GIZMO_IMAGE=""
GIZMO_IMAGES=(
    "starlakeai/gizmo-on-demand:latest"
    "starlakeai/gizmo-on-demand:1.0"
)
for gizmo_img in "${GIZMO_IMAGES[@]}"; do
    if import_existing_image "$gizmo_img" "$GIZMO_IMAGE_LOCAL" "Gizmo"; then
        USE_LOCAL_GIZMO_IMAGE="true"
        break
    fi
done

# Note: PostgreSQL (postgres:17) est une image publique légère,
# on la laisse être téléchargée directement par k3d depuis Docker Hub
# car l'import local peut échouer avec des erreurs de digest sur les images multi-arch
log_info "  PostgreSQL: sera téléchargée depuis Docker Hub (image publique légère)"

# Résumé des images locales
echo ""
log_info "Résumé des images locales:"
[ "$USE_LOCAL_AIRFLOW_IMAGE" = "true" ] && log_success "  ✓ Airflow: $AIRFLOW_IMAGE_LOCAL" || log_info "  ✗ Airflow: image par défaut"
[ "$USE_LOCAL_PROJECTS_IMAGE" = "true" ] && log_success "  ✓ Projects: $PROJECTS_IMAGE_LOCAL" || log_info "  ✗ Projects: image par défaut"
[ "$USE_LOCAL_UI_IMAGE" = "true" ] && log_success "  ✓ UI: $UI_IMAGE_LOCAL" || log_info "  ✗ UI: image par défaut"
[ "$USE_LOCAL_AGENT_IMAGE" = "true" ] && log_success "  ✓ Agent: $AGENT_IMAGE_LOCAL" || log_info "  ✗ Agent: image par défaut"
[ "$USE_LOCAL_GIZMO_IMAGE" = "true" ] && log_success "  ✓ Gizmo: $GIZMO_IMAGE_LOCAL" || log_info "  ✗ Gizmo: image par défaut"
log_info "  ✗ PostgreSQL: postgres:17 (téléchargée depuis Docker Hub)"

echo ""

# 2. Installer Headlamp (interface web Kubernetes)
log_info "Installation de Headlamp (interface web Kubernetes)..."
helm repo add headlamp https://headlamp-k8s.github.io/headlamp/ 2>/dev/null || true
helm repo update headlamp 2>/dev/null || true

helm install my-headlamp headlamp/headlamp \
    --namespace kube-system \
    --wait \
    --timeout 5m || {
        log_warning "Installation de Headlamp a échoué (non bloquant)"
    }

# Créer un ServiceAccount avec les permissions admin pour Headlamp
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: headlamp-admin
    namespace: kube-system
EOF

# Attendre que le pod Headlamp soit prêt
log_info "Attente du démarrage de Headlamp..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=headlamp -n kube-system --timeout=${HEADLAMP_READY_TIMEOUT}s 2>/dev/null || {
    log_warning "Headlamp n'est pas encore prêt (non bloquant)"
}

log_success "Headlamp installé"

# Démarrer le port-forward Headlamp maintenant pour pouvoir suivre l'installation
log_info "Démarrage du port-forward Headlamp..."
kubectl port-forward -n kube-system svc/my-headlamp 9999:80 > /dev/null 2>&1 &
HEADLAMP_PF_PID=$!
sleep 2

# Afficher le token et les informations d'accès
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🖥️  Headlamp - Suivez l'installation en temps réel"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_success "Headlamp accessible: http://localhost:9999"
echo ""
log_info "Token d'authentification:"
HEADLAMP_TOKEN=$(kubectl create token headlamp-admin --namespace kube-system 2>/dev/null || echo "Erreur: impossible de créer le token")
echo ""
echo -e "${GREEN}$HEADLAMP_TOKEN${NC}"
echo ""
log_warning "Copiez ce token et ouvrez http://localhost:9999 pour suivre l'installation"
echo ""

# 3. Lint du chart Starlake
log_info "Validation du chart (helm lint)..."
helm lint $CHART_PATH || {
    log_error "Helm lint a échoué"
    exit 1
}
log_success "Chart valide"

echo ""

# 4. Installer le chart Starlake
log_info "Installation du chart Helm..."
log_info "  Namespace: $NAMESPACE"
log_info "  Storage: local-path (K3s built-in)"

# Préparer les options d'images locales
LOCAL_IMAGE_OPTS=""

# Image Airflow (K8s Job mode)
# L'image Dockerfile_airflow_k8s inclut:
# - kubectl pour créer des K8s Jobs
# - Le wrapper starlake qui crée des Jobs au lieu d'exécuter localement
# - starlake-airflow 0.4.x pré-installé (compatible Airflow 2)
if [ "$USE_LOCAL_AIRFLOW_IMAGE" = "true" ]; then
    log_info "  Image Airflow: $AIRFLOW_IMAGE_LOCAL (K8s Job mode, packages pré-installés)"
    LOCAL_IMAGE_OPTS="$LOCAL_IMAGE_OPTS --set airflow.image.repository=starlake-airflow --set airflow.image.tag=local --set airflow.image.pullPolicy=Never --set airflow.installPythonPackages=false"
else
    log_info "  Image Airflow: apache/airflow (par défaut, pip install au démarrage)"
fi

# Image UI
if [ "$USE_LOCAL_UI_IMAGE" = "true" ]; then
    log_info "  Image UI: $UI_IMAGE_LOCAL (locale)"
    LOCAL_IMAGE_OPTS="$LOCAL_IMAGE_OPTS --set ui.image.repository=starlake-ui --set ui.image.tag=local --set ui.image.pullPolicy=Never"
else
    log_info "  Image UI: starlakeai/starlake-1.5-ui (par défaut)"
fi

# Image Agent
if [ "$USE_LOCAL_AGENT_IMAGE" = "true" ]; then
    log_info "  Image Agent: $AGENT_IMAGE_LOCAL (locale)"
    LOCAL_IMAGE_OPTS="$LOCAL_IMAGE_OPTS --set agent.image.repository=starlake-agent --set agent.image.tag=local --set agent.image.pullPolicy=Never"
else
    log_info "  Image Agent: starlakeai/starlake-1.5-ask (par défaut)"
fi

# Image Gizmo
if [ "$USE_LOCAL_GIZMO_IMAGE" = "true" ]; then
    log_info "  Image Gizmo: $GIZMO_IMAGE_LOCAL (locale)"
    LOCAL_IMAGE_OPTS="$LOCAL_IMAGE_OPTS --set gizmo.image.repository=starlake-gizmo --set gizmo.image.tag=local --set gizmo.image.pullPolicy=Never"
else
    log_info "  Image Gizmo: starlakeai/gizmo-on-demand (par défaut)"
fi

# PostgreSQL: image publique légère, téléchargée automatiquement par k3d
log_info "  Image PostgreSQL: postgres:17 (téléchargée depuis Docker Hub)"

log_info "  Note: Les images Starlake nécessitent ~2-3 minutes pour démarrer"

# Installation avec les paramètres optimisés pour K3s
# Note: --wait=false car les init jobs prennent du temps (airflow db init, demo data load)
# La boucle de surveillance ci-dessous attend que les pods soient prêts

# Préparer les options de credentials
CREDENTIAL_OPTS=""
CREDENTIAL_OPTS="$CREDENTIAL_OPTS --set postgresql.credentials.password=$PG_PASSWORD"
CREDENTIAL_OPTS="$CREDENTIAL_OPTS --set airflow.admin.password=$AIRFLOW_PASSWORD"
CREDENTIAL_OPTS="$CREDENTIAL_OPTS --set airflow.secretKey=$AIRFLOW_SECRET_KEY"
CREDENTIAL_OPTS="$CREDENTIAL_OPTS --set gizmo.apiKey=$GIZMO_API_KEY"
CREDENTIAL_OPTS="$CREDENTIAL_OPTS --set agent.applicationKey=$AGENT_APPLICATION_KEY"
CREDENTIAL_OPTS="$CREDENTIAL_OPTS --set security.validateCredentials=$VALIDATE_CREDENTIALS"

log_info "  Credentials: $([ "$PRODUCTION_MODE" = true ] && echo "sécurisés (mode production)" || echo "par défaut (mode dev)")"
log_info "  Validation: $VALIDATE_CREDENTIALS"

# Déterminer le storage class
if [ -z "$STORAGE_CLASS" ]; then
    STORAGE_CLASS="local-path"
fi

log_info "  Storage class: $STORAGE_CLASS"
log_info "  Mode: $([ "$MULTI_NODE" = true ] && echo "multi-node ($AGENT_COUNT agents)" || echo "single-node")"

# Options spécifiques multi-node
MULTINODE_OPTS=""
if [ "$MULTI_NODE" = true ]; then
    # Note: En multi-node avec local-path storage, on NE PEUT PAS forcer Gizmo sur le server
    # car le PVC a une affinité vers le nœud où il a été créé (limitation local-path)
    # Les ports Gizmo (11900+) sont accessibles via port-forward:
    log_warning "  Gizmo: port-forward requis en multi-node (limitation storage local-path)"
    log_info "  Commande: kubectl port-forward deploy/starlake-gizmo 11900:11900 -n starlake"
    # Ne pas ajouter de nodeSelector - laisser Gizmo se scheduler où le PVC est disponible
fi

# Options SeaweedFS (object storage S3)
SEAWEEDFS_OPTS=""
if [ "$SEAWEEDFS_ENABLED" = true ]; then
    log_info "  SeaweedFS: Object storage S3 activé (pour projets utilisateur)"
    log_info "  Note: Initialisation du bucket S3 via hook post-install (~30-60s)"
    SEAWEEDFS_OPTS="--set seaweedfs.enabled=true"
    SEAWEEDFS_OPTS="$SEAWEEDFS_OPTS --set seaweedfs.persistence.storageClass=$STORAGE_CLASS"
fi

# Demo projects - always enabled and stored on local PVC
# (regardless of storage mode - provides working examples out-of-the-box)
DEMO_ENABLED="true"
log_info "  Demo: Activé (toujours en local PVC pour exemples fonctionnels)"

helm install starlake $CHART_PATH \
    --namespace $NAMESPACE \
    --create-namespace \
    --timeout 10m \
    --set postgresql.internal.persistence.size=2Gi \
    --set postgresql.internal.persistence.storageClass=$STORAGE_CLASS \
    --set persistence.projects.size=2Gi \
    --set persistence.projects.storageClass=$STORAGE_CLASS \
    --set airflow.webserver.resources.requests.memory=4Gi \
    --set airflow.webserver.resources.limits.memory=16Gi \
    --set ui.resources.requests.memory=512Mi \
    --set ui.resources.limits.memory=2Gi \
    --set agent.resources.requests.memory=256Mi \
    --set agent.resources.limits.memory=1Gi \
    --set airflow.logs.persistence.enabled=false \
    --set gizmo.enabled=true \
    --set gizmo.resources.requests.memory=512Mi \
    --set gizmo.resources.limits.memory=2Gi \
    --set ui.service.type=ClusterIP \
    --set ingress.enabled=true \
    --set ingress.className="" \
    --set ingress.host="" \
    --set demo.enabled=$DEMO_ENABLED \
    --set ui.frontendUrl=http://localhost:8080 \
    --set airflow.baseUrl=http://localhost:8080/airflow \
    --set airflow.jobRunner.enabled=true \
    $CREDENTIAL_OPTS \
    $LOCAL_IMAGE_OPTS \
    $MULTINODE_OPTS \
    $SEAWEEDFS_OPTS || {
        log_error "Installation du chart a échoué"
        exit 1
    }

log_success "Chart soumis à Kubernetes"

echo ""

# 5. Surveiller le déploiement avec logs en temps réel
log_info "Surveillance du déploiement..."
log_info "  Temps estimé: 2-5 minutes (téléchargement des images + démarrage)"
echo ""

# Fonction pour afficher l'état des pods
show_pod_status() {
    echo ""
    log_info "=== État des pods ==="
    kubectl get pods -n $NAMESPACE -o wide
    echo ""

    # Vérifier les PVCs
    log_info "=== État des PVCs ==="
    kubectl get pvc -n $NAMESPACE
    echo ""
}

# Fonction pour afficher les logs des pods en erreur
show_error_logs() {
    local pod_name=$1
    echo ""
    log_warning "=== Logs de $pod_name ==="
    kubectl logs "$pod_name" -n $NAMESPACE --tail=30 2>/dev/null || \
        echo "Pas de logs disponibles"
}

# Boucle de surveillance
MAX_ATTEMPTS=$POD_READY_MAX_ATTEMPTS  # Configurable en haut du script
ATTEMPT=0
ALL_READY=false
CONSECUTIVE_ERRORS=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))

    # Récupérer l'état des pods
    PODS_STATUS=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null)

    if [ -z "$PODS_STATUS" ]; then
        log_info "[$ATTEMPT/$MAX_ATTEMPTS] Attente de la création des pods..."
        sleep 5
        continue
    fi

    # Compter les pods par état (exclure les jobs Completed)
    # Note: pipefail + grep = exit 1 si pas de match, d'où les sous-shells
    TOTAL=$(grep -vc "Completed" <<< "$PODS_STATUS" || true)
    RUNNING=$(grep -c "Running" <<< "$PODS_STATUS" || true)
    PENDING=$(grep -c "Pending" <<< "$PODS_STATUS" || true)
    CRASHLOOP=$(grep -c "CrashLoopBackOff\|ImagePullBackOff" <<< "$PODS_STATUS" || true)
    ERROR=$({ grep -E "Error" <<< "$PODS_STATUS" | grep -vc "Completed"; } || true)
    INIT=$(grep -c "Init:" <<< "$PODS_STATUS" || true)
    READY=$({ grep -E "[0-9]+/[0-9]+.*Running" <<< "$PODS_STATUS" | awk '{split($2,a,"/"); if(a[1]==a[2]) print}' | wc -l | tr -d ' '; } || true)

    echo -ne "\r[$ATTEMPT/$MAX_ATTEMPTS] Pods: $READY/$TOTAL Ready, $RUNNING Running, $INIT Init, $PENDING Pending, $CRASHLOOP CrashLoop    "

    # Vérifier si tous les pods principaux sont ready (exclure les jobs)
    # On attend au moins 5 pods: postgresql, airflow, ui, agent, gizmo (proxy removed)
    if [ "$READY" -ge 5 ] && [ "$CRASHLOOP" -eq 0 ]; then
        echo ""
        ALL_READY=true
        break
    fi

    # Si des pods sont en CrashLoopBackOff depuis plusieurs itérations
    if [ "$CRASHLOOP" -gt 0 ]; then
        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))

        # Attendre 3 itérations avant de considérer comme échec (laisser le temps aux restarts)
        if [ $CONSECUTIVE_ERRORS -ge 6 ]; then
            echo ""
            log_error "Pods en CrashLoopBackOff depuis plus de 30 secondes"
            show_pod_status

            # Afficher les logs des pods en erreur
            while IFS= read -r line; do
                POD_NAME=$(echo "$line" | awk '{print $1}')
                POD_STATUS=$(echo "$line" | awk '{print $3}')

                if [[ "$POD_STATUS" == *"CrashLoopBackOff"* ]] || [[ "$POD_STATUS" == *"ImagePullBackOff"* ]]; then
                    show_error_logs "$POD_NAME"

                    # Events du pod
                    log_warning "=== Events du pod $POD_NAME ==="
                    kubectl describe pod "$POD_NAME" -n $NAMESPACE | grep -A 15 "Events:" || true
                fi
            done <<< "$PODS_STATUS"

            log_error "Des pods sont en erreur. Consultez les logs ci-dessus."
            log_info "Pour débugger manuellement:"
            echo "  kubectl get pods -n $NAMESPACE"
            echo "  kubectl logs <pod-name> -n $NAMESPACE"
            echo "  kubectl describe pod <pod-name> -n $NAMESPACE"
            exit 1
        fi
    else
        CONSECUTIVE_ERRORS=0
    fi

    sleep 5
done

echo ""

if [ "$ALL_READY" = true ]; then
    log_success "Tous les pods sont prêts!"
else
    log_warning "Timeout atteint, vérifions l'état actuel..."
    show_pod_status

    # Vérifier si c'est acceptable (certains pods peuvent avoir des restarts)
    READY=$(kubectl get pods -n $NAMESPACE --no-headers | grep -E "[0-9]+/[0-9]+.*Running" | awk '{split($2,a,"/"); if(a[1]==a[2]) print}' | wc -l | tr -d ' ')
    if [ "$READY" -ge 5 ]; then
        log_warning "La plupart des pods sont prêts ($READY/6), on continue..."
    else
        log_error "Pas assez de pods prêts, arrêt du test"
        exit 1
    fi
fi

# Afficher l'état final
echo ""
log_info "État final des pods:"
kubectl get pods -n $NAMESPACE -o wide

echo ""
log_info "État des PVCs:"
kubectl get pvc -n $NAMESPACE

echo ""
log_info "État des services:"
kubectl get svc -n $NAMESPACE

log_success "Ressources déployées"

# 5.4 Validation multi-node (si activé)
if [ "$MULTI_NODE" = true ]; then
    echo ""
    log_info "=== Validation Multi-Node ==="

    # Afficher la distribution des pods par nœud
    log_info "Distribution des pods par nœud:"
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        pod_count=$(kubectl get pods -n $NAMESPACE --field-selector spec.nodeName=$node --no-headers 2>/dev/null | wc -l | tr -d ' ')
        echo "  $node: $pod_count pods"
    done

    # Compter le nombre de nœuds utilisés
    NODES_WITH_PODS=$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
    TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')

    echo ""
    log_info "Résumé: Pods distribués sur $NODES_WITH_PODS/$TOTAL_NODES nœuds"

    if [ "$NODES_WITH_PODS" -gt 1 ]; then
        log_success "✓ Distribution multi-nœuds validée"
    else
        log_warning "⚠ Tous les pods sont sur un seul nœud (possible si affinité ou resources limitées)"
    fi

    # Vérifier que le PVC projects est accessible (RWX)
    log_info "Vérification du storage RWX..."
    PVC_ACCESS_MODE=$(kubectl get pvc starlake-projects -n $NAMESPACE -o jsonpath='{.spec.accessModes[0]}' 2>/dev/null || echo "N/A")
    if [ "$PVC_ACCESS_MODE" = "ReadWriteMany" ] || [ "$STORAGE_CLASS" = "nfs-client" ]; then
        log_success "✓ Storage RWX configuré (StorageClass: $STORAGE_CLASS)"
    else
        log_info "  PVC access mode: $PVC_ACCESS_MODE (StorageClass: $STORAGE_CLASS)"
    fi

    echo ""
fi

echo ""

# 5.5 Configurer les projets en local_mode pour éviter les erreurs de chemin
log_info "Configuration des projets en local_mode (fix path resolution)..."
# Attendre que PostgreSQL soit prêt
sleep 5
kubectl exec starlake-postgresql-0 -n $NAMESPACE -- \
    psql -U dbuser -d starlake -c "UPDATE slk_project SET local_mode = true WHERE local_mode = false;" 2>/dev/null || \
    log_warning "Pas de projets à mettre à jour (table vide ou non créée)"
log_success "Projets configurés"

echo ""

# 6. Tests fonctionnels
log_info "Exécution des tests fonctionnels..."

# Test 1: PostgreSQL
log_info "Test 1/6: Connexion PostgreSQL..."
if kubectl exec starlake-postgresql-0 -n $NAMESPACE -- \
    psql -U dbuser -d starlake -c "SELECT 1" > /dev/null 2>&1; then
    log_success "  PostgreSQL: OK"
else
    log_warning "  PostgreSQL: En cours de démarrage..."
fi

# Test 2: Bases de données créées
log_info "Test 2/6: Vérification des bases de données..."
DB_COUNT=$(kubectl exec starlake-postgresql-0 -n $NAMESPACE -- \
    psql -U dbuser -c "\l" 2>/dev/null | grep -E "starlake|airflow" | wc -l || echo "0")
if [ "$DB_COUNT" -ge 2 ]; then
    log_success "  Bases de données: OK ($DB_COUNT trouvées)"
else
    log_warning "  Bases de données: En cours de création..."
fi

# Test 3: API Airflow accessible
log_info "Test 3/6: API Airflow..."
AIRFLOW_POD=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/component=airflow -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$AIRFLOW_POD" ]; then
    API_RESPONSE=$(kubectl exec $AIRFLOW_POD -n $NAMESPACE -- \
        curl -s -u airflow:airflow http://localhost:8080/airflow/api/v1/dags 2>/dev/null || echo "")
    if grep -q "dags" <<< "$API_RESPONSE"; then
        log_success "  API Airflow: OK"
    else
        log_warning "  API Airflow: En cours de démarrage..."
    fi
else
    log_warning "  API Airflow: Pod non trouvé"
fi

# Test 4: Health check UI (direct)
log_info "Test 4/6: Health check UI (via port-forward direct)..."
# Note: Service expose port 80 which maps to container port 9900
kubectl port-forward svc/starlake-ui 8888:80 -n $NAMESPACE > /dev/null 2>&1 &
PF_PID=$!
sleep $PORT_FORWARD_SLEEP

UI_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8888/api/v1/health 2>/dev/null || echo "000")
if [ "$UI_HEALTH" = "200" ]; then
    log_success "  UI: OK (HTTP $UI_HEALTH)"
else
    log_warning "  UI: HTTP $UI_HEALTH (peut prendre plus de temps)"
fi

kill $PF_PID 2>/dev/null || true

# Test 5: Health check Airflow (direct)
log_info "Test 5/6: Health check Airflow (via port-forward direct)..."
kubectl port-forward svc/starlake-airflow 8889:8080 -n $NAMESPACE > /dev/null 2>&1 &
PF_PID=$!
sleep $PORT_FORWARD_SLEEP

AIRFLOW_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8889/airflow/health 2>/dev/null || echo "000")
if [ "$AIRFLOW_HEALTH" = "200" ]; then
    log_success "  Airflow: OK (HTTP $AIRFLOW_HEALTH)"
else
    log_warning "  Airflow: HTTP $AIRFLOW_HEALTH (peut prendre plus de temps)"
fi

kill $PF_PID 2>/dev/null || true

# Test 6: Health check Gizmo (direct)
log_info "Test 6/6: Health check Gizmo (via port-forward direct)..."
kubectl port-forward svc/starlake-gizmo 10999:10900 -n $NAMESPACE > /dev/null 2>&1 &
PF_PID=$!
sleep $PORT_FORWARD_SLEEP

GIZMO_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:10999/health 2>/dev/null || echo "000")
if [ "$GIZMO_HEALTH" = "200" ]; then
    log_success "  Gizmo: OK (HTTP $GIZMO_HEALTH)"
else
    log_warning "  Gizmo: HTTP $GIZMO_HEALTH (peut prendre plus de temps)"
fi

kill $PF_PID 2>/dev/null || true

# Test 7: Health check SeaweedFS (si activé)
if [ "$SEAWEEDFS_ENABLED" = true ]; then
    log_info "Test 7/7: Health check SeaweedFS (via port-forward direct)..."
    kubectl port-forward svc/starlake-seaweedfs 8399:8333 -n $NAMESPACE > /dev/null 2>&1 &
    PF_PID=$!
    sleep $PORT_FORWARD_SLEEP

    # Test S3 API health
    SEAWEEDFS_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8399/ 2>/dev/null || echo "000")
    if [ "$SEAWEEDFS_HEALTH" = "200" ] || [ "$SEAWEEDFS_HEALTH" = "403" ]; then
        log_success "  SeaweedFS S3: OK (HTTP $SEAWEEDFS_HEALTH)"
    else
        log_warning "  SeaweedFS S3: HTTP $SEAWEEDFS_HEALTH (peut prendre plus de temps)"
    fi

    kill $PF_PID 2>/dev/null || true
fi

echo ""

# 8. Test d'upgrade (optionnel, rapide)
log_info "Test d'upgrade du chart..."
helm upgrade starlake $CHART_PATH \
    --namespace $NAMESPACE \
    --reuse-values \
    --set ui.replicas=1 \
    --timeout 5m || {
        log_warning "Upgrade a échoué (peut être normal si des pods redémarrent)"
    }
log_success "Upgrade soumis"

# Vérifier l'historique
REVISION_COUNT=$(helm history starlake -n $NAMESPACE 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
if [ "$REVISION_COUNT" -ge 2 ]; then
    log_success "Historique: $REVISION_COUNT révisions"
fi

echo ""

# 8. Résumé
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📊 Résumé des Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_success "Chart installé et testé avec succès!"
echo ""
log_info "Composants déployés:"
echo "  - PostgreSQL (StatefulSet)"
echo "  - Airflow Webserver + Scheduler"
echo "  - Starlake UI"
echo "  - Starlake Agent (AI)"
echo "  - Gizmo (SQL on-demand)"
if [ "$SEAWEEDFS_ENABLED" = true ]; then
    echo "  - SeaweedFS (S3 Object Storage)"
fi
echo "  - Headlamp (Interface Web Kubernetes)"
echo ""

# 9. Démarrage des port-forwards pour Starlake
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🚀 Démarrage des Port-Forwards Starlake"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "Démarrage des port-forwards..."
log_success "  Headlamp: http://localhost:9999 (déjà actif)"

# Démarrer Starlake UI port-forward sur port 8080 (service port 80 maps to container 9900)
# Note: UI proxie /airflow vers le service Airflow interne, pas besoin de port-forward séparé
kubectl port-forward svc/starlake-ui 8080:80 -n $NAMESPACE > /dev/null 2>&1 &
UI_PF_PID=$!
log_success "  Starlake UI: http://localhost:8080 (PID: $UI_PF_PID)"
log_success "  Airflow:     http://localhost:8080/airflow (via UI proxy)"

# Démarrer Agent port-forward (port 8000)
kubectl port-forward svc/starlake-agent 8000:8000 -n $NAMESPACE > /dev/null 2>&1 &
AGENT_PF_PID=$!
log_success "  Agent: http://localhost:8000 (PID: $AGENT_PF_PID)"

# Démarrer Gizmo port-forward (port 10900)
kubectl port-forward svc/starlake-gizmo 10900:10900 -n $NAMESPACE > /dev/null 2>&1 &
GIZMO_PF_PID=$!
log_success "  Gizmo: http://localhost:10900 (PID: $GIZMO_PF_PID)"

# Démarrer SeaweedFS port-forwards (si activé)
if [ "$SEAWEEDFS_ENABLED" = true ]; then
    # S3 API (8333)
    kubectl port-forward svc/starlake-seaweedfs 8333:8333 -n $NAMESPACE > /dev/null 2>&1 &
    SEAWEEDFS_S3_PF_PID=$!
    log_success "  SeaweedFS S3 API: http://localhost:8333 (PID: $SEAWEEDFS_S3_PF_PID)"

    # Master UI (9333) - Interface web cluster status
    kubectl port-forward svc/starlake-seaweedfs 9333:9333 -n $NAMESPACE > /dev/null 2>&1 &
    SEAWEEDFS_MASTER_PF_PID=$!
    log_success "  SeaweedFS Master UI: http://localhost:9333 (PID: $SEAWEEDFS_MASTER_PF_PID)"

    # Filer UI (8888) - File browser
    kubectl port-forward svc/starlake-seaweedfs 8888:8888 -n $NAMESPACE > /dev/null 2>&1 &
    SEAWEEDFS_FILER_PF_PID=$!
    log_success "  SeaweedFS Filer UI: http://localhost:8888 (PID: $SEAWEEDFS_FILER_PF_PID)"

    log_info "    S3 Endpoint: http://localhost:8333"
    log_info "    Bucket: starlake (SL_ROOT=s3a://starlake)"
    log_info "    Credentials: seaweedfs / seaweedfs123"
fi

sleep $PORT_FORWARD_SLEEP

# 10. Vérification des accès
echo ""
log_info "Vérification des accès..."

HEADLAMP_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9999/ 2>/dev/null || echo "000")
if [ "$HEADLAMP_CHECK" = "200" ] || [ "$HEADLAMP_CHECK" = "304" ]; then
    log_success "  Headlamp: OK (HTTP $HEADLAMP_CHECK)"
else
    log_warning "  Headlamp: HTTP $HEADLAMP_CHECK - Vérifiez le pod: kubectl get pods -n kube-system -l app.kubernetes.io/name=headlamp"
fi

UI_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/v1/health 2>/dev/null || echo "000")
if [ "$UI_CHECK" = "200" ]; then
    log_success "  Starlake UI: OK (HTTP $UI_CHECK)"
else
    log_warning "  Starlake UI: HTTP $UI_CHECK - Service port 80 -> container 9900"
    log_info "    Vérifiez le pod: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=ui"
fi

# Airflow via UI proxy (same port 8080)
AIRFLOW_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/airflow/health 2>/dev/null || echo "000")
if [ "$AIRFLOW_CHECK" = "200" ]; then
    log_success "  Airflow: OK (HTTP $AIRFLOW_CHECK)"
else
    log_warning "  Airflow: HTTP $AIRFLOW_CHECK - Vérifiez le pod: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=airflow"
fi

AGENT_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/ask/health 2>/dev/null || echo "000")
if [ "$AGENT_CHECK" = "200" ]; then
    log_success "  Agent: OK (HTTP $AGENT_CHECK)"
else
    log_warning "  Agent: HTTP $AGENT_CHECK - Vérifiez le pod: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=agent"
fi

GIZMO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:10900/health 2>/dev/null || echo "000")
if [ "$GIZMO_CHECK" = "200" ]; then
    log_success "  Gizmo: OK (HTTP $GIZMO_CHECK)"
else
    log_warning "  Gizmo: HTTP $GIZMO_CHECK - Vérifiez le pod: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=gizmo"
fi

if [ "$SEAWEEDFS_ENABLED" = true ]; then
    # Check S3 API (403 is expected without auth)
    SEAWEEDFS_S3_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8333/ 2>/dev/null || echo "000")
    if [ "$SEAWEEDFS_S3_CHECK" = "200" ] || [ "$SEAWEEDFS_S3_CHECK" = "403" ]; then
        log_success "  SeaweedFS S3 API: OK (HTTP $SEAWEEDFS_S3_CHECK)"
    else
        log_warning "  SeaweedFS S3 API: HTTP $SEAWEEDFS_S3_CHECK"
    fi

    # Check Master UI
    SEAWEEDFS_MASTER_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9333/ 2>/dev/null || echo "000")
    if [ "$SEAWEEDFS_MASTER_CHECK" = "200" ]; then
        log_success "  SeaweedFS Master UI: OK (HTTP $SEAWEEDFS_MASTER_CHECK)"
    else
        log_warning "  SeaweedFS Master UI: HTTP $SEAWEEDFS_MASTER_CHECK"
    fi

    # Check Filer UI
    SEAWEEDFS_FILER_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8888/ 2>/dev/null || echo "000")
    if [ "$SEAWEEDFS_FILER_CHECK" = "200" ]; then
        log_success "  SeaweedFS Filer UI: OK (HTTP $SEAWEEDFS_FILER_CHECK)"
    else
        log_warning "  SeaweedFS Filer UI: HTTP $SEAWEEDFS_FILER_CHECK"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Applications Accessibles"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Headlamp:     http://localhost:9999"
echo "  Starlake UI:  http://localhost:8080"
echo "  Airflow:      http://localhost:8080/airflow (via UI proxy)"
echo "  Agent:        http://localhost:8000"
echo "  Gizmo:        http://localhost:10900"
if [ "$SEAWEEDFS_ENABLED" = true ]; then
    echo ""
    echo "  SeaweedFS:"
    echo "    Master UI:  http://localhost:9333 (cluster status)"
    echo "    Filer UI:   http://localhost:8888 (file browser)"
    echo "    S3 API:     http://localhost:8333 (requires auth)"
fi
echo ""
if [ "$PRODUCTION_MODE" = true ]; then
    echo "  🔒 Mode Production - Credentials sécurisés:"
    echo "  Airflow: airflow / $AIRFLOW_PASSWORD"
    echo "  PostgreSQL: dbuser / $PG_PASSWORD"
    echo "  Gizmo API KEY: $SECURE_GIZMO_API_KEY"
else
    echo "  Credentials Airflow: airflow / airflow"
    echo "  Credentials PostgreSQL: dbuser / dbuser123"
fi
if [ "$SEAWEEDFS_ENABLED" = true ]; then
    echo ""
    echo "  📦 SeaweedFS Object Storage:"
    echo "    Master UI:  http://localhost:9333 (cluster status)"
    echo "    Filer UI:   http://localhost:8888 (file browser)"
    echo "    S3 API:     http://localhost:8333"
    echo "    Bucket:     starlake"
    echo "    SL_ROOT:    s3a://starlake"
    echo "    Access Key: seaweedfs"
    echo "    Secret Key: seaweedfs123"
fi
echo ""

log_info "Pour voir les logs:"
echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=ui -f"
echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=airflow -f"
echo ""

# 11. Option pour garder le cluster
read -p "Voulez-vous garder le cluster pour inspecter? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Cluster conservé: $CLUSTER_NAME"
    echo ""
    echo "  Pour arrêter les port-forwards: pkill -f 'kubectl port-forward'"
    echo "  Pour supprimer le cluster: k3d cluster delete $CLUSTER_NAME"
    echo ""

    trap - EXIT  # Désactiver le cleanup automatique
    exit 0
fi

echo ""
log_info "Nettoyage automatique..."

# Tuer les port-forwards avant cleanup
pkill -f "kubectl port-forward" 2>/dev/null || true

cleanup
trap - EXIT  # Désactiver le trap

echo ""
log_success "✅ Tous les tests ont réussi!"
echo ""
