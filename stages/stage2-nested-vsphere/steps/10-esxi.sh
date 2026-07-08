#!/usr/bin/env bash
# ============================================================================
# esxi :: Deploy N nested ESXi VMs onto the underlying target (standalone ESXi
# or an existing vCenter). Deploy options come from the committed template
# templates/esxi.template.json (rendered with envsubst) — NOT a dynamically
# generated import.spec — so behaviour is stable across OVA versions.
#
# guestinfo.* is injected via `vm.change -e` (extraConfig), the mechanism the
# validated scratch/create-esxi.sh uses: on a standalone ESXi the OVF/vApp
# environment is not reliably presented, so the appliance reads guestinfo from
# extraConfig. The template's PropertyMapping additionally covers vCenter targets.
#
# Each VM = 1 boot disk (from the OVA) + the data disks in ESXI_DATA_DISK_GB,
# added BEFORE first power-on (OSA: 1 cache + 1 capacity of distinct sizes;
# ESA: pooled data disks).
# ============================================================================

_esxi_template() { printf '%s' "${STAGE2_DIR}/templates/esxi.template.json"; }

step_esxi() {
  govc_target underlying

  local i
  # Phase 1: deploy + attach disks + power on EVERY host first, so first-boot
  # happens concurrently across all nested ESXi.
  for ((i=0; i<N_NESXI; i++)); do
    local name="${NESXI_NAME[$i]}" ip="${NESXI_IP[$i]}"
    log "--- Nested ESXi ${name} (${ip}) ---"
    _deploy_esxi_vm "$name" "$ip"
    _add_esa_disks  "$name"
    _ensure_esxi_powered_on "$name"
  done

  # Phase 2: wait for each management API. Because all hosts are already
  # powered on, these waits overlap — total time is ~one boot, not the sum.
  for ((i=0; i<N_NESXI; i++)); do
    _wait_esxi_api "${NESXI_IP[$i]}"
    ok "Nested ESXi ${NESXI_NAME[$i]} (${NESXI_IP[$i]}) API-responsive."
  done
  ok "All ${N_NESXI} nested ESXi deployed and API-responsive."
}

# ---------------------------------------------------------------------------
# _render_esxi_options  (PURE)
# Render the govc import.ova options from the committed template. Requires
# ESXI_HOST_NAME / ESXI_HOST_IP exported for the current host. Testable: set
# the vars and assert the JSON (see step_esxi.bats). The explicit var list
# stops envsubst from touching anything unexpected.
# ---------------------------------------------------------------------------
_render_esxi_options() {
  envsubst '${ESXI_HOST_NAME} ${ESXI_HOST_IP} ${ESXI_NETMASK} ${ESXI_GW}
            ${NATIVE_GW} ${DOMAIN} ${NTP_SERVER} ${ESXI_ROOT_PASSWORD}
            ${ESXI_OVA_NETWORK} ${UNDERLYING_PG}' \
    < "$(_esxi_template)"
}

