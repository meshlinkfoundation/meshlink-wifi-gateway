#!/bin/bash
# Clone the gateway and the broker side by side, then run the installer.
# Node.js is installed by install.sh. This script does not install it.
# Usage: bash bootstrap.sh [destination] [install.sh options...]
set -euo pipefail

ROOT="${MESHLINK_ROOT:-$HOME/meshlink}"
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
    ROOT="$1"
    shift
fi
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
echo "Checkouts are ready. Starting install.sh"
echo "The installer finds the broker at $ROOT/broker."
echo ""
cd "$ROOT/meshlink-wifi-gateway"
exec bash install.sh "$@"
