# Starlake Helm Chart

[![Helm](https://img.shields.io/badge/Helm-3.0%2B-blue?logo=helm)](https://helm.sh)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.19%2B-blue?logo=kubernetes)](https://kubernetes.io)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Deploy the **Starlake Data Stack** on Kubernetes with Airflow as orchestrator.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        Ingress / LB                         │
└─────────────────────────────┬───────────────────────────────┘
                              │
                    ┌─────────▼──────────┐
                    │    Starlake UI     │  Port 80
                    │  (Main Entry Point)│  Handles /airflow proxy
                    └─────────┬──────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
  ┌─────▼─────┐        ┌─────▼─────┐        ┌─────▼─────┐
  │  Airflow  │        │   Agent   │        │   Gizmo   │
  │  :8080    │        │   :8000   │        │  :10900   │
  └─────┬─────┘        └─────┬─────┘        └───────────┘
        │                    │
        └────────┬───────────┘
           ┌─────▼─────┐
           │ PostgreSQL│
           │   :5432   │
           └───────────┘

  ┌─────────────────────────────────────────────────────────┐
  │               Shared Storage (PVC - RWX)                │
  │                     /projects                           │
  │  ┌──────────────────────────────────────────────────┐   │
  │  │  Projects │ DAGs │ DuckDB files │ Configurations │   │
  │  └──────────────────────────────────────────────────┘   │
  │         ▲                              ▲                │
  │         │                              │                │
  │    Starlake UI                    Airflow               │
  │   (read/write)                  (read DAGs)             │
  └─────────────────────────────────────────────────────────┘
```

## Features

- **Flexible PostgreSQL** - Internal StatefulSet or external managed database (RDS, CloudSQL, Azure Database)
- **Shared Storage** - PVC with ReadWriteMany for projects shared between UI and Airflow
- **Integrated Services** - Starlake UI (with reverse proxy), Airflow, AI Agent, Gizmo
- **Health Probes** - Startup, liveness, and readiness probes for all services
- **Secrets Management** - Support for existing Kubernetes secrets or inline credentials
- **Demo Mode** - Pre-configured demo projects for quick evaluation

## Prerequisites

| Requirement | Version | Notes |
|------------|---------|-------|
| Kubernetes | 1.19+ | EKS, GKE, AKS, or on-premise |
| Helm | 3.0+ | [Installation guide](https://helm.sh/docs/intro/install/) |
| Storage Class | RWX | NFS, EFS, Filestore, Azure Files |
| Ingress Controller | Optional | NGINX, Traefik, ALB, GCE |

## Quick Start

### Option 1: Development (Internal PostgreSQL)

```bash
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace
```

### Option 2: Production (External PostgreSQL)

```bash
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --set postgresql.external.enabled=true \
  --set postgresql.external.host=my-postgres.example.com \
  --set postgresql.internal.enabled=false \
  --set postgresql.credentials.existingSecret=my-postgres-secret
```

### Option 3: With Ingress

```bash
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --set ingress.enabled=true \
  --set ingress.host=starlake.mycompany.com \
  --set ingress.className=nginx \
  --set ui.service.type=ClusterIP
```

### Access the Application

```bash
# Port-forward (UI proxies /airflow automatically)
kubectl port-forward svc/starlake-ui 8080:80 -n starlake

# Open in browser
# UI:      http://localhost:8080
# Airflow: http://localhost:8080/airflow (credentials: airflow/airflow)
```

> **Note**: The UI acts as a reverse proxy for Airflow. A single port-forward provides access to both services.

## Configuration

### PostgreSQL Options

<details>
<summary><b>Internal PostgreSQL (Default)</b></summary>

Deploys a PostgreSQL StatefulSet within the cluster:

```yaml
postgresql:
  external:
    enabled: false
  internal:
    enabled: true
    persistence:
      size: 50Gi
      storageClass: "standard"
  credentials:
    username: dbuser
    password: dbuser123  # Change in production!
```

**Pros**: Simple, all-in-one deployment
**Cons**: Requires backup management, no native HA

</details>

<details>
<summary><b>External PostgreSQL (Recommended for Production)</b></summary>

Uses a managed database service:

```yaml
postgresql:
  external:
    enabled: true
    host: "my-rds.abc123.us-east-1.rds.amazonaws.com"
    port: 5432
    starlakeDatabase: starlake
    airflowDatabase: airflow
  internal:
    enabled: false
  credentials:
    existingSecret: my-postgres-secret
    usernameKey: postgres-user
    passwordKey: postgres-password
```

**Pros**: HA, automatic backups, better performance
**Cons**: Additional cost

</details>

### Storage Configuration

The `projects` PVC must support **ReadWriteMany** access mode.

| Cloud Provider | Storage Class | Notes |
|---------------|---------------|-------|
| AWS | `efs-sc` | Requires EFS CSI driver |
| GCP | `filestore-csi` | Minimum 1TB |
| Azure | `azurefile` | Premium recommended |
| On-premise | `nfs-client` | Requires NFS provisioner |

```yaml
persistence:
  projects:
    enabled: true
    storageClass: "efs-sc"
    size: 100Gi
```

### Secrets Management

<details>
<summary><b>Using Existing Kubernetes Secret (Recommended)</b></summary>

```bash
# Create secret
kubectl create secret generic my-postgres-secret \
  --from-literal=postgres-user=dbuser \
  --from-literal=postgres-password=SecurePassword123 \
  -n starlake
```

```yaml
postgresql:
  credentials:
    existingSecret: my-postgres-secret
    usernameKey: postgres-user
    passwordKey: postgres-password
```

</details>

<details>
<summary><b>Inline Credentials (Development Only)</b></summary>

```yaml
postgresql:
  credentials:
    username: dbuser
    password: my-password
```

⚠️ **Warning**: Not recommended for production environments.

</details>

### Demo Mode

Enable demo projects for quick evaluation:

```bash
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --set demo.enabled=true
```

This automatically initializes:
- Demo projects (tpch001, starbake, etc.)
- DuckLake databases with sample data
- Pre-configured Airflow DAGs

Access with: `admin@localhost.local`

## Deployment Examples

<details>
<summary><b>AWS (EKS + RDS + EFS)</b></summary>

> **Note**: This configuration is provided as a reference. Ingress and multi-replica setups require validation in your environment.

```yaml
# values-aws.yaml
postgresql:
  external:
    enabled: true
    host: my-rds.abc123.us-east-1.rds.amazonaws.com
  internal:
    enabled: false
  credentials:
    existingSecret: starlake-postgres-secret

persistence:
  projects:
    storageClass: efs-sc
    size: 200Gi

ui:
  service:
    type: ClusterIP

airflow:
  admin:
    password: "ChangeThisPassword!"
```

```bash
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --values values-aws.yaml
```

</details>

<details>
<summary><b>GCP (GKE + CloudSQL + Filestore)</b></summary>

> **Note**: This configuration is provided as a reference. Ingress and multi-replica setups require validation in your environment.

```yaml
# values-gcp.yaml
postgresql:
  external:
    enabled: true
    host: 10.1.2.3  # CloudSQL private IP
  internal:
    enabled: false

persistence:
  projects:
    storageClass: filestore-csi
    size: 1Ti  # Filestore minimum

serviceAccount:
  create: true
  annotations:
    iam.gke.io/gcp-service-account: starlake-sa@PROJECT.iam.gserviceaccount.com
```

</details>

<details>
<summary><b>Local Testing (K3s/K3d)</b></summary>

```bash
# Create cluster
k3d cluster create starlake-test --servers 1 --agents 0 --port "8080:80@loadbalancer"

# Install chart
helm install starlake ./helm/starlake \
  --namespace starlake \
  --create-namespace \
  --set postgresql.internal.persistence.storageClass=local-path \
  --set persistence.projects.storageClass=local-path \
  --set ui.service.type=ClusterIP \
  --set ui.frontendUrl=http://localhost:8080 \
  --set airflow.baseUrl=http://localhost:8080/airflow

# Access
kubectl port-forward svc/starlake-ui 8080:80 -n starlake
```

</details>

## Parameters Reference

### Global

| Parameter | Description | Default |
|-----------|-------------|---------|
| `nameOverride` | Override chart name | `""` |
| `fullnameOverride` | Override full name | `""` |

### PostgreSQL

| Parameter | Description | Default |
|-----------|-------------|---------|
| `postgresql.external.enabled` | Use external PostgreSQL | `false` |
| `postgresql.external.host` | External PostgreSQL host | `""` |
| `postgresql.external.port` | External PostgreSQL port | `5432` |
| `postgresql.internal.enabled` | Deploy internal PostgreSQL | `true` |
| `postgresql.internal.persistence.size` | PostgreSQL PVC size | `50Gi` |
| `postgresql.credentials.username` | PostgreSQL username | `dbuser` |
| `postgresql.credentials.password` | PostgreSQL password | `dbuser123` |
| `postgresql.credentials.existingSecret` | Use existing secret | `""` |

### Starlake UI

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ui.enabled` | Enable UI | `true` |
| `ui.replicas` | Number of replicas | `1` |
| `ui.appType` | App type (`ducklake` or `web`) | `ducklake` |
| `ui.frontendUrl` | Frontend URL override (for port-forward) | `""` |
| `ui.service.type` | Service type | `LoadBalancer` |
| `ui.service.port` | Service port | `80` |
| `ui.resources.requests.memory` | Memory request | `1Gi` |
| `ui.resources.limits.memory` | Memory limit | `4Gi` |

### Airflow

| Parameter | Description | Default |
|-----------|-------------|---------|
| `airflow.enabled` | Enable Airflow | `true` |
| `airflow.version` | Airflow version (2 or 3) | `2` |
| `airflow.baseUrl` | Base URL override (for redirects) | `""` |
| `airflow.admin.username` | Admin username | `airflow` |
| `airflow.admin.password` | Admin password | `airflow` |
| `airflow.webserver.replicas` | Webserver replicas | `1` |
| `airflow.webserver.resources.requests.memory` | Memory request | `4Gi` |
| `airflow.webserver.resources.limits.memory` | Memory limit | `16Gi` |
| `airflow.secretKey` | Webserver session secret key | `starlake-airflow-...` |

### Agent & Gizmo

| Parameter | Description | Default |
|-----------|-------------|---------|
| `agent.enabled` | Enable AI Agent | `true` |
| `agent.replicas` | Number of replicas | `1` |
| `gizmo.enabled` | Enable Gizmo SQL service | `false` |
| `gizmo.replicas` | Number of replicas | `1` |

### Ingress

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ingress.enabled` | Enable Ingress | `false` |
| `ingress.className` | Ingress class | `nginx` |
| `ingress.host` | Ingress hostname | `starlake.example.com` |
| `ingress.tls.enabled` | Enable TLS | `false` |
| `ingress.tls.secretName` | TLS secret name | `starlake-tls` |

### Demo

| Parameter | Description | Default |
|-----------|-------------|---------|
| `demo.enabled` | Enable demo projects | `false` |

For the complete list, see [values.yaml](values.yaml).

## Upgrading

```bash
# Upgrade with new values file (recommended)
helm upgrade starlake ./helm/starlake \
  --namespace starlake \
  --values values-production.yaml

# Upgrade with specific value overrides
helm upgrade starlake ./helm/starlake \
  --namespace starlake \
  --set airflow.webserver.resources.limits.memory=16Gi

# View history
helm history starlake -n starlake

# Rollback if needed
helm rollback starlake 1 -n starlake
```

> **Warning**: Avoid using `--reuse-values` when you want to pick up new defaults from `values.yaml`. This flag preserves previously set values, which may override updated defaults.

## Uninstalling

```bash
# Remove the release
helm uninstall starlake -n starlake

# Remove PVCs (optional - this deletes data!)
kubectl delete pvc -l app.kubernetes.io/instance=starlake -n starlake

# Remove namespace
kubectl delete namespace starlake
```

## Troubleshooting

<details>
<summary><b>Pods stuck in Pending state</b></summary>

Check PVC status:
```bash
kubectl get pvc -n starlake
kubectl describe pvc starlake-projects -n starlake
```

Verify storage class supports ReadWriteMany:
```bash
kubectl get storageclass
```

</details>

<details>
<summary><b>PostgreSQL connection errors</b></summary>

Test connectivity:
```bash
kubectl exec -it deployment/starlake-ui -n starlake -- nc -zv starlake-postgresql 5432
```

Check credentials:
```bash
kubectl get secret starlake-postgresql -n starlake -o yaml
```

</details>

<details>
<summary><b>Airflow not starting</b></summary>

Check init container logs:
```bash
kubectl logs -n starlake -l app.kubernetes.io/component=airflow -c init-airflow-db
```

Restart deployment:
```bash
kubectl rollout restart deployment/starlake-airflow -n starlake
```

</details>

<details>
<summary><b>Airflow OOMKilled errors</b></summary>

If the Airflow pod shows `OOMKilled` status, the memory limit is too low. The pod runs webserver + scheduler + Starlake CLI (Java), requiring significant memory.

Check current memory limits:
```bash
kubectl get pod -n starlake -l app.kubernetes.io/component=airflow \
  -o jsonpath='{.items[0].spec.containers[0].resources}'
```

Increase memory via helm upgrade (do NOT use `--reuse-values` to pick up new defaults):
```bash
helm upgrade starlake ./helm/starlake \
  --namespace starlake \
  --set airflow.webserver.resources.requests.memory=4Gi \
  --set airflow.webserver.resources.limits.memory=16Gi
```

Default values: `4Gi` request / `16Gi` limit.

</details>

<details>
<summary><b>Airflow 403 Forbidden when reading logs</b></summary>

If you see "Please make sure that all your Airflow components have the same 'secret_key' configured", the `AIRFLOW__WEBSERVER__SECRET_KEY` is not consistent.

This is automatically handled by the chart via `airflow.secretKey`. For production, generate a new key:
```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

Then set it:
```bash
helm upgrade starlake ./helm/starlake \
  --namespace starlake \
  --reuse-values \
  --set airflow.secretKey="your-generated-secret-key"
```

</details>

<details>
<summary><b>View component logs</b></summary>

```bash
# UI logs
kubectl logs -n starlake -l app.kubernetes.io/component=ui -f

# Airflow logs
kubectl logs -n starlake -l app.kubernetes.io/component=airflow -f

# PostgreSQL logs
kubectl logs -n starlake -l app.kubernetes.io/component=postgresql -f
```

</details>

## Roadmap

The following features are planned but not yet tested in production:

- [ ] **Ingress Support** - Test with NGINX, ALB, GCE, Traefik ingress controllers
- [ ] **Multiple Replicas** - Validate HA setup with RWX storage (EFS, Filestore, Azure Files)
- [ ] **Security Contexts** - Apply pod security standards and network policies
- [ ] **Monitoring** - Add Prometheus metrics and Grafana dashboards
- [ ] **Backup/Restore** - Document backup procedures for PostgreSQL and projects PVC

Contributions to validate and document these features are welcome!

## Contributing

Contributions are welcome! Please read our [Contributing Guide](../../CONTRIBUTING.md) for details.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This Helm chart is distributed under the [Apache License 2.0](../../LICENSE).

## Support

- 📖 **Documentation**: [starlake.ai/docs](https://starlake.ai/docs)
- 🐛 **Issues**: [GitHub Issues](https://github.com/starlake-ai/starlake-data-stack/issues)
- 💬 **Community**: [Slack](https://starlake.slack.com)
- 📧 **Email**: support@starlake.ai

---

Made with ❤️ by the [Starlake](https://starlake.ai) team
