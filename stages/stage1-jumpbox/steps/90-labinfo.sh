#!/usr/bin/env bash
# ============================================================================
# labinfo :: render the customer-facing summary sheet and print it.
# Mirrors roles/labinfo.
# ============================================================================

step_labinfo() {
  write_file "$LAB_INFO_FILE" 0640 < <(_labinfo_render)
  echo ""
  cat "$LAB_INFO_FILE"
}

_labinfo_render() {
  local i nr fp
  fp=$(cat "${LAB_STATE_DIR}/ca-fingerprint.txt" 2>/dev/null || echo "(run certs step)")

  echo "================================================================================"
  echo " Nested vSphere Lab - Jumpbox (Stage 1)   ${JB_HOST}.${DOMAIN}"
  echo " Generated: $(date -Is 2>/dev/null || date)"
  echo "================================================================================"
  echo ""
  echo "ROLE OF THIS HOST"
  echo "  Router / NAT gateway, DNS, DHCP, and OCI registry for the nested vSphere lab."
  echo "  Egress is ONLY via the public NIC: ${PUBLIC_NIC}"
  echo "  Private fabric NIC (trunk): ${PRIVATE_NIC} (MTU ${MTU_PRIVATE})"
  echo ""
  echo "VLANS / SUBNETS  (gateway = .1, owned by this jumpbox)"
  for ((i=0; i<N_VLANS; i++)); do
    local tag="        "; [[ "${V_ISNATIVE[i]}" == 1 ]] && tag="(native)"
    echo "  - VLAN ${V_ID[i]} ${tag} ${V_NAME[i]}"
    echo "      subnet : ${V_CIDR[i]}"
    echo "      gateway: ${V_GW[i]}   iface: ${V_IFACE[i]}"
    if [[ "${V_DHCP[i]}" == "true" ]]; then
      echo "      DHCP   : enabled  ${V_DSTART[i]} - ${V_DEND[i]}"
    else
      echo "      DHCP   : disabled"
    fi
  done
  echo ""
  echo "DNS  (${NATIVE_GW})"
  echo "  forward zone : ${DOMAIN}"
  printf '  forwarders   :'
  nr=$(cfg_len '.dns.forwarders')
  if (( nr == 0 )); then printf ' 8.8.8.8, 1.1.1.1'; else
    for ((i=0; i<nr; i++)); do printf ' %s' "$(cfg ".dns.forwarders[$i]")$([[ $i -lt $((nr-1)) ]] && echo ,)"; done
  fi; echo ""
  echo "  pre-created records:"
  nr=$(cfg_len '.dns.records')
  for ((i=0; i<nr; i++)); do
    printf '    %-22s %s\n' "$(cfg ".dns.records[$i].name").${DOMAIN}" "$(cfg ".dns.records[$i].ip")"
  done
  echo ""
  echo "TIME (NTP)"
  echo "  No local NTP server. Nested nodes use upstream via NAT (DHCP option 42):"
  printf '    '
  nr=$(cfg_len '.ntp.upstream')
  if (( nr == 0 )); then printf 'time.vmware.com'; else
    for ((i=0; i<nr; i++)); do printf '%s ' "$(cfg ".ntp.upstream[$i]")"; done
  fi; echo ""
  echo ""
  echo "OCI REGISTRY (registry:2)"
  echo "  URL      : https://${REGISTRY_FQDN}/"
  echo "  IP       : ${HARBOR_IP}"
  echo "  data dir : ${REGISTRY_DATA}"
  echo "  auth     : ${REGISTRY_AUTH}  $( [[ "$REGISTRY_AUTH" == true ]] && echo '(user: admin; password in secrets.env)' )"
  echo ""
  echo "PKI / CA  (trusted end-to-end; distributed to nested nodes in Stage 2)"
  echo "  mode        : ${CA_MODE}"
  echo "  CA bundle   : ${CA_BUNDLE}"
  echo "  CA backup   : $(cfg '.certs.backup_path' '/root/lab-ca-backup')/"
  echo "  fingerprint : ${fp}"
  echo ""
  echo "ARTIFACTS (OVA/ISO for Stage 2)"
  echo "  local folder: ${ARTIFACTS_DIR}"
  echo ""
  echo "NEXT STEP"
  echo "  Stage 2 will deploy nested ESXi + vCenter and enable Supervisor, reusing this"
  echo "  jumpbox's DNS, DHCP, CA bundle, and registry."
  echo "================================================================================"
}
