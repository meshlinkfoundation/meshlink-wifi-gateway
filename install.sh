#!/bin/bash

# meshlink WiFi Gateway - Access Point + Captive Portal Setup
# Tested on: Raspberry Pi 5, Raspberry Pi OS (Debian 13 Trixie), NetworkManager
#
# Sets up:
#   1. WiFi access point (hostapd)
#   2. DHCP + DNS for clients (dnsmasq)
#   3. NAT so clients get internet
#   4. HTTP redirect to captive portal (iptables REDIRECT port 80 → broker)
#   5. HTTPS for the portal hostname only (never intercept internet :443)
#   6. Boot persistence (systemd service)
#   7. meshlink broker (Node.js captive portal app)
#
# Usage: bash install.sh [--ap-interface IFACE] [--wan-interface IFACE]
#                        [--security open|owe]
#                        [--portal-host HOST] [--tls-cert FILE] [--tls-key FILE]
#        bash install.sh --list-interfaces

set -e

# ─── Configuration ────────────────────────────────────────────────────────────

CONFIG_FILE="/etc/meshlink/gateway.conf"

SSID="meshlink"
AP_IP="192.168.50.1"
AP_NETMASK="255.255.255.0"
DHCP_RANGE_START="192.168.50.10"
DHCP_RANGE_END="192.168.50.100"
DHCP_LEASE="24h"
CHANNEL=6
COUNTRY_CODE="US"
WLAN_IFACE="wlan0"
WAN_IFACE="eth0"
GUEST_BRIDGE="br-guest"
HALOW_IFACE="eth1"
SECURITY_MODE="open"
BROKER_PORT=3000
TLS_PORT=3443
PORTAL_HOST="portal.meshlink"
TLS_CERT="/etc/meshlink/tls/portal.crt"
TLS_KEY="/etc/meshlink/tls/portal.key"
TLS_TRUSTED="0"
TLS_CERT_SRC=""
TLS_KEY_SRC=""

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

usage() {
    cat <<'USAGE'
Usage: bash install.sh [options]

Options:
  --ap-interface IFACE   WiFi adapter used to broadcast the meshlink AP
  --wan-interface IFACE  Internet-facing interface (default: eth0)
  --security MODE        Passwordless security: open or owe (default: open)
  --ssid NAME            Network name to broadcast (1-32 characters)
  --portal-host HOST     Hostname served over HTTPS (default: portal.meshlink)
  --tls-cert FILE        Publicly-trusted certificate (PEM). Implies trusted TLS.
  --tls-key FILE         Matching private key (PEM). Required with --tls-cert.
  --list-interfaces      Show detected network interfaces and exit
  -h, --help             Show this help

The selected interfaces are saved in /etc/meshlink/gateway.conf and reused on
later installer runs. Command-line options override the saved configuration.
USAGE
}

read_saved_setting() {
    local key="$1"
    local line

    [ -r "$CONFIG_FILE" ] || return 0
    line=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n 1) || true
    if [ -n "$line" ]; then
        printf '%s' "${line#*=}"
    fi
    return 0
}

