#!/usr/bin/env bash
# ============================================================================
# cluster :: Build the nested vSphere cluster inside the newly deployed vCenter.
#   Runs after the `imageseed` step has ensured the vLCM depot carries the nested
#   ESXi build (a fresh 9.x vCenter bundles only older fallback base images).
#   1. Create datacenter + cluster (+ DRS). The datacenter already exists (the
#      imageseed step created it as the target for the manual Add Host).
#   2. Add the nested ESXi hosts to the cluster. The seed host is already in the
#      datacenter (standalone, added by the operator during imageseed); it is
#      moved into the cluster (re-added), and the remaining hosts are added.
#   3. Align the cluster's vLCM desired image to the ESXi build the hosts run.
#      A fresh 9.x cluster is auto-managed with a single image from the
#      vCenter's *bundled* base (an older 8.0U3), which does NOT match the
#      nested hosts -- and Supervisor refuses to install the Spherelet on an
#      image-noncompliant cluster. We create a draft, set base_image.version to
#      the build the hosts run (in the depot from the imageseed step), and
#      commit. The hosts are then compliant, so no remediation/reboot fires.
#   4. Create VDS + portgroups (one per Stage 1 VLAN + edge trunk uplinks)
#   5. Add hosts to the VDS; enable vSAN + vMotion vmk services; exit maint.
#   6. Enable vSAN (OSA) + HA: `govc cluster.change -vsan-enabled` plus a
#      per-host disk group via `esxcli vsan storage add` (cache + capacity,
#      ported from scratch/create-cluster.sh.osa), then HA via vim25 REST with
#      das.ignoreRedundantNetWarning. OSA (not ESA) is used deliberately -- it
#      is far lighter on memory, which suits nested hosts.
#   7. Create the WCP storage tag + policy.
# ============================================================================

# ---- pure render fns: vim25 ClusterConfigSpecEx bodies (bats-testable) -----

# vLCM draft BaseImageSpec: the desired ESXi base-image version for the cluster.
_render_base_image_spec() {
  jq -n --arg v "$1" '{ "version": $v }'
}

_render_ha_spec() {
  jq -n '{
    "_typeName": "ClusterConfigSpecEx",
    "dasConfig": {
      "_typeName": "ClusterDasConfigInfo",
      "enabled": true,
      "option": [ {
        "_typeName": "OptionValue",
        "key": "das.ignoreRedundantNetWarning",
        "value": { "_typeName": "string", "_value": "true" }
      } ]
    }
  }'
}

# ---------------------------------------------------------------------------

step_cluster() {
  govc_target nested-vc

  _create_dc_and_cluster
  _add_hosts_to_cluster
  _align_cluster_image
  _create_vds_and_portgroups
  _add_hosts_to_vds
  _configure_vsan
  _create_storage_policy

  ok "Nested cluster '${CLUSTER_DC}/${CLUSTER_NAME}' (vSAN OSA) is configured."
}

# 1. Datacenter + cluster + DRS.
_create_dc_and_cluster() {
  if govc_object_exists "/${CLUSTER_DC}"; then
    ok "Datacenter '${CLUSTER_DC}' already exists."
  else
    log "Creating datacenter '${CLUSTER_DC}' ..."
    govc datacenter.create -k "${CLUSTER_DC}" || die "datacenter.create failed"
  fi

  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}"
  if govc_object_exists "$cluster_path"; then
    ok "Cluster '${CLUSTER_NAME}' already exists."
  else
    log "Creating cluster '${CLUSTER_NAME}' ..."
    govc cluster.create -k -dc "${CLUSTER_DC}" "${CLUSTER_NAME}" \
      || die "cluster.create failed"
  fi
  govc cluster.change -k -drs-enabled "$cluster_path" \
    || warn "Could not set DRS on '${CLUSTER_NAME}' (may already be enabled)"
}

