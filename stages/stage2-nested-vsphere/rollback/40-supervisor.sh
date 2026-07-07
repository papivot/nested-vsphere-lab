#!/usr/bin/env bash
# ============================================================================
# rollback/supervisor :: Disable the Supervisor (WCP) on the cluster and remove
# the content library. Best-effort and tolerant of missing objects.
# ============================================================================

rollback_supervisor() {
  local tok; tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}" 2>/dev/null || true)
  [[ -n "$tok" ]] || { warn "No vCenter session; cannot roll back Supervisor."; return 0; }

  # Disable WCP if it is configured on the cluster.
  local moid
  moid=$(vc_api GET "${VCSA_IP}" "$tok" "/api/vcenter/cluster" 2>/dev/null \
    | jq -r --arg n "${CLUSTER_NAME}" '.[] | select(.name == $n) | .cluster' 2>/dev/null | head -1 || true)
  if [[ -n "$moid" ]]; then
    local status
    status=$(vc_api GET "${VCSA_IP}" "$tok" \
      "/api/vcenter/namespace-management/clusters/${moid}" 2>/dev/null \
      | jq -r '.config_status // "NOT_CONFIGURED"' 2>/dev/null || echo "NOT_CONFIGURED")
    if [[ "$status" != "NOT_CONFIGURED" ]]; then
      log "Disabling Supervisor on '${CLUSTER_NAME}' (status ${status}) ..."
      curl -sk -X POST -H "vmware-api-session-id: ${tok}" \
        "https://${VCSA_IP}/api/vcenter/namespace-management/clusters/${moid}?action=disable" \
        >/dev/null 2>&1 \
        && ok "Supervisor disable requested." \
        || warn "Supervisor disable request failed; check the vCenter UI."
    else
      log "Supervisor not configured on '${CLUSTER_NAME}', nothing to disable."
    fi
  fi

  # Remove the content library.
  local id name
  for id in $(vc_api GET "${VCSA_IP}" "$tok" "/api/content/library" 2>/dev/null | jq -r '.[]' 2>/dev/null); do
    name=$(vc_api GET "${VCSA_IP}" "$tok" "/api/content/library/${id}" 2>/dev/null \
      | jq -r '.name // empty' 2>/dev/null || true)
    if [[ "$name" == "${CONTENT_LIB}" ]]; then
      log "Removing content library '${CONTENT_LIB}' (${id}) ..."
      curl -sk -X DELETE -H "vmware-api-session-id: ${tok}" \
        "https://${VCSA_IP}/api/content/library/${id}" >/dev/null 2>&1 \
        && ok "Content library removed." || warn "Could not remove content library."
      break
    fi
  done
}
