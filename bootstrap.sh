#!/bin/bash
# Clone the gateway and the broker side by side, then print the install command.
# Usage: bash bootstrap.sh [destination]
set -euo pipefail

ROOT="${1:-$HOME/meshlink}"
mkdir -p "$ROOT"

if [ ! -d "$ROOT/broker/.git" ]; then
    git clone https://github.com/meshlinkfoundation/broker.git "$ROOT/broker"
else
    echo "broker already exists at $ROOT/broker"
fi

if [ ! -d "$ROOT/meshlink-wifi-gateway/.git" ]; then
    git clone https://github.com/meshlinkfoundation/meshlink-wifi-gateway.git "$ROOT/meshlink-wifi-gateway"
else
    echo "meshlink-wifi-gateway already exists at $ROOT/meshlink-wifi-gateway"
fi

echo ""
echo "Checkouts are ready."
echo "  cd $ROOT/meshlink-wifi-gateway"
echo "  bash install.sh"
echo ""
echo "The installer finds the broker at $ROOT/broker."
echo "Pass --broker-dir if you keep the checkouts somewhere else."
echo ""
echo "The installer sets the WiFi country to US."
echo "The operator dashboard runs on this Pi at http://<pi-lan-ip>:3000/admin."
echo "To manage it from another network, set up Tailscale on the Pi (see README)."
