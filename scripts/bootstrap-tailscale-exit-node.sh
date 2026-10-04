#!/bin/bash
set -eu

TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-aws-exit-node}

hostnamectl set-hostname "$TAILSCALE_HOSTNAME"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
curl -fsSL https://tailscale.com/install.sh | sh

install -m 0644 /dev/null /etc/sysctl.d/99-tailscale.conf
printf '%s\n' \
  'net.ipv4.ip_forward = 1' \
  'net.ipv6.conf.all.forwarding = 1' \
  > /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

systemctl enable --now tailscaled

# Offer exit-node routing. Authentication is completed interactively later,
# so no Tailscale key is stored in user data or instance metadata.
tailscale up --advertise-exit-node --hostname="$TAILSCALE_HOSTNAME" --accept-dns=false || true