# _host_leave_vsan_direct <esxi-ip>
# Make a nested ESXi leave any vSAN cluster it is still a member of, talking to
# the host directly (it is not yet in vCenter inventory). vSAN membership lives
# at the ESXi level, so re-running over hosts from a prior deployment makes
# cluster.add fail with "vSAN host cannot be moved to the destination cluster:
# ... vSAN disabled". Leaving first clears that; it is a harmless no-op on a
# freshly deployed host that was never in a vSAN cluster.
_host_leave_vsan_direct() {
  local ip="$1"
  GOVC_URL="https://${ip}/sdk" GOVC_USERNAME="root" \
    GOVC_PASSWORD="${ESXI_ROOT_PASSWORD}" GOVC_INSECURE=true \
    GOVC_DATACENTER="" GOVC_DATASTORE="" \
    govc host.esxcli -k vsan cluster leave >/dev/null 2>&1 || true
}

# 2. Add nested ESXi hosts to the cluster (by FQDN; thumbprint fetched explicitly).
_add_hosts_to_cluster() {
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" i
  for ((i=0; i<N_NESXI; i++)); do
    local fqdn="${NESXI_FQDN[$i]}"
    if govc find "${cluster_path}" -type h -name "${fqdn}" 2>/dev/null | grep -q .; then
      ok "Host '${fqdn}' already in cluster."
      continue
    fi
    # If the host is still registered standalone (e.g. the seed host whose
    # removal did not complete), drop that registration first so cluster.add
    # does not fail with "host already managed by this vCenter".
    local leftover
    leftover=$(govc find -k "/${CLUSTER_DC}/host" -type h -name "${fqdn}" 2>/dev/null | head -1)
    if [[ -n "$leftover" ]]; then
      warn "Host '${fqdn}' is registered standalone; removing before cluster add ..."
      govc host.remove -k "${leftover}" 2>/dev/null || true
    fi
    # Clear residual vSAN membership so the (vSAN-disabled) cluster accepts it.
    _host_leave_vsan_direct "${NESXI_IP[$i]}"
    log "Adding host '${fqdn}' to cluster ..."
    # -noverify accepts the nested ESXi self-signed cert without a thumbprint
    # (matches scratch/create-cluster.sh). Do NOT pass -thumbprint from
    # `about.cert -thumbprint`: govc now emits a SHA-256 thumbprint, but
    # spec.sslThumbprint expects SHA-1, so vCenter rejects it.
    govc cluster.add -k \
      -cluster  "${cluster_path}" \
      -hostname "${fqdn}" \
      -username "root" \
      -password "${ESXI_ROOT_PASSWORD}" \
      -noverify -force \
      || die "cluster.add failed for ${fqdn}"
    ok "Host '${fqdn}' added to cluster."
  done
}

