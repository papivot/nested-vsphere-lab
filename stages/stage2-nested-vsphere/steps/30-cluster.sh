#!/usr/bin/env bash
# ============================================================================
# cluster :: Build the nested vSphere cluster inside the newly deployed vCenter.
#   1. Create datacenter + cluster (+ DRS)
#   2. Seed the vCenter vLCM depot with the nested ESXi image ("host seed"): add
#      the first host standalone, extract its running image into the depot, then
#      remove it. A fresh vCenter only ships older bundled base images, so
#      without this the 9.x nested build is absent from the depot and neither
#      the cluster image nor Supervisor can be made compliant.
#   3. Add nested ESXi hosts to the cluster
#   4. Align the cluster's vLCM desired image to the ESXi build the hosts run.
#      A fresh 9.x cluster is auto-managed with a single image from the
#      vCenter's *bundled* base (an older 8.0U3), which does NOT match the
#      nested hosts -- and Supervisor refuses to install the Spherelet on an
#      image-noncompliant cluster. We create a draft, set base_image.version to
#      the build the hosts run (now in the depot from step 2), and commit. The
#      hosts are then already compliant, so no remediation/reboot is triggered.
#   5. Create VDS + portgroups (one per Stage 1 VLAN + edge trunk uplinks)
#   6. Add hosts to the VDS; enable vSAN + vMotion vmk services; exit maint.
#   7. Enable vSAN (OSA or ESA) + HA:
#        - OSA (default; lighter, best for nested): govc cluster.change
#          -vsan-enabled -ha-enabled + per-host disk group via
#          `esxcli vsan storage add` (ported from scratch/create-cluster.sh.osa).
#        - ESA: vim25 SOAP-REST ReconfigureComputeResource_Task with
#          vsanEsaEnabled (from scratch/create-cluster.sh) + autoclaim.
#   8. Create the WCP storage tag + policy (mode-independent).
# ============================================================================

# ---- pure render fns: vim25 ClusterConfigSpecEx bodies (bats-testable) -----

# vLCM draft BaseImageSpec: the desired ESXi base-image version for the cluster.
_render_base_image_spec() {
  jq -n --arg v "$1" '{ "version": $v }'
}

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
  _seed_depot_from_host
  _add_hosts_to_cluster
  _align_cluster_image
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

# _depot_version_for_build <token> <build>
# Print the vLCM depot base-image version whose build matches <build> (depot
# version strings look like "9.1.0.0.25370933" -- end with ".<build>"). Empty
# if the depot has no matching base image. Soft (never dies) so callers can use
# it both as a gate and as a poll predicate.
_depot_version_for_build() {
  curl -sk -H "vmware-api-session-id: ${1}" \
    "https://${VCSA_IP}/api/esx/settings/depot-content/base-images" 2>/dev/null \
    | jq -r --arg b ".${2}" \
        '[.[] | select(.version | endswith($b))] | first | .version // empty' \
        2>/dev/null || true
}

