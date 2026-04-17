#!/bin/bash

# Update and install dependencies
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https

# Add Docker's official GPG key
sudo mkdir -m 0755 -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi

# Set up the Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Variables passed from Terraform
REPO_URL="${repo_url}"
REPO_BRANCH="${repo_branch}"
REPO_TAG="${repo_tag}"
ENABLE_HTTPS="${enable_https}"
DOMAIN_NAME="${domain_name}"
EMAIL="${email}"

if [ -z "$REPO_URL" ]; then
  REPO_URL="https://github.com/starlake-ai/starlake-data-stack.git"
fi

# Determine checkout target (Tag takes precedence over Branch)
CHECKOUT_TARGET="main"
if [ -n "$REPO_BRANCH" ]; then
    CHECKOUT_TARGET="$REPO_BRANCH"
fi
if [ -n "$REPO_TAG" ]; then
    CHECKOUT_TARGET="$REPO_TAG"
fi

# Clone into /opt/starlake if not exists
if [ ! -d "/opt/starlake" ]; then
    sudo git clone -b "$CHECKOUT_TARGET" "$REPO_URL" /opt/starlake
else
    cd /opt/starlake
    sudo git fetch origin
    sudo git checkout "$CHECKOUT_TARGET"
    sudo git pull origin "$CHECKOUT_TARGET"
fi

# HTTPS / Caddy Configuration
if [ "$ENABLE_HTTPS" = "true" ]; then
    echo "Enabling HTTPS with Caddy..."

    # Install Caddy
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt-get update
    sudo apt-get install -y caddy

    # Configure Caddy
    # If domain provided, use it (auto-HTTPS). Else, catch-all (self-signed/internal).
    if [ -n "$DOMAIN_NAME" ]; then
        CADDY_CONFIG="$DOMAIN_NAME {
    reverse_proxy localhost:8080
    email $EMAIL
}"
    else
        CADDY_CONFIG=":80, :443 {
    reverse_proxy localhost:8080
}"
    fi

    echo "$CADDY_CONFIG" | sudo tee /etc/caddy/Caddyfile
    sudo systemctl reload caddy

    # Set Starlake port to 8080 so Caddy can proxy to it
    export SL_PORT=8080
else
    echo "HTTPS disabled. Running on port 80."
    export SL_PORT=80
fi

# Navigate to the directory
cd /opt/starlake

# Export environment variables for the stack
export COMPOSE_PROFILES=airflow3,gizmo
export SL_API_APP_TYPE=ducklake

# Docker compose up in detached mode
sudo -E docker compose up -d --build
