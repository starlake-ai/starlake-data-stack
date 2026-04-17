# Starlake Data Stack on Scaleway: Deployment Guide

This guide explains how to deploy the Starlake Data Stack to Scaleway using Terraform.

## Prerequisites

1.  **Scaleway Account**: You need an active Scaleway Project.
2.  **Terraform Installed**: Ensure Terraform is installed on your local machine.
3.  **Scaleway Credentials**: Set `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, and `SCW_DEFAULT_PROJECT_ID` environment variables or configure your profile.
4.  **SSH Key**: Ensure your SSH public key is added to your Scaleway project.

## Configuration Variables

The deployment is highly customizable via Terraform variables (`variables.tf`):

| Variable        | Description                                      | Default                                                  |
| :-------------- | :----------------------------------------------- | :------------------------------------------------------- |
| `region`        | Scaleway Region.                                 | `fr-par`                                                 |
| `zone`          | Scaleway Zone.                                   | `fr-par-1`                                               |
| `instance_type` | Instance Type.                                   | `DEV1-L` (Consider `GP1-M` for prod)                     |
| `image`         | Instance Image.                                  | `ubuntu_jammy`                                           |
| `repo_url`      | Git repository URL to clone.                     | `https://github.com/starlake-ai/starlake-data-stack.git` |
| `repo_branch`   | Git branch to checkout.                          | `main`                                                   |
| `enable_https`  | Enable Caddy for HTTPS.                          | `false`                                                  |
| `domain_name`   | Domain name for SSL (required if HTTPS enabled). | `""`                                                     |
| `email`         | Email for Let's Encrypt registration.            | `""`                                                     |
| `reserve_ip`    | Reserve a flexible IP.                           | `false`                                                  |

## Deployment Scenarios

### 1. Basic Deployment

Deploys the stack with default settings.

```bash
cd terraform/scaleway
terraform init
terraform apply
```

### 2. HTTPS Deployment with Custom Domain

Deploys the stack with Caddy handling valid SSL certificates.

```bash
terraform apply \
  -var="enable_https=true" \
  -var="domain_name=starlake.example.com" \
  -var="email=admin@example.com" \
  -var="reserve_ip=true"
```

## Accessing the Application

After `terraform apply` completes:

1.  Note the `instance_ip` from the output.
2.  Wait a few minutes for the VM startup script to finish.
3.  Access via browser: `http://<instance_ip>` or `https://<domain_name>`

## Troubleshooting

Connect via SSH:

```bash
ssh root@<instance_ip>
```

Check logs:

```bash
tail -f /var/log/cloud-init-output.log
```
