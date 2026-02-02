# Tests Locaux du Helm Chart avec K3s

Ce guide explique comment tester le Helm chart Starlake localement avec K3s (Kubernetes léger).

## Pourquoi K3s ?

- ✅ **Léger** : 50 Mo vs 500+ Mo pour Minikube
- ✅ **Rapide** : Démarre en quelques secondes
- ✅ **Complet** : Support Ingress, LoadBalancer (via Traefik), storage local
- ✅ **Production-like** : Architecture identique à un vrai cluster
- ✅ **Multi-plateforme** : macOS, Linux, Windows (WSL2)

## Installation de K3s

### macOS / Linux

```bash
# Installer k3s via k3d (K3s in Docker - plus simple sur macOS)
brew install k3d

# Ou télécharger directement
# curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

### Windows (WSL2)

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

### Vérifier l'installation

```bash
k3d version
# Exemple de sortie: k3d version v5.6.0
```

## Création du Cluster de Test

### Option 1 : Cluster Basique

```bash
# Créer un cluster K3s simple
k3d cluster create starlake-test \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer"

# Vérifier que kubectl est configuré
kubectl cluster-info
kubectl get nodes
```

### Option 2 : Cluster avec Configuration Avancée

```bash
# Créer un cluster avec plus de ressources
k3d cluster create starlake-test \
  --agents 3 \
  --servers 1 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --volume "$(pwd)/projects:/projects@all"

# Note: On désactive Traefik si on veut utiliser NGINX Ingress
```

## Multi-Node Clusters and local-path Storage Limitations

When using K3d with multiple nodes and the default `local-path` storage class, there are important limitations to understand.

### The Problem

The `local-path` storage provisioner in K3s has the following behavior:

1. **Node Affinity**: PersistentVolumes are created with node affinity - the volume is physically stored on one specific node
2. **First Consumer Binding**: The PV binds to whichever node first creates a pod that uses the PVC
3. **No Cross-Node Access**: Pods on other nodes cannot access the volume

This creates issues in multi-node clusters:

```
Example scenario:
- PVC is created and bound to agent-0 (first pod scheduled there)
- Gizmo pod with hostNetwork needs to run on server-0 (where ports are mapped)
- Gizmo cannot start because the PVC is only accessible on agent-0
```

### K3d Port Mapping and hostNetwork

K3d port mapping (e.g., `--port "11900:11900@server:0"`) forwards traffic from the host to a specific node:

- `@server:0` - Forward to the first server node
- `@loadbalancer` - Forward to the built-in load balancer (for HTTP/HTTPS)
- `@agent:0` - Forward to the first agent node

When a service uses `hostNetwork: true` (like Gizmo for Arrow Flight SQL), the pod must run on the node where the port is mapped. But if the PVC is bound to a different node, there's a conflict.

### Solutions

#### Solution 1: Single-Node Cluster (Recommended for Development)

The simplest solution is to use a single-node cluster where there's no node affinity conflict:

```bash
k3d cluster create starlake-test \
  --servers 1 \
  --agents 0 \
  --port "8080:80@loadbalancer" \
  --port "11900-11920:11900-11920@server:0"
```

This is the recommended approach for local development and testing.

#### Solution 2: Use port-forward for Gizmo

In multi-node clusters, use `kubectl port-forward` instead of hostNetwork port mapping:

```bash
# Start the cluster without Gizmo-specific port mappings
k3d cluster create starlake-test --servers 1 --agents 2 --port "8080:80@loadbalancer"

# After deployment, port-forward to Gizmo
kubectl port-forward deploy/starlake-gizmo 11900:11900 -n starlake
```

#### Solution 3: RWX Storage (Production Approach)

For production or production-like testing, use a storage class that supports ReadWriteMany:

- **NFS Provisioner**: Works in any environment
- **AWS EFS**: For EKS clusters
- **GCP Filestore**: For GKE clusters
- **Azure Files**: For AKS clusters

With RWX storage, any pod on any node can access the volume.

### Gizmo Connection Details

When using port-forward or hostNetwork, connect to Gizmo using:

```
JDBC URL: jdbc:arrow-flight-sql://localhost:11900?useEncryption=true&disableCertificateVerification=true
Username: gizmosql_user
Password: gizmosql_password
```

For DBeaver or other SQL clients:
1. Install the Arrow Flight SQL JDBC driver
2. Use the connection URL above
3. Enable SSL but disable certificate verification (for development)

### Summary Table

| Cluster Type | Storage | Gizmo Access Method | Complexity |
|-------------|---------|---------------------|------------|
| Single-node K3d | local-path | hostNetwork (direct) | Simple |
| Multi-node K3d | local-path | port-forward | Medium |
| Multi-node K3d | NFS | hostNetwork (direct) | Medium |
| Production (EKS/GKE/AKS) | EFS/Filestore/Azure Files | Ingress or LoadBalancer | Production-ready |

## Installation des Prérequis

### 1. Installer Helm (si pas déjà fait)

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Vérifier
helm version
```

