#!/usr/bin/env bash
# ============================================================================
# cluster :: Build the nested vSphere cluster inside the newly deployed vCenter.
#   1. Create datacenter + cluster (+ DRS)
#   2. Add nested ESXi hosts to the cluster
#   3. Create VDS + portgroups (one per Stage 1 VLAN + edge trunk uplinks)
#   4. Add hosts to the VDS; enable vSAN + vMotion vmk services; exit maint.
#   5. Enable vSAN (OSA or ESA) + HA:
#        - OSA (default; lighter, best for nested): govc cluster.change
#          -vsan-enabled -ha-enabled + per-host disk group via
#          `esxcli vsan storage add` (ported from scratch/create-cluster.sh.osa).
#        - ESA: vim25 SOAP-REST ReconfigureComputeResource_Task with
#          vsanEsaEnabled (from scratch/create-cluster.sh) + autoclaim.
#   6. Create the WCP storage tag + policy (mode-independent).
# ============================================================================

# ---- pure render fns: vim25 ClusterConfigSpecEx bodies (bats-testable) -----

_render_vsan_spec() {
  jq -n '{
    "_typeName": "ClusterConfigSpecEx",
    "vsanConfig": { "_typeName": "VsanClusterConfigInfo", "enabled": true }
  }'
}

_render_vsan_esa_spec() {
  jq -n '{
    "_typeName": "ClusterConfigSpecEx",
    "vsanConfig": {
      "_typeName": "VsanClusterConfigInfo",
      "enabled": true,
      "vsanEsaEnabled": true
    }
  }'
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
  _create_vds_and_portgroups
  _add_hosts_to_vds
  _configure_vsan
  _create_storage_policy

  ok "Nested cluster '${CLUSTER_DC}/${CLUSTER_NAME}' (vSAN ${VSAN_MODE}) is configured."
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

# 2. Add nested ESXi hosts to the cluster (by FQDN; thumbprint fetched explicitly).
_add_hosts_to_cluster() {
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" i
  for ((i=0; i<N_NESXI; i++)); do
    local fqdn="${NESXI_FQDN[$i]}" ip="${NESXI_IP[$i]}"
    if govc find "${cluster_path}" -type h -name "${fqdn}" 2>/dev/null | grep -q .; then
      ok "Host '${fqdn}' already in cluster."
      continue
    fi
    log "Fetching thumbprint for nested ESXi ${ip} ..."
    local thumb; thumb=$(govc_host_thumbprint "$ip") \
      || die "Could not fetch thumbprint for ${ip}"
    log "Adding host '${fqdn}' to cluster ..."
    govc cluster.add -k \
      -cluster    "${cluster_path}" \
      -hostname   "${fqdn}" \
      -username   "root" \
      -password   "${ESXI_ROOT_PASSWORD}" \
      -thumbprint "${thumb}" \
      || die "cluster.add failed for ${fqdn}"
    ok "Host '${fqdn}' added to cluster."
  done
}

# 3. Create the VDS + one portgroup per Stage 1 VLAN + two ephemeral trunk
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

  local n_vlans i; n_vlans=$(cfg_len '.network.vlans')
  for ((i=0; i<n_vlans; i++)); do
    local vid vname pg_name
    vid=$(cfg ".network.vlans[$i].id")
    vname=$(cfg ".network.vlans[$i].name")
    pg_name="${VDS_NAME}-${vname}"
    if govc_object_exists "/${CLUSTER_DC}/network/${pg_name}"; then
      ok "Portgroup '${pg_name}' already exists."
      continue
    fi
    log "Creating portgroup '${pg_name}' (VLAN ${vid}) ..."
    govc dvs.portgroup.add -k -dc "${CLUSTER_DC}" -dvs "${VDS_NAME}" \
      -type earlyBinding -nports 128 -vlan "${vid}" "${pg_name}" \
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

# 4. Add each host to the VDS uplink and enable vSAN + vMotion on vmk0.
_add_hosts_to_vds() {
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" i
  for ((i=0; i<N_NESXI; i++)); do
    local fqdn="${NESXI_FQDN[$i]}" host_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}/${fqdn}"

    log "Adding host '${fqdn}' to VDS '${VDS_NAME}' (pnic ${VDS_UPLINK_PNIC}) ..."
    # dvs.add is idempotent on re-add; tolerate the "already added" error.
    govc dvs.add -k -dc "${CLUSTER_DC}" -dvs "${VDS_NAME}" \
      -pnic "${VDS_UPLINK_PNIC}" "${host_path}" 2>/dev/null \
      && ok "Host '${fqdn}' added to VDS." \
      || warn "dvs.add for '${fqdn}' reported an error (may already be added)."

    log "Enabling vSAN + vMotion services on ${fqdn} vmk0 ..."
    govc host.vnic.service -k -host "${fqdn}" -enable vsan    vmk0 2>/dev/null || true
    govc host.vnic.service -k -host "${fqdn}" -enable vmotion vmk0 2>/dev/null || true

    log "Setting NTP + exiting maintenance mode on ${fqdn} ..."
    govc host.esxcli -k -host "${fqdn}" system ntp set -e true -s "${NTP_SERVER}" 2>/dev/null || true
    govc host.maintenance.exit -k "${fqdn}" 2>/dev/null || true
  done
}

