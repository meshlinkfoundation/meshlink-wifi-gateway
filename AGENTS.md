# Agents

Guidelines and context for AI agents working in this repo.

## Repo

WiFi AP setup scripts for Raspberry Pi. Configures hostapd, dnsmasq, iptables, NetworkManager, and systemd services to turn a Raspberry Pi into a meshlink WiFi hotspot.

## Notes

### First install assumes Ethernet backhaul

On first install, the user has the Pi wired to their router over Ethernet (`eth0`, the default WAN interface). The installer takes over the Pi's WiFi radio for the hotspot: NetworkManager stops managing it and hostapd turns it into the AP. Because the internet connection and the user's SSH session both run over Ethernet, SSH stays connected while the WiFi is reconfigured.

- Assume the user is connected over SSH through Ethernet while `install.sh` runs. Don't tell them to expect a disconnect, and don't build workarounds for one.
- Don't suggest running the install over a WiFi SSH session. Turning the radio into the AP would cut that session off partway through the install.
- The Pi's LAN address printed in the install summary is its Ethernet (WAN) address. Use it for SSH and for the operator dashboard.
- Run `bash install.sh` as the normal user. Do not start it with `sudo`, and do not `apt install nodejs npm`. The script installs Node.js 20 from NodeSource and refuses Debian's `npm` metapackage.
- `bootstrap.sh` is the entry point. It clones the two repos and runs `install.sh`. It does not install Node.
