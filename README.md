# meshlink WiFi Gateway

WiFi access point + captive portal setup for the meshlink internet-sharing platform. Turns a Raspberry Pi into a monetized WiFi hotspot — like Airbnb for your spare bandwidth.

Most broadband connections run at a fraction of their capacity most of the time. meshlink lets you share that excess with nearby devices and earn from it, the same way Uber monetizes idle driving time or Airbnb monetizes empty rooms. Plug a Pi into your router, run the installer, and guests nearby can pay for access to your connection through a captive portal you control.

## Tested On

| Hardware | OS | Network Manager | Status |
|----------|-----|-----------------|--------|
| Raspberry Pi 5 (4GB) | Debian 13 Trixie (Raspberry Pi OS) | NetworkManager | Working |

## How It Works

```
Client joins the open "meshlink" WiFi
         |
         v
   Gets IP via DHCP; internet remains blocked
   (FORWARD policy: DROP)
         |
         v
   Device does HTTP captive portal check
   (e.g. GET http://connectivitycheck.gstatic.com/generate_204)
         |
         v
   iptables REDIRECT intercepts port 80 traffic
   Sends it to the meshlink broker on port 3000
         |
         v
   Broker returns 200 HTML instead of 204
   Device detects captive portal
   Shows "Sign in to WiFi" dialog
         |
         v
   Client sees meshlink landing page
   (HTTP for detection; HTTPS on portal.meshlink when a trusted cert is installed)
   Selects tier (Free / Paid)
         |
         v
   Broker adds the client IP to meshlink_auth
   Internet forwarding is granted until session expiry
```

## Quick Start

The `install.sh` script handles everything end-to-end: AP setup, DHCP/DNS, NAT, captive portal redirect, Node.js install, broker build, and systemd services.

The gateway and the broker are separate repositories. Clone both, with the broker next to this directory:

```bash
git clone https://github.com/meshlinkfoundation/broker.git
git clone https://github.com/meshlinkfoundation/meshlink-wifi-gateway.git
cd meshlink-wifi-gateway
bash install.sh
```

`bootstrap.sh` clones both into `~/meshlink` and then runs `install.sh`. It does not install Node itself. Do not `apt install nodejs npm` first: Debian's `npm` package is a metapackage, and the installer replaces it with Node.js 20 from NodeSource. If the broker lives somewhere else, pass `--broker-dir /path/to/broker`.

When a prebuilt broker for this commit is published, the installer downloads that `dist` and installs runtime packages only. Otherwise it builds on the Pi. Either way, that happens before it changes NetworkManager, hostapd, dnsmasq, or the firewall. A failed install exits nonzero. A fresh node signs in to the dashboard with the password `admin`. Change it from the dashboard after you log in. Pass `--admin-password` to choose a different one during install. A password that was already changed is left alone. The password in use is also saved in `/etc/meshlink/admin-password`.

When installation finishes, the script prints a `MESHLINK_INSTALL_SUMMARY` block: the Wi-Fi name, channel, and security; the Pi's LAN address and dashboard URLs; the admin password; and the file that holds the tiers visitors see. The same block is saved at `/etc/meshlink/install-summary.txt`.

The installer assumes the node is in the United States. It sets the WiFi country (regulatory domain) to `US` for hostapd and for the Pi itself, which also clears the soft block Raspberry Pi OS keeps on WiFi until a country is set.

### Operator Dashboard

The operator dashboard runs on the Pi. The broker serves it at `/admin` on port 3000; there is nothing to install on another machine. Open it from a device on the same local network as the Pi's WAN side:

```
http://<pi-lan-ip>:3000/admin
```

Guests on the meshlink WiFi cannot reach it — the broker returns 404 for `/admin` to clients on the guest network. To reach the dashboard from anywhere else, set up Tailscale as described below.

### Stripe Payments (Optional)

To accept paid tiers via Stripe, create a `.env` file in the broker directory before running the installer (or any time after):