# 3. Align the cluster's vLCM desired image with the build the hosts run.
#    Idempotent: skips when the committed base image already matches the hosts.
#    Deterministic -- the target version is read from a host in the cluster and
#    matched against the vCenter depot, so it tracks whatever ESXi build the OVA
#    ships (no hardcoded version string).
_align_cluster_image() {
  local host_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}/${NESXI_FQDN[0]}"

  # Build number of a host already in the cluster (e.g. 25370933).
  local build
  build=$(govc object.collect -k -s "$host_path" config.product.build 2>/dev/null || true)
  [[ -n "$build" ]] || die "Could not read ESXi build from ${NESXI_FQDN[0]} to align the cluster image"

  local tok moid
  tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}") \
    || die "Could not create vCenter session"
  moid=$(vc_api GET "${VCSA_IP}" "$tok" "/api/vcenter/cluster" \
    | jq -r --arg n "${CLUSTER_NAME}" '.[] | select(.name == $n) | .cluster' | head -1)
  [[ -n "$moid" ]] || die "Could not resolve cluster MOID for '${CLUSTER_NAME}'"

  # Desired base-image version = the depot entry whose build matches the host.
  local want
  want=$(depot_base_image_for_build "${VCSA_IP}" "$tok" "$build")
  [[ -n "$want" ]] \
    || die "No vCenter depot base image matches ESXi build ${build}. The 'imageseed' step should have seeded it; re-run --from-step imageseed."

  # Current committed desired image; skip if it already matches.
  local cur
  cur=$(vc_api GET "${VCSA_IP}" "$tok" "/api/esx/settings/clusters/${moid}/software" \
    | jq -r '.base_image.version // empty')
  if [[ "$cur" == "$want" ]]; then
    ok "Cluster desired image already '${want}' (matches hosts); skipping alignment."
    return
  fi
  log "Aligning cluster desired image '${cur:-<none>}' -> '${want}' (host build ${build}) ..."

  # vLCM allows a single draft per user per cluster; clear any stale one so a
  # re-run after a mid-step failure converges instead of erroring on AlreadyExists.
  local d
  for d in $(vc_api GET "${VCSA_IP}" "$tok" \
      "/api/esx/settings/clusters/${moid}/software/drafts" 2>/dev/null \
      | jq -r 'keys[]? // empty'); do
    vc_api DELETE "${VCSA_IP}" "$tok" \
      "/api/esx/settings/clusters/${moid}/software/drafts/${d}" >/dev/null 2>&1 || true
  done

  # Draft is initialised from the current desired document; we override only the
  # base image, then commit. Committing merely records the desired image -- the
  # hosts already run this build, so they stay compliant with no remediation.
  local draft
  draft=$(vc_api POST "${VCSA_IP}" "$tok" \
    "/api/esx/settings/clusters/${moid}/software/drafts" | tr -d '"')
  [[ -n "$draft" ]] || die "Could not create a vLCM software draft on '${CLUSTER_NAME}'"

  vc_api PUT "${VCSA_IP}" "$tok" \
    "/api/esx/settings/clusters/${moid}/software/drafts/${draft}/software/base-image" \
    -d "$(_render_base_image_spec "$want")" >/dev/null \
    || die "Could not set the draft base image to '${want}'"

  # Commit is a task-only operation: it exists only with vmw-task=true (a plain
  # ?action=commit returns HTTP 404), and it requires a commit_spec body (all
  # fields optional -> {} is valid; omitting the body is HTTP 400 "Missing field
  # [spec]"). We poll the committed image below rather than waiting on the task.
  vc_api POST "${VCSA_IP}" "$tok" \
    "/api/esx/settings/clusters/${moid}/software/drafts/${draft}?action=commit&vmw-task=true" \
    -d '{}' >/dev/null \
    || die "Could not commit the vLCM software draft"

  # Poll the committed desired image until it reflects the new base image.
  local elapsed=0 max=300
  while (( elapsed < max )); do
    cur=$(vc_api GET "${VCSA_IP}" "$tok" "/api/esx/settings/clusters/${moid}/software" \
      | jq -r '.base_image.version // empty')
    [[ "$cur" == "$want" ]] && break
    sleep 10; (( elapsed += 10 )) || true
    log "  waiting for desired image to commit (${elapsed}/${max}s) ..."
  done
  [[ "$cur" == "$want" ]] || die "Cluster desired image did not converge to '${want}'"
  ok "Cluster desired image set to '${want}' (matches nested hosts; Supervisor-ready)."
}

