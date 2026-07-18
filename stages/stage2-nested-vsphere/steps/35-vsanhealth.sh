#!/usr/bin/env bash
# ============================================================================
# vsanhealth :: Remediate the 3 vSAN health findings that are universal on
# nested/virtual hardware and block Supervisor's Spherelet install:
#   - "NVMe device is VMware certified" (HCL)      -- silenced (unfixable on
#   - "vSAN Support Insight"           (Info)      -- virtual disks/no HCL entry)
#   - "Performance service status"     (Warning)   -- REAL fix: enable the
#                                                       service (disabled by
#                                                       default on every fresh
#                                                       vSAN cluster)
#
# None of these have a REST/vim25 binding (they live on the legacy vsanHealth
# SOAP service); RVC -- bundled on every VCSA -- is the supported, documented
# way to drive them (validated live against a 9.1 VCSA: check IDs `nvmeonhcl`,
# `vsanenablesupportinsight`; commands confirmed via
# vsan.health.silent_health_check_status / vsan.perf.stats_object_create).
#
# Idempotent: gated on live health status (not silenced/already-fixed is a
# no-op); nothing here needs reversing (see rollback/35-vsanhealth.sh).
# ============================================================================

# _render_vsanhealth_commands <cluster-rvc-path>  (PURE)
# The RVC commands that remediate all 3 findings for the given cluster path.
_render_vsanhealth_commands() {
  local path="$1"
  printf 'vsan.health.silent_health_check_configure %s -a nvmeonhcl\n' "$path"
  printf 'vsan.health.silent_health_check_configure %s -a vsanenablesupportinsight\n' "$path"
  printf 'vsan.perf.stats_object_create %s\n' "$path"
}

step_vsanhealth() {
  local path; path=$(vcsa_rvc_cluster_path)

  if _vsanhealth_all_clear "$path"; then
    ok "vSAN health: HCL/NVMe certification + Performance Service already remediated."
    return
  fi

  log "Remediating nested-lab-only vSAN health findings (HCL NVMe cert, Support Insight, Performance Service) ..."
  local cmds=() line
  while IFS= read -r line; do cmds+=("$line"); done < <(_render_vsanhealth_commands "$path")
  local out
  out=$(vcsa_rvc "${cmds[@]}")
  log "RVC output:"
  printf '%s\n' "$out" | sed 's/^/  /'

  # vSAN health checks refresh on their own cadence, not instantly on fix, so
  # poll rather than re-check once (mirrors _wait_for_vsan_datastore).
  log "Waiting for vSAN health to reflect the fix (up to 3 min) ..."
  local elapsed=0 max=180
  while (( elapsed < max )); do
    _vsanhealth_all_clear "$path" && break
    sleep 20; (( elapsed += 20 )) || true
    log "  still showing a warning (${elapsed}/${max}s) ..."
  done
  _vsanhealth_all_clear "$path" || die "vSAN health findings still present after remediation and a ${max}s wait.
  Review the RVC output above, or check manually in the vSphere Client
  (Cluster -> Monitor -> vSAN -> Skyline Health). Retry with:
    sudo ./run.sh --stage 2 --from-step vsanhealth"
  ok "vSAN health findings cleared (HCL/NVMe + Support Insight silenced; Performance Service enabled)."
}

# _vsanhealth_all_clear <cluster-rvc-path>
# True if neither HCL-NVMe nor Performance-service currently shows "Warning" in
# vsan.health.health_summary. Silenced checks are documented to show as
# skipped/no-alarm, and the Performance Service fix is a real state change, so
# this single live check serves both as the pre-flight skip gate and the
# post-fix verification. (Support Insight is Info-level, not Warning, and is
# unconditionally re-silenced whenever this step actually runs -- see above --
# so it does not need its own gate condition here.)
_vsanhealth_all_clear() {
  local path="$1" summary
  summary=$(vcsa_rvc "vsan.health.health_summary ${path}")
  # A genuine health_summary response always starts with this line. Anything
  # else (SSH/RVC failure, bad password, sshpass missing, a network blip) has
  # no "Warning" substring either -- without this guard that would be
  # misread as "all clear", silently skipping remediation/verification
  # entirely instead of surfacing the real failure.
  if [[ "$summary" != *"Overall health findings"* ]]; then
    warn "vsan.health.health_summary returned no recognizable health data (RVC/SSH failure?): ${summary}"
    return 1
  fi
  ! printf '%s\n' "$summary" \
    | grep -E 'NVMe device is VMware certified|Performance service status' \
    | grep -q 'Warning'
}
