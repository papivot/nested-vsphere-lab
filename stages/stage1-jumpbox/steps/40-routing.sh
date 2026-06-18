#!/usr/bin/env bash
# ============================================================================
# routing :: nftables NAT (masquerade out the public NIC) + stateful forward
# filter, persistent static routes, optional FRR/BGP. Egress only via public
# NIC. Mirrors roles/routing.
#
# Pure renders (_nft_render, _routes_render, _frr_render) are testable; the
# apply path validates + installs systemd units.
# ============================================================================

# unique private interface list (helper used by render + firewall)
_priv_iface_list() {
  local i ifaces=()
  for ((i=0; i<N_VLANS; i++)); do
    printf '%s\n' "${ifaces[@]}" 2>/dev/null | grep -qxF "${V_IFACE[i]}" || ifaces+=("${V_IFACE[i]}")
  done
  local IFS=,; echo "${ifaces[*]}"
}

_nft_render() {
  local nat; nat=$(cfg_bool '.routing.nat' 'true')
  echo "#!/usr/sbin/nft -f"
  echo "# Managed by nested-vsphere-lab (routing). Egress ONLY via the public NIC."
  echo "flush ruleset"
  echo ""
  echo "define PUBLIC = \"${PUBLIC_NIC}\""
  echo "define PRIV_IFACES = { $(_priv_iface_list) }"
  echo ""
  echo "table inet filter {"
  echo "    chain input   { type filter hook input priority 0; policy accept; }"
  echo "    chain forward {"
  echo "        type filter hook forward priority 0; policy drop;"
  echo "        ct state established,related accept"
  echo "        iifname \$PRIV_IFACES accept"
  echo "        oifname \$PRIV_IFACES ct state new drop"
  echo "    }"
  echo "    chain output  { type filter hook output priority 0; policy accept; }"
  echo "}"
  echo ""
  echo "table ip nat {"
  echo "    chain postrouting {"
  echo "        type nat hook postrouting priority srcnat; policy accept;"
  [[ "$nat" == "true" ]] && echo "        oifname \$PUBLIC masquerade"
  echo "    }"
  echo "}"
}

_routes_render() {
  local i nr; nr=$(cfg_len '.routing.static_routes')
  echo "#!/usr/bin/env bash"
  echo "# Managed by nested-vsphere-lab (routing). Persistent static routes."
  echo "set -e"
  for ((i=0; i<nr; i++)); do
    echo "ip route replace $(cfg ".routing.static_routes[$i].dest") via $(cfg ".routing.static_routes[$i].via")"
  done
  echo "exit 0"
}

_frr_render() {
  local asn rid nn i
  asn=$(cfg '.routing.bgp.local_asn'); rid=$(cfg '.routing.bgp.router_id')
  nn=$(cfg_len '.routing.bgp.neighbors')
  echo "! Managed by nested-vsphere-lab (routing)."
  echo "frr defaults traditional"
  echo "hostname ${JB_HOST}"
  echo "log syslog informational"
  echo "!"
  echo "router bgp ${asn}"
  echo " bgp router-id ${rid}"
  echo " no bgp ebgp-requires-policy"
  for ((i=0; i<nn; i++)); do
    echo " neighbor $(cfg ".routing.bgp.neighbors[$i].ip") remote-as $(cfg ".routing.bgp.neighbors[$i].asn")"
  done
  echo " !"
  echo " address-family ipv4 unicast"
  for ((i=0; i<N_VLANS; i++)); do echo "  network ${V_CIDR[i]}"; done
  for ((i=0; i<nn; i++)); do echo "  neighbor $(cfg ".routing.bgp.neighbors[$i].ip") activate"; done
  echo " exit-address-family"
  echo "!"
  echo "line vty"
  echo "!"
}

step_routing() {
  local NFT_BIN nat; NFT_BIN=$(command -v nft); nat=$(cfg_bool '.routing.nat' 'true')

  # ---- nftables ----
  write_file "${LAB_STATE_DIR}/nftables.conf" 0640 < <(_nft_render)
  "$NFT_BIN" -c -f "${LAB_STATE_DIR}/nftables.conf" || die "nftables ruleset failed validation."

  write_file /etc/systemd/system/nested-lab-nft.service 0644 <<EOF
# Managed by nested-vsphere-lab (routing).
[Unit]
Description=Nested vSphere Lab nftables ruleset
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NFT_BIN} -f ${LAB_STATE_DIR}/nftables.conf
ExecReload=${NFT_BIN} -f ${LAB_STATE_DIR}/nftables.conf
ExecStop=${NFT_BIN} flush ruleset

[Install]
WantedBy=multi-user.target
EOF
  svc_reload_units
  systemctl enable nested-lab-nft.service >/dev/null
  systemctl restart nested-lab-nft.service
  ok "nftables loaded (nat=${nat})."

  # ---- persistent static routes ----
  local nr; nr=$(cfg_len '.routing.static_routes')
  write_file "${LAB_STATE_DIR}/routes.sh" 0750 < <(_routes_render)
  write_file /etc/systemd/system/nested-lab-routes.service 0644 <<EOF
# Managed by nested-vsphere-lab (routing).
[Unit]
Description=Nested vSphere Lab static routes
After=network-online.target nested-lab-nft.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${LAB_STATE_DIR}/routes.sh

[Install]
WantedBy=multi-user.target
EOF
  svc_reload_units
  if (( nr > 0 )); then
    systemctl enable nested-lab-routes.service >/dev/null
    systemctl restart nested-lab-routes.service
    ok "applied ${nr} static route(s)."
  else
    systemctl disable nested-lab-routes.service >/dev/null 2>&1 || true
  fi

  # ---- optional FRR / BGP ----
  if [[ "$(cfg_bool '.routing.bgp.enabled' 'false')" == "true" ]]; then _routing_bgp; fi
}

_routing_bgp() {
  local asn; asn=$(cfg '.routing.bgp.local_asn')
  pkg_install frr
  if [[ -f /etc/frr/daemons ]]; then
    sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons
    grep -q '^bgpd=yes' /etc/frr/daemons || echo 'bgpd=yes' >>/etc/frr/daemons
  fi
  write_file /etc/frr/frr.conf 0640 < <(_frr_render)
  chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
  svc_enable_now frr
  svc_restart frr
  ok "FRR/BGP configured (ASN ${asn})."
}