# 4. Create the VDS + one portgroup per Stage 1 VLAN + two ephemeral trunk
#    uplinks for the Supervisor edge/FLB.
_create_vds_and_portgroups() {
  local dvs_path="/${CLUSTER_DC}/network/${VDS_NAME}"
  if govc_object_exists "$dvs_path"; then
    ok "VDS '${VDS_NAME}' already exists."
  else
    log "Creating VDS '${VDS_NAME}' (product ${VDS_VERSION}, MTU 9000) ..."
    govc dvs.create -k -dc "${CLUSTER_DC}" \
      -product-version "${VDS_VERSION}" -mtu 9000 "${VDS_NAME}" \
      || die "dvs.create failed for ${VDS_NAME}"
  fi

  local n_vlans i native_vlan
  n_vlans=$(cfg_len '.network.vlans')
  native_vlan=$(cfg '.network.native_vlan' '100')
  for ((i=0; i<n_vlans; i++)); do
    local vid vname pg_name pg_vlan
    vid=$(cfg ".network.vlans[$i].id")
    vname=$(cfg ".network.vlans[$i].name")
    pg_name="${VDS_NAME}-${vname}"
    # The native VLAN is UNTAGGED on the physical fabric (the jumpbox carries it
    # as its native/untagged VLAN), so its portgroup must be VLAN 0 — tagging it
    # would break L2 to the jumpbox (e.g. Supervisor mgmt VMs couldn't reach DNS).
    pg_vlan="$vid"; [[ "$vid" == "$native_vlan" ]] && pg_vlan=0
    if govc_object_exists "/${CLUSTER_DC}/network/${pg_name}"; then
      ok "Portgroup '${pg_name}' already exists."
      continue
    fi
    log "Creating portgroup '${pg_name}' (VLAN ${pg_vlan}$([[ "$pg_vlan" == 0 ]] && echo ' = untagged/native')) ..."
    govc dvs.portgroup.add -k -dc "${CLUSTER_DC}" -dvs "${VDS_NAME}" \
      -type earlyBinding -nports 128 -vlan "${pg_vlan}" "${pg_name}" \
      || die "dvs.portgroup.add failed for ${pg_name}"
  done

  # Ephemeral trunk uplinks used by the Supervisor edge / Foundation LB.
  local up
  for up in edge-uplink-1 edge-uplink-2; do
    if govc_object_exists "/${CLUSTER_DC}/network/${up}"; then
      ok "Trunk uplink '${up}' already exists."
      continue
    fi
    log "Creating trunk uplink '${up}' (VLAN 0-4094) ..."
    govc dvs.portgroup.add -k -dc "${CLUSTER_DC}" -dvs "${VDS_NAME}" \
      -type ephemeral -vlan-mode=trunking -vlan-range=0-4094 "${up}" \
      || die "dvs.portgroup.add failed for ${up}"
  done
}

# 5. Add each host to the VDS uplink and enable vSAN + vMotion on vmk0.
_add_hosts_to_vds() {
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" i
  for ((i=0; i<N_NESXI; i++)); do
    # NB: separate declarations — a var cannot be referenced in the same `local`
    # statement that first assigns it (all RHS are expanded before assignment;
    # under `set -u` that is an unbound-variable error).
    local fqdn="${NESXI_FQDN[$i]}"
    local host_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}/${fqdn}"

    log "Adding host '${fqdn}' to VDS '${VDS_NAME}' (pnic ${VDS_UPLINK_PNIC}) ..."
    # dvs.add is idempotent on re-add; tolerate the "already added" error.
    govc dvs.add -k -dc "${CLUSTER_DC}" -dvs "${VDS_NAME}" \
      -pnic "${VDS_UPLINK_PNIC}" "${host_path}" 2>/dev/null \
      && ok "Host '${fqdn}' added to VDS." \
      || warn "dvs.add for '${fqdn}' reported an error (may already be added)."

    log "Enabling vSAN + vMotion services on ${fqdn} vmk0 ..."
    # Non-fatal (may already be enabled on a re-run) but no longer silent: a
    # real failure here leaves vSAN/vMotion traffic untagged on vmk0, which
    # otherwise only surfaces later as an obscure vSAN network health issue.
    govc host.vnic.service -k -host "${fqdn}" -enable vsan    vmk0 2>/dev/null \
      || warn "Could not confirm 'vsan' service enabled on ${fqdn} vmk0 (may already be enabled)."
    govc host.vnic.service -k -host "${fqdn}" -enable vmotion vmk0 2>/dev/null \
      || warn "Could not confirm 'vmotion' service enabled on ${fqdn} vmk0 (may already be enabled)."

    log "Setting NTP on ${fqdn} ..."
    govc host.esxcli -k -host "${fqdn}" system ntp set -e true -s "${NTP_SERVER}" 2>/dev/null || true

    # Nested-vSAN tweaks (validated scratch/create-esxi.sh): fake SCSI
    # reservations (required nested), disable device monitoring (avoids false
    # disk/HW-health alarms), thin swap, suppress coredump warning.
    local o
    for o in "/VSAN/FakeSCSIReservations 1" "/LSOM/VSANDeviceMonitoring 0" \
             "/VSAN/SwapThickProvisionDisabled 1" "/UserVars/SuppressCoredumpWarning 1"; do
      govc host.esxcli -k -host "${fqdn}" system settings advanced set \
        -o "${o% *}" -i "${o#* }" 2>/dev/null || true
    done

    # Only exit maintenance mode if the host is actually in it — a freshly added
    # host is connected (not in maintenance), and host.maintenance.exit then
    # errors "operation not allowed in current state".
    if [[ "$(govc object.collect -k -s "${host_path}" runtime.inMaintenanceMode 2>/dev/null || echo false)" == "true" ]]; then
      log "Exiting maintenance mode on ${fqdn} ..."
      govc host.maintenance.exit -k "${fqdn}" >/dev/null 2>&1 || warn "Could not exit maintenance mode on ${fqdn}."
    fi
  done
}