# 2. Seed the vCenter vLCM depot with the image the nested hosts run ("host
#    seed"). A fresh vCenter ships only older bundled base images, so the 9.x
#    nested build is absent from the depot -- and neither the cluster image nor
#    Supervisor can be made compliant without it. The offline fix: add the first
#    ESXi as a STANDALONE host, enable host-level image management (which runs
#    the host-seed extraction, importing its running image into the depot), then
#    remove it. The remaining hosts join the cluster normally; depot content
#    persists independent of the host.
#
#    Requires the nested ESXi to have a persistent ESX-OSData volume (the OVA's
#    boot disk provides it); otherwise extraction fails with "No OSData storage
#    partition is available to extract image".
#
#    Idempotent: if the depot already has a base image matching the host build
#    (a re-run, or an already-seeded vCenter), the whole step is a no-op.
_seed_depot_from_host() {
  local seed_fqdn="${NESXI_FQDN[0]}"
  local tok
  tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}") \
    || die "Could not create vCenter session"

  # Add the seed host standalone (idempotent) so we can read its build + extract.
  if govc find -k "/${CLUSTER_DC}/host" -type h -name "${seed_fqdn}" 2>/dev/null | grep -q .; then
    ok "Seed host '${seed_fqdn}' already present in inventory."
  else
    log "Adding '${seed_fqdn}' as a standalone host (for image extraction) ..."
    govc host.add -k -hostname "${seed_fqdn}" -username root \
      -password "${ESXI_ROOT_PASSWORD}" -noverify -force \
      || die "Could not add standalone seed host ${seed_fqdn}"
  fi

  local host_path
  host_path=$(govc find -k "/${CLUSTER_DC}/host" -type h -name "${seed_fqdn}" 2>/dev/null | head -1)
  [[ -n "$host_path" ]] || die "Seed host ${seed_fqdn} not found in inventory after add"

  local build
  build=$(govc object.collect -k -s "${host_path}" config.product.build 2>/dev/null || true)
  [[ -n "$build" ]] || die "Could not read ESXi build from seed host ${seed_fqdn}"

  # Already seeded? Then remove the standalone host and return (idempotent).
  if [[ -n "$(_depot_version_for_build "$tok" "$build")" ]]; then
    ok "Depot already has a base image for build ${build}; skipping extraction."
    _remove_standalone_host "$host_path" "$seed_fqdn"
    return
  fi

  # Host MOID (e.g. host-16) for the esx/settings API.
  local moid
  moid=$(govc find -k -i "/${CLUSTER_DC}/host" -type h -name "${seed_fqdn}" 2>/dev/null | head -1)
  moid="${moid##*:}"
  [[ -n "$moid" ]] || die "Could not resolve MOID for seed host ${seed_fqdn}"

  log "Extracting the running image from ${seed_fqdn} into the vCenter depot (host seed) ..."
  # Enable host-level image management by committing a draft of the host's
  # current software. Committing triggers the host-seed extraction, which
  # imports the host's base image + components into the vCenter depot. Errors
  # here are non-fatal: the true success criterion is depot state (polled below),
  # so a slightly different trigger on some builds still self-corrects.
  local base="https://${VCSA_IP}/api/esx/settings/hosts/${moid}/software/drafts"
  local draft
  draft=$(curl -sk -X POST -H "vmware-api-session-id: ${tok}" \
    -H "Content-Type: application/json" "$base" 2>/dev/null | tr -d '"')
  if [[ -n "$draft" && "${draft:0:1}" != "{" ]]; then
    curl -sk -X POST -H "vmware-api-session-id: ${tok}" \
      -H "Content-Type: application/json" \
      "${base}/${draft}?action=commit" >/dev/null 2>&1 || true
  else
    warn "Could not open a host software draft on ${seed_fqdn} (got: ${draft:-<none>}); relying on the depot poll."
  fi

  # Poll the depot -- extraction is asynchronous. This is the real gate.
  local elapsed=0 max=600
  while (( elapsed < max )); do
    [[ -n "$(_depot_version_for_build "$tok" "$build")" ]] && break
    sleep 15; (( elapsed += 15 )) || true
    log "  waiting for the host image to extract into the depot (${elapsed}/${max}s) ..."
  done
  if [[ -z "$(_depot_version_for_build "$tok" "$build")" ]]; then
    die "The vCenter depot never received a base image for build ${build}.
  Automated host-seed extraction did not populate the depot. Seed it once by hand:
    vCenter UI -> add host '${seed_fqdn}' as a standalone host ->
    'Extract the image on the host' -> finish. Then re-run:
      sudo ./run.sh --stage 2 --from-step cluster
  Also confirm the nested ESXi has a persistent ESX-OSData volume (see the OVA
  boot disk sizing)."
  fi
  ok "Depot seeded with the nested ESXi image (build ${build})."

  _remove_standalone_host "$host_path" "$seed_fqdn"
}

# _remove_standalone_host <host-path> <fqdn>
# Remove the standalone seed host so _add_hosts_to_cluster can add it to the
# cluster cleanly. The extracted depot content persists. Idempotent, and a
# no-op if the host has already been placed inside the cluster.
_remove_standalone_host() {
  local host_path="$1" fqdn="$2"
  case "$host_path" in
    "/${CLUSTER_DC}/host/${CLUSTER_NAME}/"*) return 0 ;;   # already inside the cluster
  esac
  log "Removing standalone seed host '${fqdn}' (depot content persists) ..."
  govc host.remove -k "${host_path}" 2>/dev/null \
    || warn "Could not remove standalone host ${fqdn}; remove it manually if the cluster add fails."
}

# 3. Add nested ESXi hosts to the cluster (by FQDN; thumbprint fetched explicitly).
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

# 4. Align the cluster's vLCM desired image with the build the hosts run.
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
  want=$(_depot_version_for_build "$tok" "$build")
  [[ -n "$want" ]] \
    || die "No vCenter depot base image matches ESXi build ${build}. Seed the depot first (the 'seed depot from host' step should have handled this)."

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

  vc_api POST "${VCSA_IP}" "$tok" \
    "/api/esx/settings/clusters/${moid}/software/drafts/${draft}?action=commit" >/dev/null \
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

