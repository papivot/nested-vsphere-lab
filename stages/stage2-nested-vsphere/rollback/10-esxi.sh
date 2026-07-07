#!/usr/bin/env bash
# ============================================================================
# rollback/esxi :: Power off and destroy all nested ESXi VMs on the underlying
# ESXi. Targets the underlying host (GOVC_URL = underlying ESXi).
# ============================================================================

rollback_esxi() {
  govc_target underlying

  local i
  for ((i=0; i<N_NESXI; i++)); do
    local name="${NESXI_NAME[$i]}"
    if govc_vm_exists "$name"; then
      log "Destroying nested ESXi VM '${name}' ..."
      # vm.destroy powers off and deletes the VM and all its disks.
      govc vm.destroy -k "$name" \
        && ok "VM '${name}' destroyed." \
        || warn "Failed to destroy '${name}'; may need manual cleanup."
    else
      log "VM '${name}' not found, nothing to destroy."
    fi
  done
}