# 5. Enable vSAN (OSA or ESA) + HA. Idempotent: skip once the datastore exists.
_configure_vsan() {
  if govc_object_exists "/${CLUSTER_DC}/datastore/${VSAN_DS}"; then
    ok "vSAN datastore '${VSAN_DS}' already present (mode=${VSAN_MODE}); skipping enable."
    return
  fi
  log "Configuring vSAN (${VSAN_MODE}) on '${CLUSTER_NAME}' ..."
  case "$VSAN_MODE" in
    osa) _vsan_osa ;;
    esa) _vsan_esa ;;
    *)   die "stage2.cluster.vsan.mode must be 'osa' or 'esa' (got '${VSAN_MODE}')" ;;
  esac
  _wait_for_vsan_datastore
}

# --- OSA: enable vSAN + HA via govc, then build a disk group per host.
#     Ported from the validated scratch/create-cluster.sh.osa (govc + esxcli;
#     no vim25 REST). Disks are matched by size (cache vs capacity). ---
_vsan_osa() {
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" i
  log "Enabling vSAN + HA on cluster (OSA) ..."
  govc cluster.change -k -vsan-enabled -ha-enabled "$cluster_path" \
    || die "cluster.change -vsan-enabled -ha-enabled failed"
  for ((i=0; i<N_NESXI; i++)); do
    _build_osa_disk_group "${NESXI_FQDN[$i]}"
  done
  ok "vSAN (OSA) + HA enabled on '${CLUSTER_NAME}'."
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

  govc host.esxcli -k -host "$fqdn" vsan storage tag add -d "$datadisk" -t capacityFlash \
    2>/dev/null || true
  govc host.esxcli -k -host "$fqdn" vsan storage add -s "$cachedisk" -d "$datadisk" \
    || die "esxcli vsan storage add failed on ${fqdn}"
  ok "vSAN OSA disk group created on ${fqdn}."
}

# --- ESA: enable vSAN + HA + vSAN ESA via vim25 REST (validated
#     scratch/create-cluster.sh), then autoclaim eligible disks. ---
_vsan_esa() {
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" tok moid t i

  tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}") \
    || die "Could not create vCenter session"
  # Cluster MOID (e.g. domain-c8) — the string the vim25 task path needs.
  moid=$(vc_api GET "${VCSA_IP}" "$tok" "/api/vcenter/cluster" \
    | jq -r --arg n "${CLUSTER_NAME}" '.[] | select(.name == $n) | .cluster' | head -1)
  [[ -n "$moid" ]] || die "Could not resolve cluster MOID for '${CLUSTER_NAME}'"

  log "Enabling vSAN on cluster (MOID ${moid}) ..."
  t=$(vc_reconfigure_cluster "${VCSA_IP}" "$tok" "$moid" "$(_render_vsan_spec)")
  [[ -n "$t" ]] && wait_for_task "${VCSA_IP}" "$tok" "$t" || die "vSAN enable task not created"

  log "Enabling HA on cluster ..."
  t=$(vc_reconfigure_cluster "${VCSA_IP}" "$tok" "$moid" "$(_render_ha_spec)")
  [[ -n "$t" ]] && wait_for_task "${VCSA_IP}" "$tok" "$t" || die "HA enable task not created"

  log "Enabling vSAN ESA on cluster ..."
  t=$(vc_reconfigure_cluster "${VCSA_IP}" "$tok" "$moid" "$(_render_vsan_esa_spec)")
  [[ -n "$t" ]] && wait_for_task "${VCSA_IP}" "$tok" "$t" || die "vSAN ESA enable task not created"

  for ((i=0; i<N_NESXI; i++)); do
    govc host.storage.info -k -host "${NESXI_FQDN[$i]}" -rescan >/dev/null 2>&1 || true
  done
  govc cluster.change -k -vsan-autoclaim "$cluster_path" 2>/dev/null || true
  ok "vSAN (ESA) + HA enabled on '${CLUSTER_NAME}'."
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

# 6. WCP storage tag + policy (idempotent create-if-absent). Mode-independent.
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
