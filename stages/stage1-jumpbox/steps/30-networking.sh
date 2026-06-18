#!/usr/bin/env bash
# ============================================================================
# networking :: per-OS VLAN sub-interfaces on the PRIVATE NIC only, each with
# gateway .1 and jumbo MTU. The public NIC is never touched (keeps SSH alive).
#   Debian -> netplan ; RedHat -> NetworkManager ; Photon -> systemd-networkd
# Mirrors roles/networking.
#
# Each OS has a pure `_net_render_*` (testable) and an apply path that writes +
# activates. RedHat is imperative (nmcli); `_net_nmcli_addargs` is its testable
# unit.
# ============================================================================

step_networking() {
  case "$OS_FAMILY" in
    debian) write_file /etc/netplan/99-nested-lab.yaml 0600 < <(_net_render_debian); netplan apply ;;
    redhat) _net_apply_redhat ;;
    photon) _net_apply_photon ;;
  esac
  sleep 3
  _net_verify
}

# ---- Debian / netplan (pure render) ----
_net_render_debian() {
  local i vlans=0
  echo "# Managed by nested-vsphere-lab (networking). Private fabric only."
  echo "# Public NIC (${PUBLIC_NIC}) is intentionally NOT managed here."
  echo "network:"
  echo "  version: 2"
  echo "  renderer: networkd"
  echo "  ethernets:"
  echo "    ${PRIVATE_NIC}:"
  echo "      dhcp4: false"
  echo "      dhcp6: false"
  echo "      accept-ra: false"
  echo "      mtu: ${MTU_PRIVATE}"
  echo "      addresses:"
  for ((i=0; i<N_VLANS; i++)); do
    [[ "${V_ISNATIVE[i]}" == 1 ]] && echo "        - ${V_GW[i]}/${V_PREFIX[i]}"
  done
  for ((i=0; i<N_VLANS; i++)); do [[ "${V_ISNATIVE[i]}" == 0 ]] && vlans=1; done
  if (( vlans )); then
    echo "  vlans:"
    for ((i=0; i<N_VLANS; i++)); do
      [[ "${V_ISNATIVE[i]}" == 0 ]] || continue
      echo "    ${V_IFACE[i]}:"
      echo "      id: ${V_ID[i]}"
      echo "      link: ${PRIVATE_NIC}"
      echo "      mtu: ${MTU_PRIVATE}"
      echo "      addresses: [${V_GW[i]}/${V_PREFIX[i]}]"
    done
  fi
}

# ---- RedHat / NetworkManager ----
# echoes the args that follow `nmcli con add` for VLAN index $1 (testable unit)
_net_nmcli_addargs() {
  local i="$1" name="nested-${V_IFACE[$1]}"
  if [[ "${V_ISNATIVE[i]}" == 1 ]]; then
    printf 'type ethernet con-name %s ifname %s ipv4.method manual ipv4.addresses %s/%s ethernet.mtu %s autoconnect yes' \
      "$name" "$PRIVATE_NIC" "${V_GW[i]}" "${V_PREFIX[i]}" "$MTU_PRIVATE"
  else
    printf 'type vlan con-name %s dev %s id %s ipv4.method manual ipv4.addresses %s/%s ethernet.mtu %s autoconnect yes' \
      "$name" "$PRIVATE_NIC" "${V_ID[i]}" "${V_GW[i]}" "${V_PREFIX[i]}" "$MTU_PRIVATE"
  fi
}

_net_apply_redhat() {
  svc_enable_now NetworkManager
  local i name args
  for ((i=0; i<N_VLANS; i++)); do
    name="nested-${V_IFACE[i]}"
    nmcli -t -f NAME con show 2>/dev/null | grep -qxF "$name" && nmcli con delete "$name" >/dev/null
    # shellcheck disable=SC2046
    nmcli con add $(_net_nmcli_addargs "$i") >/dev/null
  done
  for ((i=0; i<N_VLANS; i++)); do nmcli con up "nested-${V_IFACE[i]}" >/dev/null || warn "could not bring up nested-${V_IFACE[i]}"; done
}

# ---- Photon / systemd-networkd (pure renders) ----
_net_render_photon_main() {
  local i
  echo "# Managed by nested-vsphere-lab (networking)."
  echo "[Match]"; echo "Name=${PRIVATE_NIC}"
  echo ""; echo "[Link]"; echo "MTUBytes=${MTU_PRIVATE}"
  echo ""; echo "[Network]"
  for ((i=0; i<N_VLANS; i++)); do [[ "${V_ISNATIVE[i]}" == 1 ]] && echo "Address=${V_GW[i]}/${V_PREFIX[i]}"; done
  for ((i=0; i<N_VLANS; i++)); do [[ "${V_ISNATIVE[i]}" == 0 ]] && echo "VLAN=${V_IFACE[i]}"; done
}
_net_render_photon_netdev() {
  local i="$1"
  echo "# Managed by nested-vsphere-lab (networking)."
  echo "[NetDev]"; echo "Name=${V_IFACE[i]}"; echo "Kind=vlan"; echo "MTUBytes=${MTU_PRIVATE}"
  echo ""; echo "[VLAN]"; echo "Id=${V_ID[i]}"
}
_net_render_photon_network() {
  local i="$1"
  echo "# Managed by nested-vsphere-lab (networking)."
  echo "[Match]"; echo "Name=${V_IFACE[i]}"
  echo ""; echo "[Link]"; echo "MTUBytes=${MTU_PRIVATE}"
  echo ""; echo "[Network]"; echo "Address=${V_GW[i]}/${V_PREFIX[i]}"
}

_net_apply_photon() {
  local i
  write_file "/etc/systemd/network/10-nested-${PRIVATE_NIC}.network" 0644 < <(_net_render_photon_main)
  for ((i=0; i<N_VLANS; i++)); do
    [[ "${V_ISNATIVE[i]}" == 0 ]] || continue
    write_file "/etc/systemd/network/20-nested-${V_IFACE[i]}.netdev"  0644 < <(_net_render_photon_netdev  "$i")
    write_file "/etc/systemd/network/21-nested-${V_IFACE[i]}.network" 0644 < <(_net_render_photon_network "$i")
  done
  svc_enable_now systemd-networkd
  svc_restart systemd-networkd
}

_net_verify() {
  local i fail=0
  for ((i=0; i<N_VLANS; i++)); do
    if ip -4 addr show dev "${V_IFACE[i]}" 2>/dev/null | grep -qw "${V_GW[i]}"; then
      ok "iface ${V_IFACE[i]} has ${V_GW[i]}/${V_PREFIX[i]} (mtu ${MTU_PRIVATE})"
    else
      err "gateway ${V_GW[i]} missing on ${V_IFACE[i]}"; fail=1
    fi
  done
  (( fail == 0 )) || die "networking verification failed; check 'ip addr' and the rendered config."
}