### 2. Installer un Storage Provisioner (pour ReadWriteMany)

K3s inclut local-path-provisioner par défaut (ReadWriteOnce uniquement).
Pour ReadWriteMany, on installe NFS provisioner :

```bash
# Ajouter le repo Helm
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/

# Pour K3s, on utilise un NFS server local
# Option A : Installer NFS server sur l'hôte (recommandé)

# macOS (NFS est déjà intégré, juste besoin de le configurer)
sudo mkdir -p /System/Volumes/Data/nfs/starlake-projects
# Ajouter à /etc/exports:
echo "/System/Volumes/Data/nfs/starlake-projects -alldirs -mapall=$(id -u):$(id -g) localhost" | sudo tee -a /etc/exports
# Redémarrer NFS
sudo nfsd restart

# Linux
sudo apt-get install nfs-kernel-server
sudo mkdir -p /srv/nfs/starlake-projects
sudo chown nobody:nogroup /srv/nfs/starlake-projects
echo "/srv/nfs/starlake-projects *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo systemctl restart nfs-kernel-server

# Option B : Utiliser le provisioner local de K3s avec un workaround
# (moins idéal mais fonctionne pour les tests)
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-rwx
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  pathPattern: "/projects"
EOF
```

### 3. Installer NFS Provisioner (si NFS server disponible)

```bash
# Installer le provisioner avec l'IP de votre machine
# Obtenir l'IP locale
export HOST_IP=$(hostname -I | awk '{print $1}')  # Linux
export HOST_IP=$(ipconfig getifaddr en0)          # macOS

helm install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace kube-system \
  --set nfs.server=$HOST_IP \
  --set nfs.path=/srv/nfs/starlake-projects \
  --set storageClass.name=nfs-client \
  --set storageClass.defaultClass=false

# Vérifier
kubectl get storageclass
```

## Test du Helm Chart

### Étape 1 : Valider le Chart Localement

```bash
cd /path/to/starlake-data-stack

# Lint le chart
helm lint ./helm/starlake

# Dry-run pour voir les manifests générés
helm install starlake-test ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --dry-run --debug > /tmp/starlake-manifests.yaml

# Vérifier le fichier généré
less /tmp/starlake-manifests.yaml
```

### Étape 2 : Déployer avec PostgreSQL Interne

```bash
# Créer le namespace
kubectl create namespace starlake

# Installer avec configuration de test
helm install starlake ./helm/starlake \
  --namespace starlake \
  --set postgresql.internal.persistence.size=2Gi \
  --set persistence.projects.size=5Gi \
  --set persistence.projects.storageClass=nfs-client \
  --set ui.resources.requests.memory=256Mi \
  --set ui.resources.limits.memory=1Gi \
  --set airflow.webserver.resources.requests.memory=256Mi \
  --set airflow.webserver.resources.limits.memory=1Gi \
  --set agent.resources.requests.memory=128Mi \
  --set agent.resources.limits.memory=512Mi

# Alternative : Utiliser le fichier values-development.yaml
helm install starlake ./helm/starlake \
  --namespace starlake \
  --values ./helm/starlake/values-development.yaml \
  --set persistence.projects.storageClass=nfs-client
```

### Étape 3 : Suivre le Déploiement

```bash
# Voir les pods en cours de création
kubectl get pods -n starlake -w

# Voir les logs d'un pod spécifique
kubectl logs -n starlake -l app.kubernetes.io/component=postgresql -f

# Voir tous les événements
kubectl get events -n starlake --sort-by='.lastTimestamp'

# Vérifier les PVCs
kubectl get pvc -n starlake
```

