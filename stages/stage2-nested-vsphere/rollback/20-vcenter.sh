#!/usr/bin/env bash
# ============================================================================
# rollback/vcenter :: Power off and destroy the VCSA VM on the underlying ESXi.
# ============================================================================

rollback_vcenter() {
  govc_target underlying

  if govc_vm_exists "${VCSA_DNS_NAME}"; then
    log "Destroying VCSA VM '${VCSA_DNS_NAME}' ..."
    govc vm.destroy -k "${VCSA_DNS_NAME}" \
      && ok "VCSA VM '${VCSA_DNS_NAME}' destroyed." \
      || warn "Failed to destroy '${VCSA_DNS_NAME}'; may need manual cleanup."
  else
    log "VCSA VM '${VCSA_DNS_NAME}' not found, nothing to destroy."
  fi
}
