#!/usr/bin/env bash
# ============================================================================
# labinfo :: Print the Stage 2 access summary sheet.
# ============================================================================

step_labinfo() {
  write_file "$LAB2_INFO_FILE" 0640 < <(_lab2info_render)
  echo ""
  cat "$LAB2_INFO_FILE"
}

_lab2info_render() {
  local i
  echo "================================================================================"
  echo " Nested vSphere Lab - Stage 2 (vSphere ${S2_PROFILE})"
  echo " Generated: $(date -Is 2>/dev/null || date)"
  echo "================================================================================"
  echo ""
  echo "NESTED vCENTER"
  echo "  URL      : https://${VCSA_FQDN}/ui/"
  echo "  IP       : ${VCSA_IP}"
  echo "  Username : ${VCSA_USER}"
  echo "  Password : (in secrets.env VCSA_SSO_PASSWORD)"
  echo "  SSO      : ${VCSA_SSO_DOMAIN}"
  echo ""
  echo "NESTED ESXi HOSTS"
  for ((i=0; i<N_NESXI; i++)); do
    printf '  %-20s  %s\n' "${NESXI_FQDN[$i]}" "${NESXI_IP[$i]}"
  done
  echo "  Root password: (in secrets.env ESXI_ROOT_PASSWORD)"
  echo ""
  echo "CLUSTER"
  echo "  Datacenter : ${CLUSTER_DC}"
  echo "  Cluster    : ${CLUSTER_NAME}"
  echo "  VDS        : ${VDS_NAME}"
  echo "  vSAN       : ${VSAN_DS}  (OSA, FTT=${VSAN_FTT})"
  echo ""
  echo "SUPERVISOR / WORKLOAD MANAGEMENT"
  echo "  Profile          : ${S2_PROFILE} (Foundation Load Balancer)"
  echo "  Name             : ${SUPERVISOR_NAME}"
  echo "  Control plane    : ${SUPER_CP_SIZE} x ${SUPERVISOR_VM_COUNT}"
  echo "  Mgmt network     : ${SUPER_MGMT_NET} (VLAN ${SUPER_MGMT_VLAN_ID}) ${SUPER_MGMT_CIDR}"
  echo "  Workload network : ${SUPER_WKLD_NET} (VLAN ${SUPER_WKLD_VLAN_ID}) ${SUPER_WKLD_CIDR}"
  echo "  LB VIP range     : ${FLB_VIP_STARTING_IP} + ${FLB_VIP_IP_COUNT}"
  echo "  Storage policy   : ${STORAGE_POLICY}"
  echo "  Content library  : ${CONTENT_LIB}"
  echo ""
  echo "OCI REGISTRY (Stage 1)"
  echo "  https://${REGISTRY_FQDN}/   (reachable from workloads; wire as image source as needed)"
  echo ""
  echo "KUBECTL LOGIN (after Supervisor is RUNNING; VIP assigned from the range above)"
  echo "  kubectl vsphere login \\"
  echo "    --server ${FLB_VIP_STARTING_IP} \\"
  echo "    --vsphere-username ${VCSA_USER} \\"
  echo "    --insecure-skip-tls-verify"
  echo ""
  echo "VERIFY"
  echo "  ./run.sh --stage 2 --verify"
  echo "================================================================================"
}
