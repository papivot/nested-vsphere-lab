#!/usr/bin/env bash
# ============================================================================
# vcenter :: Deploy the VCSA with the supported vcsa-deploy CLI shipped in the
# VCSA installer ISO (the validated scratch/create-vcenter.sh flow), then wait
# for first-boot. Idempotent: if the VCSA VM already exists we skip the deploy
# and only re-verify health.
# ============================================================================

# Path to the vcsa-deploy binary inside the mounted ISO.
_vcsa_deploy_bin() { printf '%s' "${VCSA_ISO_MOUNT}/vcsa-cli-installer/lin64/vcsa-deploy"; }
# Committed install-config template — the .vc variant (existing vCenter target)
# or the .esxi variant (standalone ESXi target), selected by underlying.type.
_vcsa_template() {
  if [[ "${UNDERLYING_TYPE:-esxi}" == "vcenter" ]]; then
    printf '%s' "${STAGE2_DIR}/templates/vcsa.vc.json.tmpl"
  else
    printf '%s' "${STAGE2_DIR}/templates/vcsa.esxi.json.tmpl"
  fi
}

step_vcenter() {
  govc_target underlying

  if govc_vm_exists "${VCSA_DNS_NAME}"; then
    ok "VCSA VM '${VCSA_DNS_NAME}' already exists; skipping vcsa-deploy."
  else
    _run_vcsa_deploy
  fi

  _reconfigure_vcsa_hw
  _wait_vcsa_ready
  ok "vCenter ${VCSA_FQDN} (${VCSA_IP}) is deployed and operational."
}

# ---------------------------------------------------------------------------
# Resize the VCSA VM to the desired vCPU/memory (VCSA_CPU / VCSA_MEM_GB).
# vcsa-deploy always deploys at a fixed deployment_option size, so we adjust
# afterward. We only ever INCREASE, so try CPU/memory HOT-ADD first (no
# downtime); if the appliance's VM does not have hot-add enabled, fall back to a
# graceful power-cycle. Idempotent: a no-op once the VM already matches.
# ---------------------------------------------------------------------------
_reconfigure_vcsa_hw() {
  govc_target underlying
  local want_mem_mb=$(( VCSA_MEM_GB * 1024 )) info cur_cpu cur_mem_mb
  info=$(govc vm.info -k -json "${VCSA_DNS_NAME}" 2>/dev/null || true)
  cur_cpu=$(printf '%s' "$info" | jq -r '.virtualMachines[0].config.hardware.numCPU // empty')
  cur_mem_mb=$(printf '%s' "$info" | jq -r '.virtualMachines[0].config.hardware.memoryMB // empty')
  [[ -n "$cur_cpu" && -n "$cur_mem_mb" ]] \
    || die "Could not read VCSA VM hardware for '${VCSA_DNS_NAME}'"

  if (( cur_cpu == VCSA_CPU && cur_mem_mb == want_mem_mb )); then
    ok "VCSA already ${VCSA_CPU} vCPU / ${VCSA_MEM_GB} GB."
    return
  fi
  if (( cur_cpu > VCSA_CPU || cur_mem_mb > want_mem_mb )); then
    warn "VCSA is ${cur_cpu} vCPU / $(( cur_mem_mb / 1024 )) GB, larger than the requested ${VCSA_CPU} vCPU / ${VCSA_MEM_GB} GB; leaving as-is (hot-remove is unsupported)."
    return
  fi

  log "Resizing VCSA ${cur_cpu} vCPU / $(( cur_mem_mb / 1024 )) GB -> ${VCSA_CPU} vCPU / ${VCSA_MEM_GB} GB ..."
  # Hot-add path: VCSA is powered on after firstboot and we only increase.
  if [[ "$(govc_vm_power_state "${VCSA_DNS_NAME}")" == "poweredOn" ]] \
     && govc vm.change -k -vm "${VCSA_DNS_NAME}" -c "${VCSA_CPU}" -m "${want_mem_mb}" 2>/dev/null; then
    ok "VCSA hot-resized to ${VCSA_CPU} vCPU / ${VCSA_MEM_GB} GB (no downtime)."
    return
  fi

  warn "Hot-add unavailable on the VCSA VM; power-cycling to resize ..."
  govc vm.power -k -s=true "${VCSA_DNS_NAME}" 2>/dev/null \
    || govc vm.power -k -off -force "${VCSA_DNS_NAME}" 2>/dev/null || true
  local e=0
  while (( e < 300 )); do
    [[ "$(govc_vm_power_state "${VCSA_DNS_NAME}")" == "poweredOff" ]] && break
    sleep 10; (( e += 10 )) || true
  done
  govc vm.change -k -vm "${VCSA_DNS_NAME}" -c "${VCSA_CPU}" -m "${want_mem_mb}" \
    || die "Failed to reconfigure VCSA hardware"
  govc vm.power -k -on "${VCSA_DNS_NAME}" || die "Failed to power the VCSA back on"
  ok "VCSA resized to ${VCSA_CPU} vCPU / ${VCSA_MEM_GB} GB (via power-cycle)."
}

