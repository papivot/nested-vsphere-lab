#!/usr/bin/env bash
# Rollback for the certs step. Backup dir under certs.backup_path is preserved.
rollback_certs() {
  rm -f "${CA_TRUST_DIR}/nested-lab-ca.crt"
  "$CA_TRUST_UPDATE" >/dev/null 2>&1 || true
  rm -rf "$CERTS_DIR"
  ok "Removed CA dir and trust anchor (backup preserved)."
}
