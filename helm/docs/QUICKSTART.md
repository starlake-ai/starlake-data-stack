# Guide de Démarrage Rapide - Helm Chart Starlake

Ce guide vous aide à déployer rapidement Starlake sur Kubernetes.

## 🎯 Choix du Scénario

Choisissez le scénario qui correspond à votre situation :

### 1️⃣ Tests Locaux (K3d) - 15 min
Pour tester rapidement Starlake sur votre machine.

### 2️⃣ PostgreSQL Externe (AWS RDS, GCP CloudSQL, etc.) - 30 min
Pour utiliser une base de données managée existante.

### 3️⃣ Déploiement Complet sur Cloud - 1h
Déploiement production-ready sur AWS, GCP ou Azure.

---

## 1️⃣ Tests Locaux avec K3d

Le projet utilise **K3d** (K3s in Docker) pour les tests locaux. Un script automatisé gère tout le cycle de test.

### Prérequis
```bash
# Installer K3d
brew install k3d  # macOS
# ou curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Docker doit être installé et démarré
docker info
```

### Test Rapide (Recommandé)

```bash
cd helm

# Test développement (single-node, credentials par défaut)
./test-helm-chart.sh

# Test production (credentials sécurisés)
./test-helm-chart.sh --production

# Test multi-node avec SeaweedFS (S3 storage)
./test-helm-chart.sh --multi-node --seaweedfs

# Validation sécurité uniquement (rapide, sans cluster)
./test-helm-chart.sh --security-only
```

Le script gère automatiquement :
- Création du cluster K3d avec ports mappés
- Build et import des images locales
- Déploiement Helm avec attente de readiness
- Port-forward pour accès local
- Cleanup à la fin

### Accéder à Starlake

Après `./test-helm-chart.sh`, les URLs sont affichées :
```
  UI:      http://localhost:8080
  Airflow: http://localhost:8080/airflow
  Gizmo:   http://localhost:10900

  Credentials Airflow: airflow / airflow
```

> **Note** : L'UI agit comme reverse proxy pour Airflow. Un seul port suffit pour accéder aux deux services.

### Options du Script de Test

| Option | Description |
|--------|-------------|
| `--production` | Credentials sécurisés, validation activée |
| `--multi-node` | Cluster 1 server + N agents |
| `--seaweedfs` | Stockage S3 (SeaweedFS) |
| `--security-only` | Validation sécurité uniquement |
| `--agents N` | Nombre d'agents (défaut: 3) |

### Important : Cluster Multi-Noeud et local-path Storage

Avec K3d multi-node, `local-path` storage crée des volumes liés à un nœud spécifique :

- **Single-node cluster recommended**: For local testing, use `--servers 1 --agents 0`
- **Gizmo access in multi-node**: Use port-forward instead of hostNetwork:
  ```bash
  kubectl port-forward deploy/starlake-gizmo 11900:11900 -n starlake
  ```
- **Gizmo JDBC connection**:
  ```
  jdbc:arrow-flight-sql://localhost:11900?useEncryption=true&disableCertificateVerification=true
  User: gizmosql_user / Password: gizmosql_password
  ```

For production environments, use RWX storage (EFS, Filestore, Azure Files, NFS).

---

## 2️⃣ Avec PostgreSQL Externe (RDS, CloudSQL, etc.)

### Prérequis

1. **Base de données PostgreSQL** existante et accessible depuis le cluster
2. **Credentials** de connexion
3. **Storage class** supportant ReadWriteMany (EFS, Filestore, Azure Files)

### Exemple avec AWS RDS + EFS

#### Étape 1 : Préparer EFS

```bash
# Installer EFS CSI Driver
kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"

# Créer un EFS file system (via AWS Console ou CLI)
# Note l'ID: fs-abc12345

# Créer le StorageClass
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-abc12345  # Remplacer par votre EFS ID
  directoryPerms: "700"
EOF
```

#### Étape 2 : Créer le Secret PostgreSQL

```bash
kubectl create namespace starlake

kubectl create secret generic starlake-postgres-secret \
  --from-literal=postgres-user=starlake_admin \
  --from-literal=postgres-password="VotreMotDePasseSecure123!" \
  -n starlake
```

#### Étape 3 : Créer values-custom.yaml

```yaml
# values-custom.yaml
postgresql:
  external:
    enabled: true
    host: "my-rds.abc123.us-east-1.rds.amazonaws.com"  # Votre endpoint RDS
    port: 5432
  internal:
    enabled: false
  credentials:
    existingSecret: starlake-postgres-secret

persistence:
  projects:
    storageClass: efs-sc
    size: 100Gi

ui:
  service:
    type: LoadBalancer

airflow:
  admin:
    password: "ChangeMeInProduction!"
```

#### Étape 4 : Déployer

```bash
helm install starlake ./helm/starlake \
  --namespace starlake \
  --values values-custom.yaml
```

#### Étape 5 : Obtenir l'URL d'accès

```bash
# Attendre que le LoadBalancer soit provisionné
kubectl get svc starlake-ui -n starlake -w

# Une fois EXTERNAL-IP disponible
export STARLAKE_URL=$(kubectl get svc starlake-ui -n starlake -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Starlake: http://$STARLAKE_URL"
```

---

## 3️⃣ Déploiement Production avec Ingress

### Prérequis

1. Cluster Kubernetes de production (EKS, GKE, AKS)
2. PostgreSQL managé (RDS, CloudSQL, Azure Database)
3. Storage ReadWriteMany (EFS, Filestore, Azure Files)
4. Ingress Controller installé (NGINX, ALB, GCE)
5. Cert-Manager pour TLS (optionnel mais recommandé)

