#!/usr/bin/env bash
# Rollback for dns: stop BIND, remove zones + generated config.
rollback_dns() {
  svc_stop_disable "$BIND_SERVICE"
  local i
  rm -f "${ZONES_DIR}/db.forward"
  for ((i=0; i<N_VLANS; i++)); do rm -f "${ZONES_DIR}/db.${V_NAME[i]}.rev"; done
  if [[ "$BIND_LAYOUT" == "include" ]]; then
    rm -f "$NAMED_LOCAL"
    : >"$NAMED_OPTIONS" 2>/dev/null || true
  fi
  ok "Removed BIND zones and generated config."
}
