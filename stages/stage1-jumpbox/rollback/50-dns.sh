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

  # Undo the jumpbox resolver repoint.
  if [[ -f /etc/systemd/resolved.conf.d/nested-lab.conf ]]; then
    rm -f /etc/systemd/resolved.conf.d/nested-lab.conf
    svc_is_active systemd-resolved 2>/dev/null && svc_restart systemd-resolved || true
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null || true
  fi
  [[ -L /etc/resolv.conf ]] || sed -i "/^nameserver ${NATIVE_GW}\$/d; /^search ${DOMAIN}\$/d" /etc/resolv.conf 2>/dev/null || true

  ok "Removed BIND zones, generated config, and jumpbox resolver override."
}
