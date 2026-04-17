# Starlake Data Stack on AWS: Deployment Guide

This guide explains how to deploy the Starlake Data Stack to Amazon Web Services (AWS) using Terraform.

## Prerequisites

1.  **AWS Account**: You need an active AWS account.
2.  **Terraform Installed**: Ensure Terraform is installed on your local machine.
3.  **AWS Credentials**: Authenticate your local environment with AWS (e.g., `aws configure` or set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`).
4.  **SSH Key Pair**: Ensure you have an SSH public key at `~/.ssh/id_rsa.pub` or specify its path via `public_key_path`.

## Configuration Variables

The deployment is highly customizable via Terraform variables (`variables.tf`):

| Variable          | Description                                      | Default                                                  |
| :---------------- | :----------------------------------------------- | :------------------------------------------------------- |
| `region`          | AWS Region to deploy to.                         | `us-east-1`                                              |
| `instance_type`   | EC2 Instance Type.                               | `t3.xlarge`                                              |
| `volume_size`     | Root volume size in GB.                          | `50`                                                     |
| `repo_url`        | Git repository URL to clone.                     | `https://github.com/starlake-ai/starlake-data-stack.git` |
| `repo_branch`     | Git branch to checkout.                          | `main`                                                   |
| `repo_tag`        | Git tag to checkout (overrides branch).          | `""`                                                     |
| `enable_https`    | Enable Caddy for HTTPS.                          | `false`                                                  |
| `domain_name`     | Domain name for SSL (required if HTTPS enabled). | `""`                                                     |
| `email`           | Email for Let's Encrypt registration.            | `""`                                                     |
| `reserve_ip`      | Reserve an Elastic IP (EIP) address.             | `false`                                                  |
| `public_key_path` | Path to public SSH key.                          | `~/.ssh/id_rsa.pub`                                      |

## Deployment Scenarios

### 1. Basic Deployment

Deploys the stack on port 80.

```bash
cd terraform/aws
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

1.  Note the `instance_public_ip` (or DNS) from the output.
2.  Wait a few minutes for the VM startup script to finish.
3.  Access via browser: `http://<instance_public_ip>` or `https://<domain_name>`

## Troubleshooting

Connect via SSH:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@<instance_public_ip>
```

Check logs:

```bash
sudo tail -f /var/log/cloud-init-output.log
```
