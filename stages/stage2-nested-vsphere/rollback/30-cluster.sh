#!/usr/bin/env bash
# ============================================================================
# rollback/cluster :: Tear down the nested vCenter inventory objects the
# cluster step created: storage policy + tags, then the datacenter (which
# recursively removes the cluster, VDS, and host inventory entries). The
# nested ESXi VMs themselves are removed by `--rollback esxi`.
# Roll back the supervisor first if it is still enabled.
# ============================================================================

rollback_cluster() {
  govc_target nested-vc

  # Storage policy + tags (vCenter-global; not under the datacenter).
  # storage.policy.rm takes the policy ID, not its name — resolve it first.
  local pid
  pid=$(govc storage.policy.ls -k -json 2>/dev/null \
    | jq -r --arg n "${STORAGE_POLICY}" \
        '[.. | objects | select((.name? // .Name?) == $n)] | (.[0].id // .[0].Id // empty)' \
    2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    log "Removing storage policy '${STORAGE_POLICY}' (${pid}) ..."
    govc storage.policy.rm -k "$pid" \
      && ok "Storage policy removed." || warn "Could not remove storage policy."
  else
    warn "Storage policy '${STORAGE_POLICY}' not found (or ID unresolved); skipping."
  fi
  local cat="${STORAGE_POLICY}-cat" tag="${STORAGE_POLICY}-tag"
  govc tags.rm -k -c "$cat" "$tag" 2>/dev/null || true
  govc tags.category.rm -k "$cat" 2>/dev/null || true

  # Datacenter (recursively removes cluster, VDS, host inventory objects).
  if govc_object_exists "/${CLUSTER_DC}"; then
    log "Destroying datacenter '${CLUSTER_DC}' (cluster + VDS + hosts) ..."
    govc object.destroy -k "/${CLUSTER_DC}" \
      && ok "Datacenter '${CLUSTER_DC}' destroyed." \
      || warn "Failed to destroy datacenter '${CLUSTER_DC}'; may need manual cleanup."
  else
    log "Datacenter '${CLUSTER_DC}' not found, nothing to destroy."
  fi
}