```bash
echo "STRIPE_SECRET_KEY=sk_test_yourKeyHere" > /home/meshlink/meshlink/broker/.env
sudo systemctl restart meshlink-broker
```

The broker service loads this file via `EnvironmentFile`. See `broker/STRIPE_SETUP.md` for full details.

### Remote Management with Tailscale (Optional)

By default, the operator dashboard runs on the Pi and is only reachable at `http://<pi-lan-ip>:3000/admin` from your local network. If you want to manage your node remotely — from a different network, on the go, etc. — you'll need a way to reach it. [Tailscale](https://tailscale.com) is a simple option that creates a private mesh VPN between your devices.

```bash
# On the Pi: install and authenticate
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up
# Follow the printed URL to log in with your Tailscale account
```

Install Tailscale on your laptop/phone too, and sign in with the same account. Then find the Pi's Tailscale IP:

```bash
tailscale ip -4
# e.g. 100.125.251.114
```

The dashboard is now reachable from anywhere on your tailnet:

```
http://<pi-tailscale-ip>:3000/admin
```

Without Tailscale (or a similar solution like a VPN or reverse tunnel), you must be on the same local network as the Pi to access the dashboard.

## Default Configuration

| Setting | Value |
|---------|-------|
| SSID | `meshlink` by default; saved per gateway with `--ssid` |
| Password | None |
| AP IP / Gateway | `192.168.50.1` |
| DHCP range | `192.168.50.10` - `192.168.50.100` |
| Channel | 6 (2.4 GHz) |
| WiFi country | `US` |
| AP interface | `wlan0` by default; the field Pi uses the Alfa on `wlan1` |
| Guest bridge | `br-guest` holds `192.168.50.1`; the Alfa and HaLow USB Ethernet (`eth1`) are members |
| WAN interface | `eth0` |
| Security | Open by default; OWE/Enhanced Open is operator-selectable |
| Broker port | 3000 |
| Portal hostname | `portal.meshlink` → `192.168.50.1` |
| Portal HTTPS | Self-signed by default; trusted cert optional |

The installer defaults to the Pi's built-in `wlan0`. To use an external USB
adapter such as an Alfa, list the detected interface names and select the WiFi
one when installing:

```bash
bash install.sh --list-interfaces
bash install.sh --ap-interface wlan1 --ssid "Free Wi-Fi - PSL Market"
```

The selection is saved in `/etc/meshlink/gateway.conf`, used by hostapd,
dnsmasq, the firewall, the boot service, and the broker's bandwidth limiter,
and reused on later installer runs. hostapd bridges the AP into `br-guest`.
`/usr/local/sbin/meshlink-guest-up.sh` waits up to 15 seconds for the HaLow
USB Ethernet adapter and still brings the Alfa portal up if that adapter is
absent. `meshlink-eth1.service` attaches it whenever it appears later. Operators can switch adapters by rerunning
the installer with a different `--ap-interface`. When an external adapter is
selected, NetworkManager leaves both it and the unused onboard radio alone to
prevent an accidental WiFi connection from interfering with the AP. Keep the
WAN on Ethernet when possible; if it is not `eth0`, set it at the same time:

```bash
bash install.sh --ap-interface wlan1 --wan-interface enp1s0
```

The adapter and its Linux driver must support AP mode. The installer checks
this before changing the gateway. If it fails, inspect the USB chipset and
driver with `lsusb`, `iw dev`, and `iw list`—the Alfa product name alone does
not identify the chipset or guarantee AP-mode driver support.

### Passwordless encryption with OWE

OWE (WiFi Enhanced Open) encrypts each client's WiFi link without requiring a
shared password. It does not authenticate the hotspot, and older clients that
do not support Enhanced Open cannot join a pure OWE network. Enable it with:

```bash
bash install.sh --ap-interface wlan1 --security owe
```

The selected mode is persisted as `MESHLINK_WIFI_SECURITY` in
`/etc/meshlink/gateway.conf`. Use `--security open` to roll back. Changing the
mode disconnects current WiFi clients; manage the gateway over Ethernet or
Tailscale while applying it. Captive-portal access control continues to work
above the encrypted WiFi link.

