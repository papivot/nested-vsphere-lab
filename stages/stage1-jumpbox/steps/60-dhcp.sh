#!/usr/bin/env bash
# ============================================================================
# dhcp :: Kea DHCPv4, one subnet per DHCP-enabled VLAN. Pool = last /26 of each
# /24 (.193-.254). Advertises gateway, DNS, domain-search, jumbo MTU (option 26)
# and upstream NTP (option 42), plus static reservations. Mirrors roles/dhcp_kea.
# ============================================================================

step_dhcp() {
  pkg_install "${KEA_PACKAGES[@]}"
  local kuser; kuser=$(_kea_user)
  mkdir -p /etc/kea /var/lib/kea /var/log/kea
  if [[ -n "$kuser" ]]; then chown "$kuser" /var/lib/kea /var/log/kea 2>/dev/null || true; fi

  # `< <(fn)` (not a pipe) so FILE_CHANGED is set in this shell, not a subshell.
  write_file "$KEA_CONF" 0644 < <(_dhcp_config)
  local changed="$FILE_CHANGED"

  # Validate AS the Kea runtime user (e.g. _kea on Ubuntu). Running `kea-dhcp4 -t`
  # as root trips the kea-dhcp4 AppArmor profile (dac_override DENIED), because the
  # confined root process can't traverse /etc/kea -- which the service user owns.
  _kea_validate "$kuser" || die "Kea config failed validation (${KEA_BIN} -t)."

  svc_enable_now "$KEA_SERVICE"
  [[ "$changed" == yes ]] && svc_restart "$KEA_SERVICE"
  ok "Kea DHCPv4 active (${KEA_SERVICE})."
}

# The system user the Kea service runs as (Ubuntu/Debian: _kea). Empty if none.
_kea_user() {
  if   id _kea >/dev/null 2>&1; then echo _kea
  elif id kea  >/dev/null 2>&1; then echo kea
  fi
}

# Run `kea-dhcp4 -t` as the service user so AppArmor/DAC match runtime.
_kea_validate() {
  local kuser="$1"
  if [[ -n "$kuser" ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$kuser" -- "$KEA_BIN" -t "$KEA_CONF"
  else
    "$KEA_BIN" -t "$KEA_CONF"
  fi
}

_dhcp_config() {
  local i k lease nn u nr
  lease=$(cfg '.dhcp.lease_time' '86400')

  # upstream NTP IPs only (FQDNs are dropped for option 42)
  local ntp_join=""
  nn=$(cfg_len '.ntp.upstream')
  for ((k=0; k<nn; k++)); do u=$(cfg ".ntp.upstream[$k]"); is_ipv4 "$u" && ntp_join+="${ntp_join:+, }$u"; done

  nr=$(cfg_len '.dhcp.reservations')
  local subnets=() ifaces=()
  for ((i=0; i<N_VLANS; i++)); do
    [[ "${V_DHCP[i]}" == "true" ]] || continue
    ifaces+=("${V_IFACE[i]}")

    # reservations for this VLAN id
    local res=()
    for ((k=0; k<nr; k++)); do
      if [[ "$(cfg ".dhcp.reservations[$k].vlan")" == "${V_ID[i]}" ]]; then
        res+=("$(jq -n --arg m "$(cfg ".dhcp.reservations[$k].mac")" --arg ip "$(cfg ".dhcp.reservations[$k].ip")" \
          '{ "hw-address":$m, "ip-address":$ip }')")
      fi
    done
    local res_json='[]'; ((${#res[@]})) && res_json=$(printf '%s\n' "${res[@]}" | jq -s '.')

    local opts
    opts=$(jq -n --arg gw "${V_GW[i]}" --arg dom "$DOMAIN" --arg mtu "$MTU_PRIVATE" --arg ntp "$ntp_join" '
      [ {name:"routers",             data:$gw},
        {name:"domain-name-servers", data:$gw},
        {name:"domain-name",         data:$dom},
        {name:"domain-search",       data:$dom},
        {name:"interface-mtu",       data:$mtu} ]
      + (if ($ntp|length)>0 then [{name:"ntp-servers",data:$ntp}] else [] end)')

    subnets+=("$(jq -n --argjson id "${V_ID[i]}" --arg subnet "${V_CIDR[i]}" --arg iface "${V_IFACE[i]}" \
      --arg pool "${V_DSTART[i]} - ${V_DEND[i]}" --argjson opts "$opts" --argjson res "$res_json" '
      { id:$id, subnet:$subnet, interface:$iface, pools:[{pool:$pool}],
        "option-data":$opts, reservations:$res }')")
  done

  local subnets_json='[]' ifaces_json='[]'
  ((${#subnets[@]})) && subnets_json=$(printf '%s\n' "${subnets[@]}" | jq -s '.')
  ((${#ifaces[@]}))  && ifaces_json=$(printf '%s\n' "${ifaces[@]}" | jq -R . | jq -s '.')

  jq -n --argjson lease "$lease" --argjson subnets "$subnets_json" --argjson ifaces "$ifaces_json" '
    { "Dhcp4": {
        "interfaces-config": { "interfaces": $ifaces, "dhcp-socket-type": "raw" },
        "lease-database":     { "type": "memfile", "persist": true, "name": "/var/lib/kea/kea-leases4.csv" },
        "valid-lifetime":     $lease,
        "loggers": [ { "name": "kea-dhcp4", "output_options": [ { "output": "/var/log/kea/kea-dhcp4.log" } ], "severity": "INFO" } ],
        "subnet4": $subnets
    } }'
}