# ---------------------------------------------------------------------------
# Deploy one nested ESXi VM. Idempotent: skips if the VM exists.
# ---------------------------------------------------------------------------
_deploy_esxi_vm() {
  local name="$1" ip="$2"
  if govc_vm_exists "$name"; then
    ok "VM '${name}' already exists, skipping deploy."
    return
  fi

  # Resolve the OVA's internal network label (the NetworkMapping *Name*, which
  # must match a network the OVA defines — e.g. "VM Network"). Auto-detected
  # from the OVA (a stable field) unless overridden via stage2.esxi.ova_network.
  # The target portgroup (NetworkMapping *Network*) is always UNDERLYING_PG.
  if [[ -z "${ESXI_OVA_NETWORK:-}" ]]; then
    ESXI_OVA_NETWORK=$(govc import.spec -k "${ESXI_OVA}" 2>/dev/null \
      | jq -r '.NetworkMapping[0].Name // empty' 2>/dev/null || true)
    [[ -n "$ESXI_OVA_NETWORK" ]] || ESXI_OVA_NETWORK="VM Network"
  fi
  export ESXI_OVA_NETWORK
  log "Mapping OVA network '${ESXI_OVA_NETWORK}' -> portgroup '${UNDERLYING_PG}'"

  export ESXI_HOST_NAME="$name" ESXI_HOST_IP="$ip"
  local opts; opts=$(mktemp)
  _render_esxi_options >"$opts" || die "Failed to render ESXi import options for ${name}"
  jq empty "$opts" 2>/dev/null || die "Rendered ESXi options are not valid JSON (check secrets for quotes)"

  log "Deploying ${name} from ${ESXI_OVA} (this takes several minutes) ..."
  govc import.ova -k \
    -name    "$name" \
    -ds      "${UNDERLYING_DATASTORE}" \
    -options "$opts" \
    "${ESXI_OVA}" \
    || die "govc import.ova failed for ${name}"

  # Correct CPU/mem and expose hardware virtualisation + disk UUIDs (nested vSAN).
  govc vm.change -k -vm "$name" -c "${ESXI_CPU}" -m "$(( ESXI_MEM * 1024 ))" \
    || die "vm.change (cpu/mem) failed for ${name}"
  govc vm.change -k -vm "$name" -e vhv.enable=TRUE -e disk.EnableUUID=TRUE \
    || warn "Could not set vhv.enable/disk.EnableUUID for ${name}"
  govc vm.upgrade -k -vm "$name" 2>/dev/null || true

  # Inject guestinfo.* via extraConfig (validated), sourced from the SAME
  # rendered template so there is a single source of truth for the values.
  local eargs=() kv
  while IFS= read -r kv; do eargs+=(-e "$kv"); done < <(
    jq -r '.PropertyMapping[] | select(.Key | startswith("guestinfo.")) | "\(.Key)=\(.Value)"' "$opts"
  )
  govc vm.change -k -vm "$name" "${eargs[@]}" \
    || die "vm.change (guestinfo) failed for ${name}"

  rm -f "$opts"
  ok "VM '${name}' created (not yet powered on)."
}

# ---------------------------------------------------------------------------
# Attach the data disks BEFORE first power-on. Idempotent: expected disk count
# = 1 boot + N data disks.
# ---------------------------------------------------------------------------
_add_esa_disks() {
  local name="$1"
  local want=$(( 1 + ${#ESXI_DATA_DISK_GB[@]} ))
  local have
  have=$(govc device.info -k -vm "$name" -json 'disk-*' 2>/dev/null \
    | jq '.devices | length' 2>/dev/null || echo 0)

  if (( have >= want )); then
    ok "VM '${name}' already has ${have} disk(s) (want ${want}), skipping."
    return
  fi

  local i n=1
  for ((i=0; i<${#ESXI_DATA_DISK_GB[@]}; i++)); do
    log "Adding vSAN data disk ${n} (${ESXI_DATA_DISK_GB[$i]}G) to ${name} ..."
    govc vm.disk.create -k \
      -vm   "$name" \
      -name "${name}/${name}-vsan-${n}" \
      -size "${ESXI_DATA_DISK_GB[$i]}G" \
      || die "Failed to add vSAN data disk ${n} to ${name}"
    (( n++ )) || true
  done
  ok "vSAN data disks added to ${name}."
}

# ---------------------------------------------------------------------------
# Power on the VM if not already running.
# ---------------------------------------------------------------------------
_ensure_esxi_powered_on() {
  local name="$1"
  local state; state=$(govc_vm_power_state "$name")
  if [[ "$state" == "poweredOn" ]]; then
    ok "VM '${name}' already powered on."
    return
  fi
  log "Powering on ${name} ..."
  govc vm.power -k -on "$name" || die "vm.power -on failed for ${name}"
}

# ---------------------------------------------------------------------------
# Wait until the nested ESXi management UI (HTTPS :443) responds.
# ---------------------------------------------------------------------------
_wait_esxi_api() {
  local ip="$1"
  log "Waiting for nested ESXi at ${ip} to come up (up to 15 min) ..."
  wait_https "https://${ip}/ui/" 900
  ok "ESXi ${ip} API is responding."
}