# 6. Enable vSAN (OSA) + HA. Idempotent: skip once the datastore exists.
_configure_vsan() {
  if govc_object_exists "/${CLUSTER_DC}/datastore/${VSAN_DS}"; then
    ok "vSAN datastore '${VSAN_DS}' already present (OSA); skipping enable."
    return
  fi
  log "Configuring vSAN (OSA) on '${CLUSTER_NAME}' ..."
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" tok moid t i
  tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}") \
    || die "Could not create vCenter session"
  moid=$(vc_api GET "${VCSA_IP}" "$tok" "/api/vcenter/cluster" \
    | jq -r --arg n "${CLUSTER_NAME}" '.[] | select(.name == $n) | .cluster' | head -1)
  [[ -n "$moid" ]] || die "Could not resolve cluster MOID for '${CLUSTER_NAME}'"

  # OSA: enable vSAN on the cluster (govc), then build a cache+capacity disk
  # group per host. Ported from the validated scratch/create-cluster.sh.osa.
  log "Enabling vSAN on cluster (OSA) ..."
  govc cluster.change -k -vsan-enabled "$cluster_path" \
    || die "cluster.change -vsan-enabled failed"
  for ((i=0; i<N_NESXI; i++)); do
    _build_osa_disk_group "${NESXI_FQDN[$i]}"
  done
  ok "vSAN (OSA) enabled on '${CLUSTER_NAME}'."

  # Enable HA with das.ignoreRedundantNetWarning=true so the "host has no
  # management network redundancy" config issue is suppressed (nested hosts have
  # a single mgmt uplink). vim25 REST — govc cluster.change -ha-enabled cannot
  # set the das advanced option.
  log "Enabling HA (mgmt-network-redundancy warning suppressed) ..."
  t=$(vc_reconfigure_cluster "${VCSA_IP}" "$tok" "$moid" "$(_render_ha_spec)")
  [[ -n "$t" ]] && wait_for_task "${VCSA_IP}" "$tok" "$t" || die "HA enable task not created"

  _wait_for_vsan_datastore
}

