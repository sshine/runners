#!/usr/bin/env bash
set -euo pipefail

if command -v nix &>/dev/null; then
  echo "nix already installed: $(nix --version)"
  exit 0
fi

echo "Installing Nix..."
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --no-daemon

. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true

echo "nix installed: $(nix --version)"
