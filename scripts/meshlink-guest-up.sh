#!/bin/sh
# Bring up the guest bridge before hostapd, dnsmasq, and the broker.
# The Alfa AP and the HaLow USB Ethernet adapter share the guest bridge.
# In lab mode a single wired guest interface replaces the wireless AP.
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
GUEST_IFACE=$(read_key MESHLINK_GUEST_INTERFACE "")
BRIDGE=$(read_key MESHLINK_GUEST_BRIDGE br-guest)
AP_IP=$(read_key MESHLINK_AP_IP 192.168.50.1)
LAB_QEMU=$(read_key MESHLINK_LAB_QEMU 0)

[ "$LAB_QEMU" = "1" ] || /usr/sbin/rfkill unblock wlan 2>/dev/null || true
/usr/sbin/ip link add name "$BRIDGE" type bridge 2>/dev/null || true
/usr/sbin/ip link set "$BRIDGE" up

attach_interface() {
  iface="$1"
  i=0
  while [ "$i" -lt 15 ] && ! /usr/sbin/ip link show "$iface" >/dev/null 2>&1; do
    i=$((i + 1))
    sleep 1
  done
  if /usr/sbin/ip link show "$iface" >/dev/null 2>&1; then
    /usr/sbin/ip link set "$iface" up
    /usr/sbin/ip addr flush dev "$iface" 2>/dev/null || true
    /usr/sbin/ip link set "$iface" master "$BRIDGE"
  fi
}

if [ "$LAB_QEMU" = "1" ]; then
  [ -n "$GUEST_IFACE" ] && attach_interface "$GUEST_IFACE"
else
  [ -n "$HALOW_IFACE" ] && attach_interface "$HALOW_IFACE"
  /usr/sbin/ip link set "$AP_IFACE" up
  /usr/sbin/ip addr flush dev "$AP_IFACE" 2>/dev/null || true
fi

/usr/sbin/ip addr replace "$AP_IP/24" dev "$BRIDGE"
/usr/sbin/sysctl -w "net.ipv6.conf.${BRIDGE}.disable_ipv6=1" >/dev/null
/usr/sbin/ipset create meshlink_auth hash:ip timeout 0 -exist
/usr/sbin/iptables-restore /etc/iptables/rules.v4