### Étape 4 : Tester l'Accès

#### Option A : Port-Forward (Simple et Recommandé)

```bash
# Port-forward vers l'UI (point d'entrée principal)
# L'UI proxie automatiquement /airflow vers le service Airflow interne
kubectl port-forward svc/starlake-ui 8080:80 -n starlake

# Ouvrir dans le navigateur
open http://localhost:8080          # UI Starlake
open http://localhost:8080/airflow  # Airflow (via proxy UI)

# Credentials Airflow par défaut : airflow / airflow
```

> **Note** : L'UI agit comme reverse proxy pour Airflow. Un seul port-forward suffit pour accéder aux deux services sur le même port.

#### Option B : LoadBalancer (K3s inclut un LoadBalancer)

```bash
# Obtenir l'IP externe (sera localhost ou 127.0.0.1)
kubectl get svc starlake-ui -n starlake

# Accéder via le port mappé lors de la création du cluster
open http://localhost:8080
```

### Étape 5 : Tests Fonctionnels

```bash
# 1. Tester la connexion PostgreSQL
kubectl exec -it starlake-postgresql-0 -n starlake -- \
  psql -U dbuser -d starlake -c "SELECT version();"

# 2. Vérifier les bases de données
kubectl exec -it starlake-postgresql-0 -n starlake -- \
  psql -U dbuser -c "\l"

# 3. Tester la connectivité UI → PostgreSQL
kubectl exec -it deployment/starlake-ui -n starlake -- \
  nc -zv starlake-postgresql 5432

# 4. Vérifier les health checks
kubectl get pods -n starlake -o wide
kubectl describe pod starlake-ui-xxxxx -n starlake | grep -A 10 "Liveness\|Readiness"

# 5. Tester les API (avec port-forward sur 8080)
# Health check UI
curl http://localhost:8080/api/v1/health

# Health check Airflow (via proxy UI)
curl http://localhost:8080/airflow/health
```

### Étape 6 : Test avec PostgreSQL Externe (Simulation)

```bash
# Créer un PostgreSQL externe dans le cluster (pour simuler RDS)
kubectl run postgres-external \
  --image=postgres:17 \
  --env="POSTGRES_PASSWORD=external123" \
  --env="POSTGRES_USER=externaluser" \
  --env="POSTGRES_DB=starlake" \
  -n starlake

# Exposer comme service
kubectl expose pod postgres-external \
  --port=5432 \
  --name=postgres-external \
  -n starlake

# Attendre que le pod soit prêt
kubectl wait --for=condition=ready pod/postgres-external -n starlake --timeout=60s

# Réinstaller Starlake avec PostgreSQL externe
helm uninstall starlake -n starlake

helm install starlake ./helm/starlake \
  --namespace starlake \
  --set postgresql.external.enabled=true \
  --set postgresql.external.host=postgres-external \
  --set postgresql.internal.enabled=false \
  --set postgresql.credentials.username=externaluser \
  --set postgresql.credentials.password=external123 \
  --set persistence.projects.storageClass=nfs-client
```

## Tests de Mise à Jour (Upgrade)

```bash
# Modifier une valeur (ex: changer le nombre de replicas UI)
helm upgrade starlake ./helm/starlake \
  --namespace starlake \
  --reuse-values \
  --set ui.replicas=2

# Voir l'historique
helm history starlake -n starlake

# Rollback si nécessaire
helm rollback starlake -n starlake
```

## Tests de Performance (Optionnel)

```bash
# Stress test simple sur l'UI
kubectl run -it --rm load-test \
  --image=busybox \
  --restart=Never \
  -- sh -c 'while true; do wget -q -O- http://starlake-ui.starlake.svc/api/v1/health; done'

# Voir l'utilisation des ressources
kubectl top pods -n starlake
kubectl top nodes
```

## Checklist de Tests

- [ ] PostgreSQL démarre et est accessible
- [ ] UI démarre et se connecte à PostgreSQL
- [ ] Airflow démarre (webserver + scheduler)
- [ ] Agent démarre
- [ ] Health checks passent pour tous les pods
- [ ] PVC projects est créé avec ReadWriteMany
- [ ] Logs sont accessibles via `kubectl logs`
- [ ] Port-forward fonctionne
- [ ] LoadBalancer fonctionne (si configuré)
- [ ] Upgrade/rollback fonctionnent
- [ ] PostgreSQL externe fonctionne (test de simulation)