# _build_osa_disk_group <host-fqdn>
# Identify the cache (ESXI_CACHE_GB) and capacity (ESXI_CAP_GB) disks by size,
# tag the capacity disk capacityFlash (all-flash OSA), and create the disk group.
# Idempotent: skip if the host already has a vSAN disk group.
_build_osa_disk_group() {
  local fqdn="$1"
  if govc host.esxcli -k -host "$fqdn" vsan storage list 2>/dev/null | grep -q .; then
    ok "Host '${fqdn}' already has a vSAN disk group."
    return
  fi
  govc host.storage.info -k -host "$fqdn" -refresh=true -rescan=true -rescan-vmfs=true \
    >/dev/null 2>&1 || true

  local cachedisk="" datadisk="" dev size
  # host.storage.info text: column 1 = device path, column 3 = size in GB.
  while read -r dev size; do
    case "$size" in
      "$ESXI_CACHE_GB") cachedisk="${dev##*/}" ;;
      "$ESXI_CAP_GB")   datadisk="${dev##*/}"  ;;
    esac
  done < <(govc host.storage.info -k -host "$fqdn" | grep disk | awk '{printf "%s %d\n", $1, $3}')

  [[ -n "$cachedisk" && -n "$datadisk" ]] \
    || die "Could not identify OSA cache(${ESXI_CACHE_GB}G)/capacity(${ESXI_CAP_GB}G) disks on ${fqdn}"
  log "OSA disk group on ${fqdn}: cache=${cachedisk} capacity=${datadisk}"

  # Nested re-run safety: the target disks may still carry a vSAN claim from a
  # prior deployment ("Unable to add device: ... In use by vSAN"). Release any
  # stale disk group / claim first -- removing by the cache SSD tears down the
  # whole group, then drop any lingering capacity-disk claim. Both are no-ops on
  # freshly deployed blank disks.
  govc host.esxcli -k -host "$fqdn" vsan storage remove -s "$cachedisk" 2>/dev/null || true
  govc host.esxcli -k -host "$fqdn" vsan storage remove -d "$datadisk"  2>/dev/null || true

  govc host.esxcli -k -host "$fqdn" vsan storage tag add -d "$datadisk" -t capacityFlash \
    2>/dev/null || true
  if ! govc host.esxcli -k -host "$fqdn" vsan storage add -s "$cachedisk" -d "$datadisk"; then
    warn "vsan storage add failed on ${fqdn}; current vSAN storage state:"
    govc host.esxcli -k -host "$fqdn" vsan storage list 2>&1 | sed 's/^/    /' || true
    die "esxcli vsan storage add failed on ${fqdn}. If a disk is still 'in use by vSAN' from a prior deployment, its on-disk vSAN partitions persist -- wipe/redeploy the nested ESXi (rollback esxi + re-run), or clear the disks with partedUtil, then re-run."
  fi
  ok "vSAN OSA disk group created on ${fqdn}."
}

_wait_for_vsan_datastore() {
  log "Waiting for vSAN datastore '${VSAN_DS}' to appear (up to 10 min) ..."
  local elapsed=0 max=600
  while (( elapsed < max )); do
    govc_object_exists "/${CLUSTER_DC}/datastore/${VSAN_DS}" && break
    sleep 20; (( elapsed += 20 )) || true
    log "  vSAN datastore not yet visible (${elapsed}/${max}s) ..."
  done
  govc_object_exists "/${CLUSTER_DC}/datastore/${VSAN_DS}" \
    || die "Timed out waiting for vSAN datastore '${VSAN_DS}'"
  ok "vSAN datastore '${VSAN_DS}' is visible."
}

# 7. WCP storage tag + policy (idempotent create-if-absent). Mode-independent.
_create_storage_policy() {
  local cat="${STORAGE_POLICY}-cat" tag="${STORAGE_POLICY}-tag"
  govc tags.category.info -k "$cat" >/dev/null 2>&1 \
    || govc tags.category.create -k -d "WCP storage" -t Datastore "$cat" \
    || die "tags.category.create failed"
  govc tags.info -k -c "$cat" "$tag" >/dev/null 2>&1 \
    || govc tags.create -k -d "WCP storage" -c "$cat" "$tag" \
    || die "tags.create failed"
  govc tags.attach -k -c "$cat" "$tag" "/${CLUSTER_DC}/datastore/${VSAN_DS}" 2>/dev/null || true
  if govc storage.policy.info -k "${STORAGE_POLICY}" >/dev/null 2>&1; then
    ok "Storage policy '${STORAGE_POLICY}' already exists."
  else
    log "Creating storage policy '${STORAGE_POLICY}' ..."
    govc storage.policy.create -k -category "$cat" -tag "$tag" "${STORAGE_POLICY}" \
      || die "storage.policy.create failed"
  fi
  ok "Storage tag + policy ready for Supervisor."
}
