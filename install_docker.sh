#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Remove any conflicting/community packages (ignore if absent)
apt-get update -y
apt-get purge -y docker.io docker-doc docker-compose docker-compose-v2 \
  podman-docker containerd runc || true
apt-get autoremove -y || true

# Base deps
apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key:
mkdir -p -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc || { echo "Failed to download GPG key"; exit 1; }
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") \
    stable" > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

docker --version
docker compose version || true