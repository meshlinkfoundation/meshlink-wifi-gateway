#!/bin/sh
# Bring up the guest bridge before hostapd and dnsmasq.
# The Alfa AP and the HaLow USB Ethernet adapter share 192.168.50.1.
# eth1 often enumerates after boot; the Alfa portal still comes up without it.
set -e

conf=/etc/meshlink/gateway.conf
read_key() {
  key="$1"
  fallback="$2"
  if [ -r "$conf" ]; then
    line=$(grep -E "^${key}=" "$conf" 2>/dev/null | tail -n 1) || true
    if [ -n "$line" ]; then
      printf '%s' "${line#*=}"
      return
    fi
  fi
  printf '%s' "$fallback"
}

AP_IFACE=$(read_key MESHLINK_AP_INTERFACE wlan1)
HALOW_IFACE=$(read_key MESHLINK_HALOW_INTERFACE eth1)
BRIDGE=$(read_key MESHLINK_GUEST_BRIDGE br-guest)
AP_IP=$(read_key MESHLINK_AP_IP 192.168.50.1)

/usr/sbin/rfkill unblock wlan || true
/usr/sbin/ip link add name "$BRIDGE" type bridge 2>/dev/null || true
/usr/sbin/ip link set "$BRIDGE" up

i=0
while [ "$i" -lt 15 ] && ! /usr/sbin/ip link show "$HALOW_IFACE" >/dev/null 2>&1; do
  i=$((i + 1))
  sleep 1
done
if /usr/sbin/ip link show "$HALOW_IFACE" >/dev/null 2>&1; then
  /usr/sbin/ip link set "$HALOW_IFACE" up
  /usr/sbin/ip addr flush dev "$HALOW_IFACE"
  /usr/sbin/ip link set "$HALOW_IFACE" master "$BRIDGE"
fi

/usr/sbin/ip link set "$AP_IFACE" up
/usr/sbin/ip addr flush dev "$AP_IFACE" || true
/usr/sbin/ip addr replace "$AP_IP/24" dev "$BRIDGE"
/usr/sbin/sysctl -w "net.ipv6.conf.${BRIDGE}.disable_ipv6=1" >/dev/null
/usr/sbin/ipset create meshlink_auth hash:ip timeout 0 -exist
/usr/sbin/iptables-restore /etc/iptables/rules.v4
