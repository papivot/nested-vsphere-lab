#!/usr/bin/env bash
# Rollback for routing: stop loaders, flush ruleset, remove units + config.
rollback_routing() {
  svc_stop_disable nested-lab-nft.service
  svc_stop_disable nested-lab-routes.service
  nft flush ruleset 2>/dev/null || true
  rm -f /etc/systemd/system/nested-lab-nft.service \
        /etc/systemd/system/nested-lab-routes.service \
        "${LAB_STATE_DIR}/nftables.conf" "${LAB_STATE_DIR}/routes.sh"
  if [[ "$(cfg_bool '.routing.bgp.enabled' 'false')" == "true" ]]; then
    svc_stop_disable frr
  fi
  svc_reload_units
  ok "Removed routing/NAT config and units."
}