### Exemple Complet AWS

#### 1. Préparer l'infrastructure

```bash
# Variables
export CLUSTER_NAME=my-eks-cluster
export RDS_ENDPOINT=starlake-db.abc123.us-east-1.rds.amazonaws.com
export EFS_ID=fs-abc12345
export DOMAIN=starlake.mycompany.com
```

#### 2. Installer les prérequis

```bash
# EFS CSI Driver
kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"

# Cert-Manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME
```

#### 3. Créer ClusterIssuer pour Let's Encrypt

```yaml
# letsencrypt-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@mycompany.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: alb
```

```bash
kubectl apply -f letsencrypt-issuer.yaml
```

#### 4. Créer StorageClass EFS

```yaml
# efs-sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
```

```bash
kubectl apply -f efs-sc.yaml
```

#### 5. Créer values-production.yaml

```yaml
# values-production.yaml
postgresql:
  external:
    enabled: true
    host: "starlake-db.abc123.us-east-1.rds.amazonaws.com"
    port: 5432
  internal:
    enabled: false
  credentials:
    existingSecret: starlake-postgres-secret

persistence:
  projects:
    storageClass: efs-sc
    size: 200Gi

# High Availability
ui:
  replicas: 2
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "8Gi"
      cpu: "4000m"

airflow:
  webserver:
    replicas: 2
    resources:
      requests:
        memory: "2Gi"
        cpu: "1000m"
      limits:
        memory: "8Gi"
        cpu: "4000m"
  admin:
    password: "SuperSecurePassword123!"

agent:
  replicas: 2

# Ingress
ui:
  service:
    type: ClusterIP

ingress:
  enabled: true
  className: alb
  host: starlake.mycompany.com
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    enabled: true
    secretName: starlake-tls
```

#### 6. Déployer

```bash
# Créer le secret PostgreSQL
kubectl create secret generic starlake-postgres-secret \
  --from-literal=postgres-user=starlake_admin \
  --from-literal=postgres-password="SuperSecurePassword123!" \
  -n starlake

# Installer Starlake
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --values values-production.yaml
```

#### 7. Vérifier le déploiement

```bash
# Vérifier les pods
kubectl get pods -n starlake

# Vérifier l'Ingress
kubectl get ingress -n starlake

# Obtenir l'URL
kubectl get ingress starlake -n starlake -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

#### 8. Configurer DNS

Créer un CNAME DNS pointant vers l'ALB :

```
starlake.mycompany.com -> k8s-starlake-xxxxx.us-east-1.elb.amazonaws.com
```

Accéder à : `https://starlake.mycompany.com`

---

## 🔍 Vérifications Post-Installation

### Vérifier l'état des pods

```bash
kubectl get pods -n starlake

# Tous les pods doivent être en Running
# Example output:
# NAME                              READY   STATUS    RESTARTS   AGE
# starlake-postgresql-0             1/1     Running   0          5m
# starlake-ui-xxxxx                 1/1     Running   0          4m
# starlake-airflow-xxxxx            1/1     Running   0          4m
# starlake-agent-xxxxx              1/1     Running   0          4m
```

### Vérifier les logs

```bash
# UI
kubectl logs -n starlake -l app.kubernetes.io/component=ui -f

# Airflow
kubectl logs -n starlake -l app.kubernetes.io/component=airflow -f

# PostgreSQL (si interne)
kubectl logs -n starlake -l app.kubernetes.io/component=postgresql -f
```

### Tester la connexion PostgreSQL

```bash
# Si PostgreSQL interne
kubectl exec -it starlake-postgresql-0 -n starlake -- \
  psql -U dbuser -d starlake -c "SELECT version();"

# Lister les bases
kubectl exec -it starlake-postgresql-0 -n starlake -- \
  psql -U dbuser -c "\l"
```

---

## 🛠️ Dépannage Rapide

### Pods en CrashLoopBackOff

```bash
# Voir les logs du pod en erreur
kubectl logs <pod-name> -n starlake --previous

# Décrire le pod pour voir les events
kubectl describe pod <pod-name> -n starlake
```

### PVC en Pending

```bash
# Vérifier le PVC
kubectl describe pvc starlake-projects -n starlake

# Vérifier si le storage class existe
kubectl get storageclass

# Solutions:
# - Vérifier que le provisioner est installé
# - Vérifier que le storage class supporte ReadWriteMany
```

### Impossible de se connecter à PostgreSQL

```bash
# Vérifier la connectivité réseau
kubectl exec -it deployment/starlake-ui -n starlake -- \
  nc -zv starlake-postgresql 5432

# Vérifier les secrets
kubectl get secret starlake-postgresql -n starlake -o yaml

# Vérifier les variables d'environnement
kubectl exec deployment/starlake-ui -n starlake -- env | grep POSTGRES
```

---

## 📚 Prochaines Étapes

1. **Configurer les projets Starlake** : Copier vos projets dans le PVC
2. **Paramétrer Airflow** : Configurer les connexions et variables
3. **Monitoring** : Installer Prometheus + Grafana
4. **Backups** : Configurer Velero pour les backups K8s
5. **CI/CD** : Intégrer avec ArgoCD ou FluxCD

---

## 🆘 Aide

- Documentation complète : [README.md](starlake/README.md)
- Issues GitHub : https://github.com/starlake-ai/starlake-data-stack/issues
- Slack : https://starlake.slack.com
