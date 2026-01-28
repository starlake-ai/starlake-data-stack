#!/bin/bash
# Script de validation du Helm chart Starlake

set -e

CHART_DIR="./starlake"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Validation du Helm Chart Starlake"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}✗ Helm n'est pas installé${NC}"
    echo "  Installer avec: brew install helm (macOS) ou voir https://helm.sh/docs/intro/install/"
    exit 1
fi
echo -e "${GREEN}✓ Helm est installé${NC} ($(helm version --short))"

# Check if chart directory exists
if [ ! -d "$CHART_DIR" ]; then
    echo -e "${RED}✗ Répertoire du chart non trouvé: $CHART_DIR${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Répertoire du chart trouvé${NC}"

# Lint the chart
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  1. Validation de la syntaxe (helm lint)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if helm lint "$CHART_DIR"; then
    echo -e "${GREEN}✓ Lint réussi${NC}"
else
    echo -e "${RED}✗ Erreurs de lint détectées${NC}"
    exit 1
fi

# Validate templates
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  2. Validation des templates"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test with default values
echo -e "${YELLOW}[Test 1/4]${NC} Configuration par défaut (PostgreSQL interne)"
helm template test-starlake "$CHART_DIR" > /dev/null
echo -e "${GREEN}✓ Templates valides avec configuration par défaut${NC}"

# Test with external PostgreSQL
echo -e "${YELLOW}[Test 2/4]${NC} Configuration avec PostgreSQL externe"
helm template test-starlake "$CHART_DIR" \
  --set postgresql.external.enabled=true \
  --set postgresql.external.host=my-postgres.example.com \
  --set postgresql.internal.enabled=false > /dev/null
echo -e "${GREEN}✓ Templates valides avec PostgreSQL externe${NC}"

# Test with Ingress enabled
echo -e "${YELLOW}[Test 3/4]${NC} Configuration avec Ingress activé"
helm template test-starlake "$CHART_DIR" \
  --set ingress.enabled=true \
  --set ingress.host=starlake.example.com \
  --set proxy.service.type=ClusterIP > /dev/null
echo -e "${GREEN}✓ Templates valides avec Ingress${NC}"

# Test with development values
echo -e "${YELLOW}[Test 4/4]${NC} Configuration développement"
helm template test-starlake "$CHART_DIR" \
  --values "$CHART_DIR/values-development.yaml" > /dev/null
echo -e "${GREEN}✓ Templates valides avec values-development.yaml${NC}"

# Check required files
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  3. Vérification des fichiers requis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

required_files=(
    "$CHART_DIR/Chart.yaml"
    "$CHART_DIR/values.yaml"
    "$CHART_DIR/templates/_helpers.tpl"
    "$CHART_DIR/templates/secrets.yaml"
    "$CHART_DIR/templates/configmap.yaml"
    "$CHART_DIR/templates/pvc.yaml"
    "$CHART_DIR/templates/database/statefulset.yaml"
    "$CHART_DIR/templates/database/service.yaml"
    "$CHART_DIR/templates/ui/deployment.yaml"
    "$CHART_DIR/templates/ui/service.yaml"
    "$CHART_DIR/templates/airflow/deployment.yaml"
    "$CHART_DIR/templates/airflow/service.yaml"
    "$CHART_DIR/templates/airflow/init-job.yaml"
    "$CHART_DIR/templates/agent/deployment.yaml"
    "$CHART_DIR/templates/agent/service.yaml"
    "$CHART_DIR/templates/proxy/deployment.yaml"
    "$CHART_DIR/templates/proxy/service.yaml"
    "$CHART_DIR/templates/ingress.yaml"
    "$CHART_DIR/templates/serviceaccount.yaml"
    "$CHART_DIR/templates/NOTES.txt"
)

missing_files=0
for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $file"
    else
        echo -e "${RED}✗${NC} $file ${RED}(manquant)${NC}"
        ((missing_files++))
    fi
done

if [ $missing_files -gt 0 ]; then
    echo -e "${RED}✗ $missing_files fichiers manquants${NC}"
    exit 1
fi

# Check scripts
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  4. Vérification des scripts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

required_scripts=(
    "$CHART_DIR/scripts/init-airflow-database.sh"
    "$CHART_DIR/scripts/starlake.sh"
)

missing_scripts=0
for script in "${required_scripts[@]}"; do
    if [ -f "$script" ]; then
        echo -e "${GREEN}✓${NC} $script"
    else
        echo -e "${RED}✗${NC} $script ${RED}(manquant)${NC}"
        ((missing_scripts++))
    fi
done

if [ $missing_scripts -gt 0 ]; then
    echo -e "${RED}✗ $missing_scripts scripts manquants${NC}"
    exit 1
fi

# Dry-run install test
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  5. Test d'installation (dry-run)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if helm install starlake-test "$CHART_DIR" --dry-run --debug > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Dry-run install réussi${NC}"
else
    echo -e "${RED}✗ Dry-run install échoué${NC}"
    helm install starlake-test "$CHART_DIR" --dry-run --debug
    exit 1
fi

# Success
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Toutes les validations ont réussi !${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Le chart est prêt à être déployé !"
echo ""
echo "Prochaines étapes :"
echo "  1. Tester sur un cluster local : helm install starlake ./starlake -n starlake --create-namespace"
echo "  2. Personnaliser values.yaml pour votre environnement"
echo "  3. Déployer en production avec : helm install starlake ./starlake -f values-production.yaml"
echo ""