# ---------------------------------------------------------------------------
# _render_vcsa_json  (PURE)
# Render the vcsa-deploy install config from the committed template using the
# exported model. Testable: set the vars and diff the JSON (step_vcenter.bats).
# The explicit var list keeps envsubst from touching anything unexpected.
# ---------------------------------------------------------------------------
_render_vcsa_json() {
  envsubst '${UNDERLYING_HOST} ${UNDERLYING_USER} ${UNDERLYING_PASSWORD}
            ${UNDERLYING_PG} ${UNDERLYING_DATASTORE} ${UNDERLYING_DATACENTER}
            ${UNDERLYING_CLUSTER} ${VCSA_SIZE} ${VCSA_DNS_NAME}
            ${VCSA_FQDN} ${VCSA_IP} ${VCSA_PREFIX} ${VCSA_GW} ${NATIVE_GW}
            ${VCSA_SSO_PASSWORD} ${NTP_SERVER} ${VCSA_SSO_DOMAIN}' \
    < "$(_vcsa_template)"
}

# ---------------------------------------------------------------------------
# Mount the VCSA ISO (idempotent) and run vcsa-deploy install.
# ---------------------------------------------------------------------------
_run_vcsa_deploy() {
  local json; json=$(mktemp)
  _render_vcsa_json >"$json" || die "Failed to render VCSA install config"
  jq empty "$json" 2>/dev/null || die "Rendered VCSA config is not valid JSON (check secrets for quotes)"

  mkdir -p "${VCSA_ISO_MOUNT}"
  if mountpoint -q "${VCSA_ISO_MOUNT}"; then
    ok "VCSA ISO already mounted at ${VCSA_ISO_MOUNT}."
  else
    log "Mounting ${VCSA_ISO} at ${VCSA_ISO_MOUNT} ..."
    mount -o loop,ro "${VCSA_ISO}" "${VCSA_ISO_MOUNT}" \
      || die "Failed to mount ${VCSA_ISO} at ${VCSA_ISO_MOUNT}"
  fi

  local installer; installer=$(_vcsa_deploy_bin)
  [[ -x "$installer" ]] \
    || die "vcsa-deploy not found at ${installer} (is the VCSA ISO correct?)"

  log "Running vcsa-deploy for ${VCSA_FQDN} (this takes 20-40 min) ..."
  "$installer" install \
    --accept-eula \
    --acknowledge-ceip \
    --no-ssl-certificate-verification \
    --terse \
    "$json" \
    || die "vcsa-deploy failed. Check the installer log; rollback with --rollback vcenter, then re-run."

  rm -f "$json"
  # Best-effort unmount; leaving it mounted is harmless (mount is idempotent).
  umount "${VCSA_ISO_MOUNT}" 2>/dev/null || true
  ok "vcsa-deploy completed for '${VCSA_DNS_NAME}'."
}

# ---------------------------------------------------------------------------
# Wait for the VCSA to be fully operational.
#   Phase 1: appliance REST /api/appliance/system/version -> 200
#   Phase 2: vCenter inventory /api/vcenter/datacenter    -> 200 (session auth)
# ---------------------------------------------------------------------------
_wait_vcsa_ready() {
  local base="https://${VCSA_IP}"

  # Gate on the SOAP `about` call (the validated scratch/create-vcenter.sh
  # signal). Do NOT poll /api/ REST with basic auth: those endpoints reject
  # basic auth with HTTP 401 — a session token from POST /api/session is
  # required first (see the inventory check below, which does that).
  log "Waiting for the vCenter API to come up (up to 30 min) ..."
  govc_target nested-vc
  local elapsed=0 max=1800
  while (( elapsed < max )); do
    govc about -k >/dev/null 2>&1 && break
    sleep 30; (( elapsed += 30 )) || true
    log "  vCenter API not ready yet, ${elapsed}/${max}s ..."
  done
  (( elapsed < max )) || die "Timed out waiting for the vCenter API at ${VCSA_IP}"
  ok "vCenter SOAP API is responding."

  log "Waiting for vCenter inventory API (up to 10 min) ..."
  local e2=0 max2=600 tok dc_code
  while (( e2 < max2 )); do
    tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}" || true)
    if [[ -n "$tok" ]]; then
      dc_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        -H "vmware-api-session-id: ${tok}" \
        "${base}/api/vcenter/datacenter" 2>/dev/null || true)
      [[ "$dc_code" == "200" ]] && break
    fi
    sleep 20; (( e2 += 20 )) || true
    log "  vCenter inventory not ready (${e2}/${max2}s) ..."
  done
  (( e2 < max2 )) || die "Timed out waiting for vCenter inventory API"
  ok "vCenter ${VCSA_FQDN} is fully operational."
}