list_interfaces() {
    printf '%-16s %-10s %s\n' "INTERFACE" "TYPE" "DRIVER"
    for path in /sys/class/net/*; do
        [ -e "$path" ] || continue
        local iface type driver
        iface=$(basename "$path")
        if [ -d "$path/wireless" ]; then
            type="wifi"
        else
            type="network"
        fi
        driver=$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)" 2>/dev/null) || true
        printf '%-16s %-10s %s\n' "$iface" "$type" "${driver:--}"
    done
}

validate_interface_name() {
    local label="$1"
    local iface="$2"
    [[ "$iface" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || fail "$label interface name is invalid: $iface"
}

# Reuse the last operator selection unless this is the first install.
SAVED_WLAN_IFACE=$(read_saved_setting MESHLINK_AP_INTERFACE)
SAVED_WAN_IFACE=$(read_saved_setting MESHLINK_WAN_INTERFACE)
SAVED_SECURITY_MODE=$(read_saved_setting MESHLINK_WIFI_SECURITY)
SAVED_SSID=$(read_saved_setting MESHLINK_SSID)
SAVED_PORTAL_HOST=$(read_saved_setting MESHLINK_PORTAL_HOST)
SAVED_TLS_TRUSTED=$(read_saved_setting MESHLINK_TLS_TRUSTED)
[ -n "$SAVED_WLAN_IFACE" ] && WLAN_IFACE="$SAVED_WLAN_IFACE"
[ -n "$SAVED_WAN_IFACE" ] && WAN_IFACE="$SAVED_WAN_IFACE"
[ -n "$SAVED_SECURITY_MODE" ] && SECURITY_MODE="$SAVED_SECURITY_MODE"
[ -n "$SAVED_SSID" ] && SSID="$SAVED_SSID"
[ -n "$SAVED_PORTAL_HOST" ] && PORTAL_HOST="$SAVED_PORTAL_HOST"
[ -n "$SAVED_TLS_TRUSTED" ] && TLS_TRUSTED="$SAVED_TLS_TRUSTED"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ap-interface)
            [ "$#" -ge 2 ] || fail "--ap-interface requires a value"
            WLAN_IFACE="$2"
            shift 2
            ;;
        --wan-interface)
            [ "$#" -ge 2 ] || fail "--wan-interface requires a value"
            WAN_IFACE="$2"
            shift 2
            ;;
        --security)
            [ "$#" -ge 2 ] || fail "--security requires open or owe"
            SECURITY_MODE="$2"
            shift 2
            ;;
        --ssid)
            [ "$#" -ge 2 ] || fail "--ssid requires a network name"
            SSID="$2"
            shift 2
            ;;
        --portal-host)
            [ "$#" -ge 2 ] || fail "--portal-host requires a hostname"
            PORTAL_HOST="$2"
            shift 2
            ;;
        --tls-cert)
            [ "$#" -ge 2 ] || fail "--tls-cert requires a file path"
            TLS_CERT_SRC="$2"
            shift 2
            ;;
        --tls-key)
            [ "$#" -ge 2 ] || fail "--tls-key requires a file path"
            TLS_KEY_SRC="$2"
            shift 2
            ;;
        --list-interfaces)
            list_interfaces
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown option: $1"
            ;;
    esac
done

validate_interface_name "AP" "$WLAN_IFACE"
validate_interface_name "WAN" "$WAN_IFACE"
[ "$WLAN_IFACE" != "$WAN_IFACE" ] || fail "AP and WAN interfaces must be different"
case "$SECURITY_MODE" in
    open)
        SECURITY_DESCRIPTION="Open (captive portal gated; unencrypted WiFi link)"
        HOSTAPD_SECURITY_CONFIG="wpa=0"
        ;;
    owe)
        SECURITY_DESCRIPTION="Enhanced Open / OWE (passwordless encrypted WiFi link)"
        HOSTAPD_SECURITY_CONFIG=$'wpa=2\nwpa_key_mgmt=OWE\nrsn_pairwise=CCMP\nieee80211w=2\nowe_groups=19'
        ;;
    *)
        fail "Unsupported security mode '$SECURITY_MODE'; use open or owe"
        ;;
esac
[[ "$SSID" =~ ^[[:print:]]{1,32}$ ]] || fail "SSID must be 1-32 printable characters"
[[ "$PORTAL_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$ ]] || fail "Invalid --portal-host: $PORTAL_HOST"
if [ -n "$TLS_CERT_SRC" ] || [ -n "$TLS_KEY_SRC" ]; then
    [ -n "$TLS_CERT_SRC" ] && [ -n "$TLS_KEY_SRC" ] || fail "--tls-cert and --tls-key must be used together"
    [ -f "$TLS_CERT_SRC" ] || fail "TLS certificate not found: $TLS_CERT_SRC"
    [ -f "$TLS_KEY_SRC" ] || fail "TLS private key not found: $TLS_KEY_SRC"
    TLS_TRUSTED="1"
fi

# ─── Pre-flight ───────────────────────────────────────────────────────────────

info "meshlink WiFi Gateway Installer"
echo "────────────────────────────────────────"
echo "  SSID:       $SSID"
echo "  Security:   $SECURITY_DESCRIPTION"
echo "  Gateway:    $AP_IP"
echo "  DHCP:       $DHCP_RANGE_START - $DHCP_RANGE_END"
echo "  Channel:    $CHANNEL"
echo "  AP device:  $WLAN_IFACE"
echo "  WAN device: $WAN_IFACE"
echo "  Portal:     http://$AP_IP:$BROKER_PORT"
echo "  HTTPS:      https://$PORTAL_HOST/ ($( [ "$TLS_TRUSTED" = "1" ] && echo trusted || echo self-signed ))"
echo "────────────────────────────────────────"

[ -d "/sys/class/net/$WLAN_IFACE" ] || fail "$WLAN_IFACE not found"
[ -d "/sys/class/net/$WAN_IFACE" ] || fail "$WAN_IFACE not found"
[ -d "/sys/class/net/$WLAN_IFACE/wireless" ] || fail "$WLAN_IFACE is not a wireless interface"

PREVIOUS_WLAN_IFACE="$SAVED_WLAN_IFACE"

# ─── 1. Install packages ─────────────────────────────────────────────────────

info "Installing packages..."
sudo apt update -y
sudo apt install -y hostapd dnsmasq iptables ipset iw rfkill iproute2 openssl
ok "Packages installed"

PHY_NAME=$(basename "$(readlink -f "/sys/class/net/$WLAN_IFACE/phy80211" 2>/dev/null)" 2>/dev/null) || true
[ -n "$PHY_NAME" ] || fail "Could not determine the wireless radio for $WLAN_IFACE"
if ! iw phy "$PHY_NAME" info 2>/dev/null | grep -qE '^[[:space:]]*\* AP$'; then
    fail "$WLAN_IFACE does not report hostapd/AP mode support; check the Alfa chipset driver"
fi

# Persist only validated values. This file is also loaded by the broker service.
sudo mkdir -p /etc/meshlink /etc/meshlink/tls
sudo chmod 755 /etc/meshlink /etc/meshlink/tls

info "Configuring portal TLS..."
if [ -n "$TLS_CERT_SRC" ]; then
    sudo cp "$TLS_CERT_SRC" "$TLS_CERT"
    sudo cp "$TLS_KEY_SRC" "$TLS_KEY"
    TLS_TRUSTED="1"
    ok "Installed operator-provided TLS certificate for $PORTAL_HOST"
elif [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ] && { [ -z "$SAVED_PORTAL_HOST" ] || [ "$PORTAL_HOST" = "$SAVED_PORTAL_HOST" ]; }; then
    ok "Reusing existing portal certificate ($TLS_CERT)"
else
    TLS_TRUSTED="0"
    sudo openssl req -x509 -newkey rsa:2048 -sha256 -days 825 \
        -nodes \
        -keyout "$TLS_KEY" \
        -out "$TLS_CERT" \
        -subj "/CN=$PORTAL_HOST" \
        -addext "subjectAltName=DNS:${PORTAL_HOST},IP:${AP_IP}"
    ok "Generated self-signed certificate for $PORTAL_HOST"
    warn "Phones will not trust this cert. Use --tls-cert/--tls-key with a Let's Encrypt cert to serve the portal over trusted HTTPS."
fi
sudo chmod 644 "$TLS_CERT"
sudo chmod 640 "$TLS_KEY"

sudo tee "$CONFIG_FILE" > /dev/null <<CONFEOF
MESHLINK_AP_INTERFACE=$WLAN_IFACE
MESHLINK_WAN_INTERFACE=$WAN_IFACE
MESHLINK_GUEST_BRIDGE=$GUEST_BRIDGE
MESHLINK_HALOW_INTERFACE=$HALOW_IFACE
MESHLINK_WIFI_SECURITY=$SECURITY_MODE
MESHLINK_SSID=$SSID
MESHLINK_AP_IP=$AP_IP
MESHLINK_PORTAL_HOST=$PORTAL_HOST
MESHLINK_TLS_CERT=$TLS_CERT
MESHLINK_TLS_KEY=$TLS_KEY
MESHLINK_TLS_PORT=$TLS_PORT
MESHLINK_TLS_TRUSTED=$TLS_TRUSTED
CONFEOF
sudo chmod 644 "$CONFIG_FILE"

# ─── 2. Stop services while configuring ───────────────────────────────────────

sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

# When changing adapters, remove only the address previously owned by meshlink.
if [ -n "$PREVIOUS_WLAN_IFACE" ] && [ "$PREVIOUS_WLAN_IFACE" != "$WLAN_IFACE" ] && [ -d "/sys/class/net/$PREVIOUS_WLAN_IFACE" ]; then
    sudo ip addr del "$AP_IP/24" dev "$PREVIOUS_WLAN_IFACE" 2>/dev/null || true
    sudo /usr/sbin/tc qdisc del dev "$PREVIOUS_WLAN_IFACE" root 2>/dev/null || true
fi

# ─── 3. Tell NetworkManager to ignore the AP interface ──────────────────────

if systemctl is-active --quiet NetworkManager; then
    info "Configuring NetworkManager to ignore $WLAN_IFACE..."
    NM_UNMANAGED="interface-name:$WLAN_IFACE;interface-name:$GUEST_BRIDGE;interface-name:$HALOW_IFACE"
    if [ "$WLAN_IFACE" != "wlan0" ]; then
        # Keep the unused onboard radio from auto-connecting or scanning beside
        # the external AP. It remains available for a later explicit switch.
        NM_UNMANAGED="$NM_UNMANAGED;interface-name:wlan0"
    fi
    sudo tee /etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf > /dev/null <<NMEOF
[keyfile]
unmanaged-devices=$NM_UNMANAGED
NMEOF
    sudo systemctl restart NetworkManager
    sleep 2
    ok "NetworkManager ignoring $WLAN_IFACE"
fi

# ─── 4. Unblock WiFi & bring up the AP interface ────────────────────────────
# Must happen AFTER NetworkManager restart (NM can re-block the radio)

info "Unblocking WiFi..."
sudo /usr/sbin/rfkill unblock wlan
sleep 2
ok "WiFi unblocked"

# ─── 5. Guest bridge ─────────────────────────────────────────────────────────
# The AP address lives on br-guest. hostapd enslaves the Alfa radio, and the
# HaLow USB Ethernet adapter (eth1) joins the same bridge when it is present.
# eth1 can show up after this step; meshlink-eth1.service attaches it later.

info "Setting $AP_IP on $GUEST_BRIDGE..."
sudo ip link add name "$GUEST_BRIDGE" type bridge 2>/dev/null || true
sudo ip link set "$GUEST_BRIDGE" up
sudo ip link set "$WLAN_IFACE" up
sudo ip addr flush dev "$WLAN_IFACE" || true
if [ -d "/sys/class/net/$HALOW_IFACE" ]; then
    sudo ip link set "$HALOW_IFACE" up
    sudo ip addr flush dev "$HALOW_IFACE" || true
    sudo ip link set "$HALOW_IFACE" master "$GUEST_BRIDGE"
fi
sudo ip addr replace "$AP_IP/24" dev "$GUEST_BRIDGE"
ok "Guest bridge ready"

# ─── 6. hostapd (access point) ───────────────────────────────────────────────

info "Configuring hostapd..."
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<HAPEOF
interface=$WLAN_IFACE
bridge=$GUEST_BRIDGE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
auth_algs=1
$HOSTAPD_SECURITY_CONFIG
ap_isolate=1
wmm_enabled=1
country_code=$COUNTRY_CODE
ieee80211n=1
HAPEOF

[ -f /etc/default/hostapd ] && sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
ok "hostapd configured"

# ─── 7. dnsmasq (DHCP + DNS) ─────────────────────────────────────────────────
# CRITICAL: bind-interfaces + listen-address keeps dnsmasq off localhost
# so it never breaks the Pi's own DNS / SSH access.

info "Configuring dnsmasq..."

[ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.orig ] && sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig

# Disable dnsmasq's resolvconf integration (prevents it from overwriting /etc/resolv.conf)
sudo tee /etc/default/dnsmasq > /dev/null <<'DEFEOF'
DNSMASQ_EXCEPT="lo"
IGNORE_RESOLVCONF=yes
DEFEOF

CAPTIVE_PORTAL_DHCP=""
if [ "$TLS_TRUSTED" = "1" ]; then
    # RFC 8910 — only advertise HTTPS when phones will trust the cert.
    CAPTIVE_PORTAL_DHCP="dhcp-option=114,https://$PORTAL_HOST/api/captive-portal"
fi

sudo tee /etc/dnsmasq.conf > /dev/null <<DNSEOF
# meshlink - DHCP + DNS for WiFi clients only
interface=$GUEST_BRIDGE
listen-address=$AP_IP
bind-interfaces
no-resolv
server=8.8.8.8
server=8.8.4.4
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$AP_NETMASK,$DHCP_LEASE
domain-needed
bogus-priv
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
$CAPTIVE_PORTAL_DHCP
# Split-horizon for the portal hostname only. Do not hijack
# captive.apple.com / connectivitycheck.gstatic.com — that breaks detection.
address=/$PORTAL_HOST/$AP_IP
DNSEOF

ok "dnsmasq configured"

# ─── 8. IP forwarding ────────────────────────────────────────────────────────

info "Enabling IP forwarding..."
sudo tee /etc/sysctl.d/99-meshlink.conf > /dev/null <<SYSEOF
net.ipv4.ip_forward=1
net.ipv6.conf.$GUEST_BRIDGE.disable_ipv6=1
SYSEOF
sudo /usr/sbin/sysctl -w net.ipv4.ip_forward=1 > /dev/null
sudo /usr/sbin/sysctl -w "net.ipv6.conf.$GUEST_BRIDGE.disable_ipv6=1" > /dev/null
ok "IP forwarding enabled"

# ─── 9. ipset + iptables (access control + captive portal) ─────────────────
# Clients are blocked by default (FORWARD DROP). When the broker grants access
# it adds the client IP to meshlink_auth ipset, which allows FORWARD.
# Port 80 REDIRECT and DNS still work for blocked clients (INPUT chain, not
# FORWARD) so they can reach the captive portal to purchase a package.

info "Configuring ipset + iptables..."

# Create ipset with timeout support (timeout 0 = per-entry timeouts enabled, kernel auto-expires)
sudo ipset create meshlink_auth hash:ip timeout 0 -exist

sudo iptables -F FORWARD 2>/dev/null || true
sudo iptables -t nat -F 2>/dev/null || true

# INPUT: WiFi clients may reach only the services needed to join and use the
# captive portal. Management services such as SSH remain reachable from eth0
# and other trusted interfaces, but never from the public AP.
for CLEANUP_IFACE in "$GUEST_BRIDGE" "$WLAN_IFACE" "$PREVIOUS_WLAN_IFACE" wlan0 wlan1; do
    [ -n "$CLEANUP_IFACE" ] || continue
    while sudo iptables -D INPUT -i "$CLEANUP_IFACE" -j meshlink_input 2>/dev/null; do :; done
done
sudo iptables -F meshlink_input 2>/dev/null || true
sudo iptables -X meshlink_input 2>/dev/null || true
sudo iptables -N meshlink_input
sudo iptables -I INPUT 1 -i "$GUEST_BRIDGE" -j meshlink_input
sudo iptables -A meshlink_input -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A meshlink_input -p udp --dport 67 -j ACCEPT
sudo iptables -A meshlink_input -p udp --dport 53 -j ACCEPT
sudo iptables -A meshlink_input -p tcp --dport 53 -j ACCEPT
sudo iptables -A meshlink_input -p tcp --dport "$BROKER_PORT" -j ACCEPT
sudo iptables -A meshlink_input -p tcp --dport 443 -j ACCEPT
sudo iptables -A meshlink_input -p tcp --dport "$TLS_PORT" -j ACCEPT
sudo iptables -A meshlink_input -j DROP

# FORWARD: block by default, allow only authenticated clients
sudo iptables -P FORWARD DROP
sudo iptables -A FORWARD -i "$GUEST_BRIDGE" -o "$WAN_IFACE" -m set --match-set meshlink_auth src -j ACCEPT
sudo iptables -A FORWARD -i "$WAN_IFACE" -o "$GUEST_BRIDGE" -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── Captive portal detection ─────────────────────────────────────────────────
# REJECT HTTPS (port 443) instead of silent DROP — iOS/Android captive portal
# detection sends HTTPS probes first. Silent DROP causes a timeout; REJECT with
# tcp-reset gives an immediate failure so the device falls back to HTTP (port 80)
# which gets REDIRECT'd to the broker captive portal.
sudo iptables -A FORWARD -i "$GUEST_BRIDGE" -o "$WAN_IFACE" -p tcp --dport 443 -j REJECT --reject-with tcp-reset

# NAT
sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE

# Captive portal: redirect unauthenticated HTTP (port 80) to the broker.
# Authorized clients must bypass this rule so captive-network probes succeed.
# REDIRECT works in PREROUTING → INPUT, so it reaches the broker even when
# FORWARD is DROP. Devices see 200 HTML instead of 204, triggering
# "Sign in to WiFi".
# Portal hostname / gateway IP: always land on the broker, even after auth.
# These match only traffic to the AP itself — they do not hijack internet sites.
sudo iptables -t nat -A PREROUTING -i "$GUEST_BRIDGE" -p tcp -d "$AP_IP" --dport 80 \
    -j REDIRECT --to-port "$BROKER_PORT"
sudo iptables -t nat -A PREROUTING -i "$GUEST_BRIDGE" -p tcp -d "$AP_IP" --dport 443 \
    -j REDIRECT --to-port "$TLS_PORT"

sudo iptables -t nat -A PREROUTING -i "$GUEST_BRIDGE" -p tcp --dport 80 \
    -m set ! --match-set meshlink_auth src \
    -j REDIRECT --to-port "$BROKER_PORT"

# Save rules
sudo mkdir -p /etc/iptables
sudo sh -c "iptables-save > /etc/iptables/rules.v4"

ok "iptables configured (FORWARD DROP + ipset auth + captive portal)"

# ─── 10. Boot persistence ────────────────────────────────────────────────────

info "Creating boot service..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sudo install -m 755 "$SCRIPT_DIR/scripts/meshlink-guest-up.sh" /usr/local/sbin/meshlink-guest-up.sh

sudo tee /etc/systemd/system/meshlink-network.service > /dev/null <<SVCEOF
[Unit]
Description=MeshLink Network Setup
Before=hostapd.service dnsmasq.service
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/meshlink-guest-up.sh

[Install]
WantedBy=multi-user.target
SVCEOF

# Attach the HaLow USB Ethernet adapter whenever it appears. Enabling this
# warns until the adapter is plugged in; the unit still stays enabled.
sudo tee /etc/systemd/system/meshlink-eth1.service > /dev/null <<ETHEOF
[Unit]
Description=Attach HaLow USB Ethernet to the guest bridge
After=sys-subsystem-net-devices-${HALOW_IFACE}.device meshlink-network.service
BindsTo=sys-subsystem-net-devices-${HALOW_IFACE}.device

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/ip link set ${HALOW_IFACE} up; /usr/sbin/ip addr flush dev ${HALOW_IFACE}; /usr/sbin/ip link set ${HALOW_IFACE} master ${GUEST_BRIDGE}'

[Install]
WantedBy=sys-subsystem-net-devices-${HALOW_IFACE}.device
ETHEOF

ok "Boot service created"

# ─── 11. Enable & start ──────────────────────────────────────────────────────

info "Enabling services..."
sudo systemctl daemon-reload
sudo systemctl unmask hostapd
sudo systemctl enable meshlink-network.service hostapd dnsmasq
sudo systemctl enable meshlink-eth1.service || warn "HaLow USB Ethernet is not plugged in yet; meshlink-eth1 will attach it when it appears"
# The older unit addresses eth1 as its own 192.168.51.1 LAN. The field gateway
# bridges that adapter into br-guest instead, so leave it disabled.
sudo systemctl disable --now meshlink-halow.service 2>/dev/null || true

info "Starting services..."
sudo systemctl restart meshlink-network.service
sudo systemctl start hostapd
sudo systemctl start dnsmasq

# ─── 12. Install Node.js & deploy broker ─────────────────────────────────────

if ! command -v node &>/dev/null; then
    info "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt install -y nodejs
fi
ok "Node.js $(node --version)"

BROKER_DIR="$(cd "$(dirname "$0")/../broker" 2>/dev/null && pwd)" || true

if [ -d "$BROKER_DIR" ]; then
    info "Building meshlink broker..."
    cd "$BROKER_DIR"

    # Remove macOS-specific esbuild if present
    sed -i '/@esbuild\/darwin-arm64/d' package.json 2>/dev/null || true

    npm install
    npm run build

    # Sudoers for broker network management
    CURRENT_USER=$(whoami)
    sudo chown root:"$CURRENT_USER" "$TLS_KEY" "$TLS_CERT"
    sudo chmod 640 "$TLS_KEY"
    sudo chmod 644 "$TLS_CERT"
    sudo tee /etc/sudoers.d/meshlink-network > /dev/null <<SUDEOF
$CURRENT_USER ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/ipset, /usr/sbin/iptables-save, /usr/sbin/iptables-restore, /usr/sbin/tc
SUDEOF
    sudo chmod 440 /etc/sudoers.d/meshlink-network

    # Create broker service
    sudo tee /etc/systemd/system/meshlink-broker.service > /dev/null <<BRKEOF
[Unit]
Description=meshlink Broker
After=network.target meshlink-network.service hostapd.service dnsmasq.service

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$BROKER_DIR
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=5
EnvironmentFile=-$BROKER_DIR/.env
EnvironmentFile=-$CONFIG_FILE
Environment=NODE_ENV=production
Environment=PORT=$BROKER_PORT

[Install]
WantedBy=multi-user.target
BRKEOF

    sudo systemctl daemon-reload
    sudo systemctl enable meshlink-broker
    sudo systemctl restart meshlink-broker
    sleep 2
    ok "Broker running on port $BROKER_PORT"
else
    warn "Broker directory not found at $BROKER_DIR - skipping broker setup"
    echo "  Deploy the broker manually, then create the meshlink-broker service."
fi

# ─── 13. Verify ──────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────"
ERRORS=0

for svc in meshlink-network hostapd dnsmasq; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc running"
    else
        warn "$svc not running"
        ERRORS=$((ERRORS + 1))
    fi
done

systemctl is-active --quiet meshlink-broker && ok "meshlink-broker running" || warn "meshlink-broker not running"

ip addr show "$GUEST_BRIDGE" 2>/dev/null | grep -q "$AP_IP" && ok "$GUEST_BRIDGE has $AP_IP" || warn "$GUEST_BRIDGE missing IP"
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && ok "IP forwarding on" || warn "IP forwarding off"
if curl -sk --max-time 5 "https://127.0.0.1:${TLS_PORT}/api/health" > /dev/null 2>&1; then
    ok "Portal HTTPS listening on :$TLS_PORT"
else
    warn "Portal HTTPS not reachable on 127.0.0.1:$TLS_PORT"
fi

# Verify Pi's own DNS still works (the bug that broke SSH last time)
if host google.com > /dev/null 2>&1 || dig +short google.com > /dev/null 2>&1 || getent hosts google.com > /dev/null 2>&1; then
    ok "Pi DNS resolution works"
else
    warn "Pi DNS may be broken - check /etc/resolv.conf"
fi

echo "────────────────────────────────────────"

if [ "$ERRORS" -eq 0 ]; then
    echo ""
    echo "============================================"
    echo "  meshlink WiFi Gateway Ready!"
    echo "============================================"
    echo "  SSID:       $SSID"
    echo "  Security:   $SECURITY_DESCRIPTION"
    echo "  AP device:  $WLAN_IFACE"
    echo "  Guest LAN:  $GUEST_BRIDGE ($HALOW_IFACE joins when present)"
    echo "  WAN device: $WAN_IFACE"
    echo "  Portal:     http://$AP_IP:$BROKER_PORT"
    echo "  HTTPS:      https://$PORTAL_HOST/"
    if [ "$TLS_TRUSTED" = "1" ]; then
        echo "  TLS:        trusted certificate (phones will upgrade to HTTPS)"
    else
        echo "  TLS:        self-signed (detection stays HTTP; add --tls-cert for trusted HTTPS)"
    fi
    echo "============================================"
    echo ""
    echo "  Clients join without a WiFi password."
    echo "  Internet remains blocked until portal authorization."
    echo "  Detection stays on HTTP. The portal hostname is HTTPS."
    echo ""
fi
