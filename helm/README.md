# Starlake Helm Chart

This directory contains the official Helm chart for deploying the Starlake Data Stack on Kubernetes.

## Documentation

- **[Chart Documentation](starlake/README.md)** - Complete chart documentation (installation, configuration, parameters)
- **[Quick Start Guide](docs/QUICKSTART.md)** - Step-by-step deployment guides
- **[Local Testing](docs/LOCAL_TESTING.md)** - Test locally with K3s/K3d

## Quick Start

```bash
# Automated test script (creates K3s cluster, installs chart, validates)
./test-helm-chart.sh

# Manual installation
helm install starlake ./starlake \
  --namespace starlake \
  --create-namespace
```

## Directory Structure

```
helm/
├── starlake/              # The Helm chart
│   ├── Chart.yaml         # Chart metadata
│   ├── values.yaml        # Default configuration
│   ├── templates/         # Kubernetes templates
│   └── README.md          # Chart documentation
├── docs/                  # Additional documentation
└── test-helm-chart.sh     # Automated test script
```

For full documentation, see [starlake/README.md](starlake/README.md).