### HTTPS for the captive portal

Open WiFi has no link encryption. Serving the portal over HTTPS keeps portal
API calls, session setup, and payment start from being readable by a radio
sniffer. It does **not** replace WPA3/OWE — anyone nearby can still see who
associates and can still run an evil twin.

Captive-portal *detection* must stay on HTTP. iOS and Android probe HTTP
endpoints such as `http://captive.apple.com/hotspot-detect.html`. If those
probes are forced onto HTTPS, or if detection domains are DNS-hijacked, the
phone often shows "Unable to join" instead of "Sign in to WiFi".

meshlink therefore splits the two:

1. **Detection** — unauthenticated port 80 is still `REDIRECT`ed to the broker.
   Internet port 443 is still `REJECT`ed so phones fall back to HTTP.
2. **Portal** — `portal.meshlink` (or your hostname) resolves to `192.168.50.1`
   and is served over TLS. Only traffic *to the gateway* on 443 is redirected.
   Internet HTTPS is never intercepted.

A self-signed cert is generated at install time so `https://portal.meshlink/`
listens. Phones will not trust it, so the Sign-in sheet stays on HTTP. To
actually protect the sheet and skip certificate warnings, install a publicly
trusted certificate for a hostname you control (Let's Encrypt DNS-01 works
from the Pi's ethernet/WAN even without a public IP):

```bash
# On the Pi, after copying fullchain.pem and privkey.pem
bash install.sh --ap-interface wlan1 \
  --portal-host wifi.example.com \
  --tls-cert /path/to/fullchain.pem \
  --tls-key /path/to/privkey.pem
```

That sets `MESHLINK_TLS_TRUSTED=1`, advertises the HTTPS URL via DHCP option
114 (RFC 8910), and the portal upgrades browsers to `https://wifi.example.com/`.
Re-run with `--security open` if you also need to keep the Alfa adapter in the
working open mode.

## Network Architecture

```
Internet
   |
   | (ethernet)
   |
[WAN] Raspberry Pi 5 [selected WiFi AP] ──── WiFi clients
192.168.0.x (DHCP)     192.168.50.1 (AP)
   |                      |
   | NAT/masquerade        | FORWARD policy: DROP
   |<─────────────────────-| (authorized IPs only)
   |                      |
                     DHCP: 192.168.50.10-100
                     DNS:  192.168.50.1 (Pi → 8.8.8.8)
                     Unauthorized port 80: REDIRECT → broker:3000
                     portal host :443: REDIRECT → broker TLS :3443
```

## Who Does What

meshlink is built from a stack of components that each have one job. Understanding this separation makes the system much easier to operate, debug, and trust.

```
┌─────────────────────────────────────────────────────────────────┐
│  hostapd      Manages the open WiFi AP, SSID broadcast, channel,│
│               and client isolation. Any device can associate.  │
│               Knows nothing about meshlink or payments.         │
│      │                                                          │
│      ↓        Client associated (Layer 2)                       │
│                                                                 │
│  dnsmasq      Hands out an IP via DHCP (192.168.50.x range)     │
│               and serves DNS. Client now has Layer 3.           │
│      │                                                          │
│      ↓        Client has an IP                                  │
│                                                                 │
│  Linux        Default FORWARD policy = DROP.                    │
│  kernel       Unauthorized clients can't reach the internet.    │
│  (iptables    HTTP requests on port 80 are REDIRECTed to        │
│   + ipset)    the broker on port 3000.                          │
│      │                                                          │
│      ↓        Client lands on captive portal                    │
│                                                                 │
│  Broker       Serves captive portal HTML. Handles payment       │
│  (Node.js)    (Stripe or MESH). On success, shells out:         │
│                  sudo ipset add <tier> <client_ip>              │
│      │                                                          │
│      ↓        Client added to the auth ipset                    │
│                                                                 │
│  Linux        Now matches an ACCEPT rule in FORWARD chain       │
│  kernel       (and gets the right bandwidth tier via tc).       │
│               Internet flows. Tier expires → broker calls       │
│               `ipset del` → client back to captive portal.      │
└─────────────────────────────────────────────────────────────────┘
```

### What the broker does *not* do

It's important to understand what the broker is **not** responsible for:

| Concern | Handled by | Not the broker |
|---|---|---|
| WiFi association, SSID, and client isolation | `hostapd` | ✗ |
| Assigning IP addresses | `dnsmasq` | ✗ |
| Routing packets | Linux kernel | ✗ |
| Blocking unauthorized traffic | iptables + ipset | ✗ |
| Bandwidth throttling per tier | tc queues + iptables marks | ✗ |
| DNS resolution | `dnsmasq` (forwards to 8.8.8.8) | ✗ |

The broker's entire role on the network side is:

```
sudo ipset add <tier> <client_ip>      # after payment
sudo ipset del <tier> <client_ip>      # when tier expires
```

That's it. Everything else is the kernel doing its job autonomously based on rules configured once at boot.

### Why this design

- **Performance** — every packet flows through the kernel at line rate. The broker would be a bottleneck if it sat in the data path. Instead it only touches the access list, never the packets themselves.
- **Reliability** — if the broker crashes, existing paying clients keep their access. Only new payments stop until it restarts. Customers in the middle of streaming don't get cut off.
- **Auditability** — `sudo ipset list` shows exactly who has access right now. `tc -s class show dev <AP-interface>` shows live bandwidth per tier. No black box, no log digging.
- **Simplicity** — broker code stays small. It doesn't reimplement networking; it just calls one CLI tool. Easier to maintain, audit, and reason about.

## Captive Portal Flow

1. Client connects to meshlink WiFi, gets IP via DHCP
2. DNS resolves normally via the Pi's dnsmasq (forwards to 8.8.8.8)
3. Device does HTTP captive portal check (e.g. `GET /generate_204` to Google)
4. iptables `REDIRECT` intercepts port 80 traffic and sends it to broker on port 3000
5. Broker returns 200 HTML (not 204), triggering captive portal detection
6. Device shows "Sign in to WiFi" dialog with the meshlink landing page
7. Client selects a tier on the landing page

### Important: Why REDIRECT, not DNAT or DNS hijacking

- **REDIRECT** (not DNAT) is required because DNAT to a local IP can have routing issues
- **Do NOT hijack DNS** for captive portal detection domains — Android/MIUI switches to HTTPS-only when it sees local IPs in DNS responses, which breaks detection
- **Do NOT redirect internet port 443** — TLS handshake failures are not interpreted as "captive portal" by Android. Only `192.168.50.1:443` (the portal hostname) is redirected to the broker TLS port
- Local `address=/portal.meshlink/192.168.50.1` is safe because that name is not a detection domain
- The working approach: let detection-domain DNS resolve normally, REDIRECT port 80 for probes, serve the portal hostname on HTTPS

## Files Modified

| File | Purpose |
|------|---------|
| `/etc/hostapd/hostapd.conf` | Access point configuration |
| `/etc/dnsmasq.conf` | DHCP and DNS for WiFi clients only |
| `/etc/default/dnsmasq` | Disables resolvconf integration (prevents DNS breakage) |
| `/etc/sysctl.d/99-meshlink.conf` | IP forwarding |
| `/etc/iptables/rules.v4` | NAT + captive portal REDIRECT rules |
| `/etc/meshlink/gateway.conf` | Operator-selected AP, WAN, portal host, and TLS settings |
| `/etc/meshlink/tls/portal.crt` | Portal TLS certificate |
| `/etc/meshlink/tls/portal.key` | Portal TLS private key |
| `/etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf` | NM ignores the selected AP interface |
| `/usr/local/sbin/meshlink-guest-up.sh` | Creates `br-guest`, waits for `eth1`, restores iptables |
| `/etc/systemd/system/meshlink-network.service` | Boot: runs the guest bridge script before hostapd and dnsmasq |
| `/etc/systemd/system/meshlink-eth1.service` | Attaches the HaLow USB Ethernet adapter to `br-guest` |
| `/etc/systemd/system/meshlink-broker.service` | Broker auto-start |
| `/etc/sudoers.d/meshlink-network` | Broker can manage iptables/ipset |

## Services

| Service | Purpose |
|---------|---------|
| `meshlink-network` | Boot: guest bridge, optional `eth1`, iptables restore |
| `meshlink-eth1` | Attach the HaLow USB Ethernet adapter when it enumerates |
| `hostapd` | WiFi access point, bridged to `br-guest` |
| `dnsmasq` | DHCP + DNS for clients |
| `meshlink-broker` | Node.js captive portal web app + API |

## Troubleshooting

### Captive portal not showing on device

**Forget and reconnect** to meshlink WiFi — the device only checks for captive portals on fresh connections.

### Phone says "Unable to join" after enabling HTTPS

Detection must stay on HTTP. Confirm internet :443 is still `REJECT`ed, not
redirected, and that dnsmasq does **not** override `captive.apple.com` or
`connectivitycheck.gstatic.com`:

```bash
sudo iptables -t nat -L PREROUTING -n -v
grep address /etc/dnsmasq.conf
curl -sk https://127.0.0.1:3443/api/health
```

A self-signed cert will not make the Sign-in sheet use HTTPS. That is expected.
Install a Let's Encrypt cert with `--tls-cert` / `--tls-key` to upgrade it.

```bash
# Verify REDIRECT rule exists
sudo iptables -t nat -L PREROUTING -n -v

# Check broker is running and reachable
sudo systemctl status meshlink-broker
curl -s http://192.168.50.1:3000/api/health
```

### WiFi AP not starting

```bash
sudo systemctl status hostapd
sudo journalctl -u hostapd -n 30
sudo rfkill list wlan
ip addr show "$(sed -n 's/^MESHLINK_AP_INTERFACE=//p' /etc/meshlink/gateway.conf)"
```

### Pi lost SSH / DNS broken

This can happen if dnsmasq's resolvconf helper overwrites `/etc/resolv.conf`. The installer prevents this with `IGNORE_RESOLVCONF=yes` in `/etc/default/dnsmasq` and `bind-interfaces` + `listen-address` in `/etc/dnsmasq.conf`. If it does happen:

1. Power cycle the Pi
2. Check `/etc/resolv.conf` points to your router (e.g. `nameserver 192.168.0.1`), not to `127.0.0.1`
3. Re-run the installer

### After reboot, captive portal doesn't work

```bash
sudo systemctl status meshlink-network
sudo journalctl -u meshlink-network -n 20
sudo systemctl restart meshlink-network hostapd dnsmasq meshlink-broker
```

## Re-running the Installer

The script is idempotent. It flushes iptables rules before re-adding them and backs up config files only once.

## Uninstall

```bash
sudo systemctl stop meshlink-broker hostapd dnsmasq meshlink-network meshlink-eth1
sudo systemctl disable meshlink-broker hostapd dnsmasq meshlink-network meshlink-eth1
sudo rm /etc/systemd/system/meshlink-network.service
sudo rm /etc/systemd/system/meshlink-eth1.service
sudo rm /usr/local/sbin/meshlink-guest-up.sh
sudo rm /etc/systemd/system/meshlink-broker.service
sudo rm /etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf
sudo rm /etc/sysctl.d/99-meshlink.conf
sudo rm /etc/sudoers.d/meshlink-network
sudo rm /etc/default/dnsmasq
sudo cp /etc/dnsmasq.conf.orig /etc/dnsmasq.conf 2>/dev/null
sudo iptables -P FORWARD ACCEPT
sudo iptables -t nat -F
sudo iptables -F FORWARD
sudo systemctl restart NetworkManager
sudo systemctl daemon-reload
```
