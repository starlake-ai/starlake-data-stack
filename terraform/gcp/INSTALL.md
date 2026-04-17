# Starlake Data Stack on GCP: Deployment Guide

This guide explains how to deploy the Starlake Data Stack to a Google Cloud Platform (GCP) VM using Terraform.

## Prerequisites

1.  **Google Cloud Platform Account**: You need a GCP project with billing enabled.
2.  **Terraform Installed**: Ensure Terraform is installed on your local machine.
3.  **GCP Credentials**: Authenticate your local environment with GCP (e.g., `gcloud auth application-default login`).

## Configuration Variables

The deployment is highly customizable via Terraform variables (`variables.tf`):

| Variable       | Description                                      | Default                                                  |
| :------------- | :----------------------------------------------- | :------------------------------------------------------- |
| `project_id`   | **Required.** Your GCP Project ID.               | -                                                        |
| `region`       | GCP Region to deploy to.                         | `europe-west1`                                           |
| `zone`         | GCP Zone to deploy to.                           | `europe-west1-b`                                          |
| `machine_type` | VM Machine Type.                                 | `e2-highmem-8`                                           |
| `repo_url`     | Git repository URL to clone.                     | `https://github.com/starlake-ai/starlake-data-stack.git` |
| `repo_branch`  | Git branch to checkout.                          | `main`                                                   |
| `repo_tag`     | Git tag to checkout (overrides branch).          | `""`                                                     |
| `enable_https` | Enable Caddy for HTTPS.                          | `false`                                                  |
| `domain_name`  | Domain name for SSL (required if HTTPS enabled). | `""`                                                     |
| `email`        | Email for Let's Encrypt registration.            | `""`                                                     |
| `reserve_ip`   | Reserve a static external IP address.            | `false`                                                  |

## Deployment Scenarios

### 1. Basic HTTP Deployment

Deploys the stack on port 80.

```bash
cd terraform/gcp
terraform init
terraform apply \
  -var="project_id=your-project-id"
```

### 2. Deployment with Static IP

Reserves a static external IP address for the VM.

```bash
terraform apply \
  -var="project_id=your-project-id" \
  -var="reserve_ip=true"
```

### 3. Deployment with Specific Version (Tag)

Deploys a specific version of the stack defined by a git tag.

```bash
terraform apply \
  -var="project_id=your-project-id" \
  -var="repo_tag=v1.5.0"
```

### 4. HTTPS Deployment with Custom Domain

Deploys the stack with Caddy handling valid SSL certificates for your domain.

```bash
terraform apply \
  -var="project_id=your-project-id" \
  -var="enable_https=true" \
  -var="domain_name=starlake.example.com" \
  -var="email=admin@example.com" \
  -var="reserve_ip=true"
```

> [!IMPORTANT]
> Ensure your domain's DNS `A` record points to the VM's public IP address _before_ Caddy attempts to provision the certificate. You can get the IP from the output of `terraform apply` or by checking the GCP console, then update your DNS, and finally ssh into the box to restart Caddy or just wait for retries.

## Accessing the Application

After `terraform apply` completes:

1.  Note the `instance_ip` from the output.
2.  Wait a few minutes for the VM startup script to finish (Install Docker, Clone Repo, Start Stack).
3.  Access via browser:
    - **HTTP**: `http://<instance_ip>`
    - **HTTPS**: `https://<domain_name>`

## Troubleshooting

- **Check Startup status**:
  SSH into the VM and check the logs.
  ```bash
  gcloud compute ssh --zone "europe-west1-b" "terraform-instance-64gb" --project "your-project-id"
  # Inside VM:
  sudo journalctl -u google-startup-scripts.service -f
  ```
- **Check Docker containers**:
  ```bash
  sudo docker ps
  ```
