#!/usr/bin/env bash
# Rollback for dhcp: stop Kea, remove config (lease DB preserved for recovery).
rollback_dhcp() {
  svc_stop_disable "$KEA_SERVICE"
  rm -f "$KEA_CONF"
  ok "Removed Kea config (leases under /var/lib/kea preserved)."
}