# 5. Create the VDS + one portgroup per Stage 1 VLAN + two ephemeral trunk
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

# 6. Add each host to the VDS uplink and enable vSAN + vMotion on vmk0.
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
    govc host.vnic.service -k -host "${fqdn}" -enable vsan    vmk0 2>/dev/null || true
    govc host.vnic.service -k -host "${fqdn}" -enable vmotion vmk0 2>/dev/null || true

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

# 7. Enable vSAN (OSA or ESA) + HA. Idempotent: skip once the datastore exists.
_configure_vsan() {
  if govc_object_exists "/${CLUSTER_DC}/datastore/${VSAN_DS}"; then
    ok "vSAN datastore '${VSAN_DS}' already present (mode=${VSAN_MODE}); skipping enable."
    return
  fi
  log "Configuring vSAN (${VSAN_MODE}) on '${CLUSTER_NAME}' ..."
  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}" tok moid t
  tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}") \
    || die "Could not create vCenter session"
  moid=$(vc_api GET "${VCSA_IP}" "$tok" "/api/vcenter/cluster" \
    | jq -r --arg n "${CLUSTER_NAME}" '.[] | select(.name == $n) | .cluster' | head -1)
  [[ -n "$moid" ]] || die "Could not resolve cluster MOID for '${CLUSTER_NAME}'"

  case "$VSAN_MODE" in
    osa) _vsan_osa "$cluster_path" ;;
    esa) _vsan_esa "$cluster_path" "$tok" "$moid" ;;
    *)   die "stage2.cluster.vsan.mode must be 'osa' or 'esa' (got '${VSAN_MODE}')" ;;
  esac

  # Enable HA for BOTH modes with das.ignoreRedundantNetWarning=true so the
  # "host has no management network redundancy" config issue is suppressed
  # (nested hosts have a single mgmt uplink). vim25 REST — govc cluster.change
  # -ha-enabled cannot set the das advanced option.
  log "Enabling HA (mgmt-network-redundancy warning suppressed) ..."
  t=$(vc_reconfigure_cluster "${VCSA_IP}" "$tok" "$moid" "$(_render_ha_spec)")
  [[ -n "$t" ]] && wait_for_task "${VCSA_IP}" "$tok" "$t" || die "HA enable task not created"

  _wait_for_vsan_datastore
}

# --- OSA: enable vSAN via govc, then build a disk group per host.
#     Ported from the validated scratch/create-cluster.sh.osa (govc + esxcli;
#     no vim25 REST). Disks are matched by size (cache vs capacity). ---
_vsan_osa() {
  local cluster_path="$1" i
  log "Enabling vSAN on cluster (OSA) ..."
  govc cluster.change -k -vsan-enabled "$cluster_path" \
    || die "cluster.change -vsan-enabled failed"
  for ((i=0; i<N_NESXI; i++)); do
    _build_osa_disk_group "${NESXI_FQDN[$i]}"
  done
  ok "vSAN (OSA) enabled on '${CLUSTER_NAME}'."
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

# --- ESA: enable vSAN + vSAN ESA via vim25 REST (validated
#     scratch/create-cluster.sh), then autoclaim eligible disks. HA is enabled
#     by the caller (shared with OSA). ---
_vsan_esa() {
  local cluster_path="$1" tok="$2" moid="$3" t i

  log "Enabling vSAN on cluster (MOID ${moid}) ..."
  t=$(vc_reconfigure_cluster "${VCSA_IP}" "$tok" "$moid" "$(_render_vsan_spec)")
  [[ -n "$t" ]] && wait_for_task "${VCSA_IP}" "$tok" "$t" || die "vSAN enable task not created"

  log "Enabling vSAN ESA on cluster ..."
  t=$(vc_reconfigure_cluster "${VCSA_IP}" "$tok" "$moid" "$(_render_vsan_esa_spec)")
  [[ -n "$t" ]] && wait_for_task "${VCSA_IP}" "$tok" "$t" || die "vSAN ESA enable task not created"

  for ((i=0; i<N_NESXI; i++)); do
    govc host.storage.info -k -host "${NESXI_FQDN[$i]}" -rescan >/dev/null 2>&1 || true
  done
  govc cluster.change -k -vsan-autoclaim "$cluster_path" 2>/dev/null || true
  ok "vSAN (ESA) enabled on '${CLUSTER_NAME}'."
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

# 8. WCP storage tag + policy (idempotent create-if-absent). Mode-independent.
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
