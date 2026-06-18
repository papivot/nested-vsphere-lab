#!/usr/bin/env bash
# Rollback for networking. Removes only what this role created; public NIC untouched.
rollback_networking() {
  local i
  case "$OS_FAMILY" in
    debian)
      rm -f /etc/netplan/99-nested-lab.yaml
      netplan apply || true
      ;;
    redhat)
      for ((i=0; i<N_VLANS; i++)); do
        nmcli con delete "nested-${V_IFACE[i]}" >/dev/null 2>&1 || true
      done
      ;;
    photon)
      rm -f "/etc/systemd/network/10-nested-${PRIVATE_NIC}.network"
      rm -f /etc/systemd/network/20-nested-*.netdev /etc/systemd/network/21-nested-*.network
      svc_restart systemd-networkd || true
      ;;
  esac
  ok "Removed nested VLAN interface config."
}
