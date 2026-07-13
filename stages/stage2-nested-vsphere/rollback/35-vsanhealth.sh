#!/usr/bin/env bash
# ============================================================================
# rollback/vsanhealth :: no-op. Silencing the nested-only HCL/Support-Insight
# findings and enabling the Performance Service are both harmless, desirable
# states to leave in place -- there is nothing here that needs reversing.
# (To manually un-silence: RVC `vsan.health.silent_health_check_configure
# <path> -r <checkid>`; the Performance Service has no supported disable path
# per Broadcom KB, so it is not restored either.)
# ============================================================================

rollback_vsanhealth() {
  log "vsanhealth has nothing to undo (silenced findings + the Performance Service are left in place)."
}
