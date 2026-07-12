#!/usr/bin/env bash
# ============================================================================
# imageseed :: One-time MANUAL gate — seed the vLCM depot with the nested ESXi
# image before the cluster is built.
#
# Why this is manual: a freshly deployed vSphere 9.x vCenter bundles only OLDER
# fallback ESXi base images (e.g. 8.0U3), so the nested 9.x build is absent from
# the depot. There is NO supported REST API that extracts a host's *running*
# image into the depot (govc host.add auto-enables single-image management with
# the bundled image; a host software draft only inherits that desired image).
# The ONLY offline path is the vCenter Add-Host wizard's "Extract the image on
# the host." So this step ensures the datacenter exists (a target for the manual
# Add Host), prints the exact instructions, and then VERIFIES the depot really
# carries the build before letting `cluster` proceed.
#
# Interactive: after you extract the image in the UI, type `done` and it
# re-checks the depot — the cluster is built only once the image is present.
# Non-interactive (no TTY): it stops with a --from-step imageseed re-run hint.
#
# Idempotent + nothing to reverse: once the depot has the image it is a silent
# pass (see rollback/25-imageseed.sh — a no-op).
# ============================================================================

step_imageseed() {
  govc_target nested-vc

  # The operator adds the seed host to this datacenter, so it must exist first.
  if govc_object_exists "/${CLUSTER_DC}"; then
    ok "Datacenter '${CLUSTER_DC}' present (target for the seed host)."
  else
    log "Creating datacenter '${CLUSTER_DC}' (target for the manual Add Host) ..."
    govc datacenter.create -k "${CLUSTER_DC}" || die "datacenter.create failed"
  fi

  local seed_fqdn tok
  seed_fqdn="${NESXI_FQDN[0]}"

  while true; do
    tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}") \
      || die "Could not create vCenter session"

    # Verify: if the seed host is in inventory and the depot carries its build,
    # the seed is satisfied and the cluster step may proceed.
    local host_path build=""
    host_path=$(govc find -k "/${CLUSTER_DC}/host" -type h -name "${seed_fqdn}" 2>/dev/null | head -1)
    if [[ -n "$host_path" ]]; then
      build=$(govc object.collect -k -s "${host_path}" config.product.build 2>/dev/null || true)
      if [[ -n "$build" && -n "$(depot_base_image_for_build "${VCSA_IP}" "$tok" "$build")" ]]; then
        ok "vLCM depot carries the nested ESXi build ${build}; image seed satisfied."
        return
      fi
    fi

    _imageseed_instructions "$seed_fqdn" "$build"

    # No terminal (cron/headless): can't prompt — stop and let a re-run verify.
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
      die "Image seed not satisfied and no terminal to prompt on. Complete the
  manual extraction above, then re-run:  sudo ./run.sh --stage 2 --from-step imageseed"
    fi

    local ack=""
    printf '\n>>> After extracting the image in the vCenter UI, type "done" to continue (or "abort"): ' > /dev/tty
    read -r ack < /dev/tty || die "No input; re-run --from-step imageseed after extracting the image."
    ack=$(printf '%s' "$ack" | tr '[:upper:]' '[:lower:]')
    case "$ack" in
      done|d|y|yes) log "Re-checking the vLCM depot ..." ;;      # loop re-verifies
      abort|a|q|quit) die "Aborted at image seed. Re-run --from-step imageseed when ready." ;;
      *) warn "Unrecognized input '${ack}'. Type 'done' once the image is extracted, or 'abort'." ;;
    esac
  done
}

# _imageseed_instructions <seed-fqdn> <build-or-empty>
# Print the exact one-time manual step. Pure (no side effects).
_imageseed_instructions() {
  local seed_fqdn="$1" build="$2"
  log "======================================================================"
  log " MANUAL STEP — seed the vLCM depot with the nested ESXi image"
  log "======================================================================"
  log " A fresh vCenter carries only older fallback ESXi base images; the"
  log " nested build${build:+ (}${build}${build:+)} is not in the depot yet, and no API can extract a"
  log " host's running image offline. Do this once in the vCenter UI:"
  log ""
  log "   1. Log in to  https://${VCSA_FQDN}/ui   (${VCSA_USER})"
  log "   2. Right-click datacenter '${CLUSTER_DC}'  ->  Add Host"
  log "   3. Host: ${seed_fqdn}   User: root   (accept the thumbprint)"
  log "   4. At the image step choose:  'Extract the image on the host'"
  log "   5. Finish the wizard (wait for the extract to complete)."
  log ""
  log " The nested ESXi must have a persistent ESX-OSData volume on a dedicated"
  log " disk for the extract to succeed. The cluster step then moves this host"
  log " into the cluster and adds the rest."
  log "======================================================================"
}