## Nettoyage

```bash
# Supprimer le release Helm
helm uninstall starlake -n starlake

# Supprimer les PVCs (optionnel)
kubectl delete pvc -l app.kubernetes.io/instance=starlake -n starlake

# Supprimer le namespace
kubectl delete namespace starlake

# Supprimer le cluster K3s
k3d cluster delete starlake-test
```

## Dépannage

### Pods en CrashLoopBackOff

```bash
# Voir les logs du pod
kubectl logs <pod-name> -n starlake --previous

# Décrire le pod pour voir les events
kubectl describe pod <pod-name> -n starlake
```

### PVC en Pending

```bash
# Vérifier le PVC
kubectl describe pvc starlake-projects -n starlake

# Vérifier les storage classes
kubectl get storageclass

# Si NFS ne fonctionne pas, utiliser local-path pour les tests
helm upgrade starlake ./helm/starlake \
  --namespace starlake \
  --set persistence.projects.storageClass=local-path \
  --set persistence.projects.size=2Gi
```

### PostgreSQL ne démarre pas

```bash
# Vérifier les logs
kubectl logs starlake-postgresql-0 -n starlake

# Vérifier le PVC
kubectl get pvc -n starlake | grep postgresql

# Supprimer et recréer
helm uninstall starlake -n starlake
kubectl delete pvc data-starlake-postgresql-0 -n starlake
helm install starlake ./helm/starlake --namespace starlake
```

## Automatisation des Tests

Créer un script de test automatisé :

```bash
#!/bin/bash
# test-helm-chart.sh

set -e

echo "🧪 Test du Helm Chart Starlake"

# 1. Créer le cluster
echo "📦 Création du cluster K3s..."
k3d cluster create starlake-test --agents 2 --port "8080:80@loadbalancer"

# 2. Installer le chart
echo "🚀 Installation du chart..."
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --values ./helm/starlake/values-development.yaml \
  --wait --timeout 10m

# 3. Vérifier les pods
echo "✅ Vérification des pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=starlake -n starlake --timeout=5m

# 4. Tests fonctionnels
echo "🔍 Tests fonctionnels..."

# Test PostgreSQL
kubectl exec starlake-postgresql-0 -n starlake -- psql -U dbuser -d starlake -c "SELECT 1" > /dev/null
echo "  ✓ PostgreSQL OK"

# Test UI health
kubectl port-forward svc/starlake-ui 8080:80 -n starlake &
sleep 5
curl -f http://localhost:8080/api/v1/health > /dev/null
echo "  ✓ UI Health OK"
kill %1

# 5. Nettoyage
echo "🧹 Nettoyage..."
helm uninstall starlake -n starlake
k3d cluster delete starlake-test

echo "✅ Tous les tests ont réussi !"
```

Rendre le script exécutable :
```bash
chmod +x helm/test-helm-chart.sh
./helm/test-helm-chart.sh
```

## Intégration Continue (CI)

Exemple de GitHub Actions workflow :

```yaml
# .github/workflows/test-helm.yml
name: Test Helm Chart

on:
  pull_request:
    paths:
      - 'helm/**'
  push:
    branches:
      - main

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install k3d
        run: curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

      - name: Install Helm
        uses: azure/setup-helm@v3

      - name: Create K3s cluster
        run: k3d cluster create test --agents 2

      - name: Lint Helm chart
        run: helm lint ./helm/starlake

      - name: Install chart
        run: |
          helm install starlake ./helm/starlake \
            --namespace starlake \
            --create-namespace \
            --values ./helm/starlake/values-development.yaml \
            --wait --timeout 10m

      - name: Test pods are running
        run: |
          kubectl wait --for=condition=ready pod \
            -l app.kubernetes.io/instance=starlake \
            -n starlake --timeout=5m

      - name: Cleanup
        if: always()
        run: k3d cluster delete test
```

## Prochaines Étapes

Après validation locale avec K3s :

1. **Tester sur un vrai cluster** (EKS, GKE, AKS)
2. **Configurer monitoring** (Prometheus, Grafana)
3. **Mettre en place CI/CD** (ArgoCD, Flux)
4. **Documenter les cas d'usage production**
5. **Publier le chart** (sur un Helm repository)
