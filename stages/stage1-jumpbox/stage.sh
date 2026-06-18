#!/usr/bin/env bash
# ============================================================================
# stage1-jumpbox/stage.sh - ordered step pipeline + derived facts + dispatch.
# Sourced by run.sh (which has already loaded lib/* and computed nothing yet).
# ============================================================================

STAGE1_DIR="${STAGE_DIR}"   # stages/stage1-jumpbox

# Ordered steps. preflight is always a hard gate and runs first.
STEPS=(preflight base_os certs networking routing dns dhcp registry labinfo)

# ---- shared lab paths (mirrors group_vars/all.yml lab.*) ----
LAB_STATE_DIR=/etc/nested-lab
LAB_INFO_FILE=/etc/nested-lab/lab-info.txt
MIN_DISK_GB=100

# Per-VLAN derived arrays (the Bash equivalent of Ansible's vlans_computed).
declare -a V_ID V_NAME V_CIDR V_DHCP V_GW V_PREFIX V_NETMASK V_IFACE V_ISNATIVE V_DSTART V_DEND V_REVZONE

compute_derived() {
  PRIVATE_NIC=$(cfg '.jumpbox.private_nic' 'ens224')
  PUBLIC_NIC=$(cfg '.jumpbox.public_nic' 'ens192')
  JB_HOST=$(cfg '.jumpbox.hostname' 'jump01')
  DOMAIN=$(cfg '.jumpbox.domain' 'env1.lab.test')
  MTU_PRIVATE=$(cfg '.mtu.private' '9000')
  NATIVE_VLAN=$(cfg '.network.native_vlan' '100')
  SUPERNET=$(cfg '.network.private_supernet' '192.168.100.0/22')

  local n i; n=$(cfg_len '.network.vlans'); N_VLANS=$n
  NATIVE_GW=""
  for ((i=0; i<n; i++)); do
    V_ID[i]=$(cfg ".network.vlans[$i].id")
    V_NAME[i]=$(cfg ".network.vlans[$i].name" "vlan${V_ID[i]}")
    V_CIDR[i]=$(cfg ".network.vlans[$i].cidr")
    V_DHCP[i]=$(cfg_bool ".network.vlans[$i].dhcp" 'true')
    V_GW[i]=$(cidr_gateway "${V_CIDR[i]}")
    V_PREFIX[i]=$(cidr_prefix "${V_CIDR[i]}")
    V_NETMASK[i]=$(cidr_netmask "${V_CIDR[i]}")
    V_DSTART[i]=$(cidr_dhcp_start "${V_CIDR[i]}")
    V_DEND[i]=$(cidr_dhcp_end "${V_CIDR[i]}")
    V_REVZONE[i]=$(reverse_zone_24 "${V_CIDR[i]}")
    if [[ "${V_ID[i]}" == "$NATIVE_VLAN" ]]; then
      V_ISNATIVE[i]=1; V_IFACE[i]="$PRIVATE_NIC"; NATIVE_GW="${V_GW[i]}"
    else
      V_ISNATIVE[i]=0; V_IFACE[i]="${PRIVATE_NIC}.${V_ID[i]}"
    fi
  done

  # Certs / registry
  CERTS_DIR=$(cfg '.certs.dir' '/etc/nested-lab/ca')
  CA_MODE=$(cfg '.certs.ca_mode' 'selfsigned')
  CA_BUNDLE="${CERTS_DIR}/ca-bundle.crt"
  REGISTRY_FQDN=$(cfg '.registry.fqdn' "harbor.${DOMAIN}")
  REGISTRY_IP=$(cfg '.registry.ip' '')
  HARBOR_IP="${REGISTRY_IP:-$NATIVE_GW}"
  REGISTRY_DATA=$(cfg '.registry.data_dir' '/data/harbor')
  REGISTRY_AUTH=$(cfg_bool '.registry.auth' 'false')
  ARTIFACTS_DIR=$(cfg '.artifacts.dir' '/data/isos')

  export PRIVATE_NIC PUBLIC_NIC JB_HOST DOMAIN MTU_PRIVATE NATIVE_VLAN SUPERNET N_VLANS NATIVE_GW
  export CERTS_DIR CA_MODE CA_BUNDLE REGISTRY_FQDN REGISTRY_IP HARBOR_IP REGISTRY_DATA REGISTRY_AUTH ARTIFACTS_DIR
}

# Source every step + rollback definition.
_load_steps() {
  local f
  for f in "${STAGE1_DIR}"/steps/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
  done
  for f in "${STAGE1_DIR}"/rollback/*.sh; do
    [[ -e "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

# Wipe checkpoints for the given step and everything after it (so they re-run).
stage_reset_from() {
  local from="$1" hit="" s
  for s in "${STEPS[@]}"; do
    [[ "$s" == "$from" ]] && hit=1
    [[ -n "$hit" ]] && unmark "$s"
  done
  [[ -n "$hit" ]] || die "--from-step '${from}' is not a stage-1 step: ${STEPS[*]}"
  log "Reset checkpoints from '${from}' onward; those steps will re-run."
}

stage_run() {
  _load_steps
  mkdir -p "$LAB_STATE_DIR"; chmod 0750 "$LAB_STATE_DIR"
  local s
  for s in "${STEPS[@]}"; do
    run_step "$s" "step_${s}"
  done
  printf '\n'
  ok "Stage ${STAGE} complete. Summary: ${LAB_INFO_FILE}"
}

stage_rollback() {
  _load_steps
  local step="$1"
  [[ -n "$step" ]] || die "--rollback needs a step name: ${STEPS[*]}"
  if ! declare -F "rollback_${step}" >/dev/null; then
    die "No rollback defined for step '${step}'. Steps with rollback: certs networking routing dns dhcp registry."
  fi
  CURRENT_STEP="rollback:${step}"
  log "Rolling back step '${step}'"
  "rollback_${step}"
  unmark "$step"
  ok "Rollback of '${step}' complete; checkpoint cleared."
}

stage_check() {
  _load_steps
  log "DRY-RUN plan for stage ${STAGE} (no changes will be made):"
  local s state
  for s in "${STEPS[@]}"; do
    if is_done "$s"; then state="done "; else state="TODO "; fi
    printf '   [%s] %s\n' "$state" "$s"
  done
  printf '\n'
  log "VLANs / derived model:"
  local i
  for ((i=0; i<N_VLANS; i++)); do
    printf '   VLAN %-5s %-10s %-18s gw=%-15s iface=%-14s dhcp=%s (%s-%s)\n' \
      "${V_ID[i]}" "${V_NAME[i]}" "${V_CIDR[i]}" "${V_GW[i]}" "${V_IFACE[i]}" \
      "${V_DHCP[i]}" "${V_DSTART[i]}" "${V_DEND[i]}"
  done
  printf '\n'
  log "Run for real with: ./run.sh --stage ${STAGE}"
}
