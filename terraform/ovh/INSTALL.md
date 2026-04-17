# Starlake Data Stack on OVH: Deployment Guide

This guide explains how to deploy the Starlake Data Stack to OVH Public Cloud using Terraform (via OpenStack provider).

## Prerequisites

1.  **OVH Account**: You need an active OVH Public Cloud project.
2.  **Terraform Installed**: Ensure Terraform is installed on your local machine.
3.  **OpenStack Credentials**: Download your OpenRC file from the OVH Horizon interface and source it (`source openrc.sh`).
4.  **SSH Key Pair**: Upload your SSH public key to OpenStack/OVH or ensure you have one to use.

## Configuration Variables

The deployment is highly customizable via Terraform variables (`variables.tf`):

| Variable        | Description                                      | Default                                                  |
| :-------------- | :----------------------------------------------- | :------------------------------------------------------- |
| `region`        | OpenStack Region (e.g., `GRA11`).                | `GRA11`                                                  |
| `service_name`  | OpenStack Project ID (Tenant ID).                | **Required**                                             |
| `flavor_name`   | Instance Flavor (Size).                          | `d2-8`                                                   |
| `image_name`    | Instance Image Name.                             | `Ubuntu 22.04`                                           |
| `key_pair_name` | Name of existing Key Pair in OVH.                | **Required**                                             |
| `network_name`  | Network Name (usually `Ext-Net`).                | `Ext-Net`                                                |
| `repo_url`      | Git repository URL to clone.                     | `https://github.com/starlake-ai/starlake-data-stack.git` |
| `repo_branch`   | Git branch to checkout.                          | `main`                                                   |
| `enable_https`  | Enable Caddy for HTTPS.                          | `false`                                                  |
| `domain_name`   | Domain name for SSL (required if HTTPS enabled). | `""`                                                     |
| `email`         | Email for Let's Encrypt registration.            | `""`                                                     |

## Deployment Scenarios

### 1. Basic Deployment

Deploys the stack with default settings.

```bash
cd terraform/ovh
terraform init
terraform apply \
  -var="service_name=your-project-id" \
  -var="key_pair_name=your-key-name"
```

### 2. HTTPS Deployment with Custom Domain

Deploys the stack with Caddy handling valid SSL certificates.

```bash
terraform apply \
  -var="service_name=your-project-id" \
  -var="key_pair_name=your-key-name" \
  -var="enable_https=true" \
  -var="domain_name=starlake.example.com" \
  -var="email=admin@example.com"
```

## Accessing the Application

After `terraform apply` completes:

1.  Note the `instance_ip` from the output.
2.  Wait a few minutes for the VM startup script to finish.
3.  Access via browser: `http://<instance_ip>` or `https://<domain_name>`

## Troubleshooting

Connect via SSH:

```bash
ssh ubuntu@<instance_ip>
```

Check logs:

```bash
sudo tail -f /var/log/cloud-init-output.log
```
