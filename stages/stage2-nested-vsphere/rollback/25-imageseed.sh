#!/usr/bin/env bash
# ============================================================================
# rollback/imageseed :: no-op. The imageseed step is a manual verify gate; it
# makes no change that needs reversing (it only ensures the datacenter exists,
# which `--rollback cluster` tears down along with the cluster/VDS/hosts). The
# extracted depot image is intentionally left in place — it is harmless and lets
# a subsequent run skip the manual seed.
# ============================================================================

rollback_imageseed() {
  log "imageseed has nothing to undo (the datacenter is removed by --rollback cluster; the seeded depot image is left in place)."
}
