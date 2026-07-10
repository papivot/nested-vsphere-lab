#!/usr/bin/env bash
# ============================================================================
# stage2-nested-vsphere/stage.sh - ordered step pipeline + derived facts.
# Sourced by run.sh after lib/* are loaded. Mirrors stage1-jumpbox/stage.sh.
# ============================================================================

STAGE2_DIR="${STAGE_DIR}"   # stages/stage2-nested-vsphere

# Ordered steps. preflight is always a hard gate.
STEPS=(preflight esxi vcenter cluster supervisor labinfo)

# ---- shared state paths ----
LAB_STATE_DIR=/etc/nested-lab
LAB2_INFO_FILE=/etc/nested-lab/lab2-info.txt

# Per-nested-ESXi arrays (populated by compute_derived from dns.records).
declare -a NESXI_NAME NESXI_IP NESXI_FQDN
# ESA data-disk sizes (GiB), one per disk beyond the boot disk.
declare -a ESXI_DATA_DISK_GB

# Uppercase a string (TINY/SMALL/... for the WCP API). bash 3.2 safe.
_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Number of usable addresses in a CIDR (2^(32-prefix)); used for the k8s
# service range in the WCP payload (expressed as address + count).
_cidr_count() { local p="${1##*/}"; printf '%d' "$(( 1 << (32 - p) ))"; }

compute_derived() {
  local i j n_rec n_vlans

  # ---- Stage 1 facts reused by Stage 2 ----
  DOMAIN=$(cfg '.jumpbox.domain'       'env1.lab.test')
  ARTIFACTS_DIR=$(cfg '.artifacts.dir' '/data/isos')
  CERTS_DIR=$(cfg '.certs.dir'         '/etc/nested-lab/ca')
  CA_BUNDLE="${CERTS_DIR}/ca-bundle.crt"
  REGISTRY_FQDN=$(cfg '.registry.fqdn' "$(cfg '.registry.name' 'registry').${DOMAIN}")
  # Native VLAN gateway (.1 of the first VLAN) == the jumpbox: DNS + NTP + NAT.
  NATIVE_GW=$(cidr_gateway "$(cfg '.network.vlans[0].cidr' '192.168.100.0/24')")
  NTP_SERVER=$(cfg '.ntp.upstream[0]' "$NATIVE_GW")

  n_rec=$(cfg_len '.dns.records')
  n_vlans=$(cfg_len '.network.vlans')

  # Echo the network.vlans[].cidr that contains an IP (empty if none).
  _vlan_cidr_for_ip() {
    local ip="$1" k c
    for ((k=0; k<n_vlans; k++)); do
      c=$(cfg ".network.vlans[$k].cidr")
      if ip_in_cidr "$ip" "$c"; then printf '%s' "$c"; return 0; fi
    done
    return 1
  }

  # ---- Stage 2 underlying target (standalone ESXi or an existing vCenter) ----
  UNDERLYING_TYPE=$(cfg '.stage2.underlying.type'          'esxi')
  UNDERLYING_HOST=$(cfg '.stage2.underlying.host'          '')
  UNDERLYING_DATASTORE=$(cfg '.stage2.underlying.datastore' '')
  UNDERLYING_PG=$(cfg '.stage2.underlying.portgroup_trunk'  'VM Network')
  UNDERLYING_USER=$(cfg '.stage2.underlying.username'       'root')
  # Only used when type=vcenter (placement for nested VMs + VCSA deploy target).
  UNDERLYING_DATACENTER=$(cfg '.stage2.underlying.datacenter' '')
  UNDERLYING_CLUSTER=$(cfg '.stage2.underlying.cluster'       '')
  [[ "$UNDERLYING_TYPE" == "esxi" || "$UNDERLYING_TYPE" == "vcenter" ]] \
    || die "stage2.underlying.type must be 'esxi' or 'vcenter' (got '${UNDERLYING_TYPE}')"
  if [[ "$UNDERLYING_TYPE" == "vcenter" ]]; then
    [[ -n "$UNDERLYING_DATACENTER" && -n "$UNDERLYING_CLUSTER" ]] \
      || die "stage2.underlying.datacenter and .cluster are required when type=vcenter"
  fi

  # ---- Stage 2 profile ----
  S2_PROFILE=$(cfg '.stage2.profile' 'vds_foundation_lb')

  # ---- Nested ESXi: derive list from dns.records matching dns_prefix ----
  ESXI_OVA="${ARTIFACTS_DIR}/$(cfg '.stage2.esxi.ova' 'nested-esxi9.ova')"
  ESXI_OVA_NETWORK=$(cfg '.stage2.esxi.ova_network' '')  # OVF network label; blank = auto-detect from the OVA
  ESXI_DNS_PREFIX=$(cfg '.stage2.esxi.dns_prefix' 'esxi')
  ESXI_CPU=$(cfg '.stage2.esxi.cpu'    '8')
  ESXI_MEM=$(cfg '.stage2.esxi.mem_gb' '48')

  # disk[0] = boot; every disk beyond that is a data disk. vSAN OSA needs exactly
  # one 'vsan_cache' + one 'vsan_capacity' disk of DISTINCT sizes (identified by
  # size at claim time).
  ESXI_DISK_BOOT=$(cfg '.stage2.esxi.disks[0].size_gb' '32')
  ESXI_DATA_DISK_GB=()
  ESXI_CACHE_GB=""; ESXI_CAP_GB=""
  local n_disks lbl sz; n_disks=$(cfg_len '.stage2.esxi.disks')
  for ((i=1; i<n_disks; i++)); do
    sz=$(cfg ".stage2.esxi.disks[$i].size_gb" '400')
    lbl=$(cfg ".stage2.esxi.disks[$i].label" 'vsan_capacity')
    ESXI_DATA_DISK_GB+=( "$sz" )
    case "$lbl" in
      *cache*) ESXI_CACHE_GB="$sz" ;;
      *cap*)   ESXI_CAP_GB="$sz" ;;
    esac
  done
  # Total per-host disk footprint (thin) for the preflight capacity estimate.
  ESXI_DISK_TOTAL_GB=$ESXI_DISK_BOOT
  for ((i=0; i<${#ESXI_DATA_DISK_GB[@]}; i++)); do
    ESXI_DISK_TOTAL_GB=$(( ESXI_DISK_TOTAL_GB + ESXI_DATA_DISK_GB[i] ))
  done

  local n_esxi=0 rname
  for ((i=0; i<n_rec; i++)); do
    rname=$(cfg ".dns.records[$i].name")
    if [[ "$rname" == "${ESXI_DNS_PREFIX}"* ]]; then
      NESXI_NAME[n_esxi]="$rname"
      NESXI_IP[n_esxi]=$(cfg ".dns.records[$i].ip")
      NESXI_FQDN[n_esxi]="${rname}.${DOMAIN}"
      (( n_esxi++ )) || true
    fi
  done
  N_NESXI=$n_esxi
  (( N_NESXI > 0 )) || die "No dns.records match esxi prefix '${ESXI_DNS_PREFIX}'"

  # Nested ESXi management network = the VLAN that owns the first ESXi IP
  # (NOT the Supervisor mgmt CIDR — decoupled so the two can differ).
  ESXI_MGMT_CIDR=$(_vlan_cidr_for_ip "${NESXI_IP[0]}") \
    || die "No network.vlans CIDR contains nested ESXi IP ${NESXI_IP[0]}"
  ESXI_NETMASK=$(cidr_netmask "$ESXI_MGMT_CIDR")
  ESXI_GW=$(cidr_gateway "$ESXI_MGMT_CIDR")

  # ---- Nested vCenter: derive from dns.records ----
  VCSA_ISO="${ARTIFACTS_DIR}/$(cfg '.stage2.vcsa.iso' 'VMware-VCSA-all.iso')"
  VCSA_DNS_NAME=$(cfg '.stage2.vcsa.dns_name' 'vcsa')
  VCSA_SSO_DOMAIN=$(cfg '.stage2.vcsa.sso_domain' 'vsphere.local')
  VCSA_SIZE=$(cfg '.stage2.vcsa.size' 'tiny')
  VCSA_ISO_MOUNT=$(cfg '.stage2.vcsa.iso_mount' '/mnt/vcsa-iso')
  # vcsa-deploy deploys at a fixed deployment_option size; we resize the VCSA VM
  # to these values afterward (hot-add if the appliance supports it, else a
  # power-cycle). Only ever increased — see steps/20-vcenter.sh.
  VCSA_CPU=$(cfg '.stage2.vcsa.cpu' '6')
  VCSA_MEM_GB=$(cfg '.stage2.vcsa.mem_gb' '26')

  VCSA_IP=""
  for ((i=0; i<n_rec; i++)); do
    if [[ "$(cfg ".dns.records[$i].name")" == "$VCSA_DNS_NAME" ]]; then
      VCSA_IP=$(cfg ".dns.records[$i].ip")
      break
    fi
  done
  [[ -n "$VCSA_IP" ]] || die "dns.records has no entry named '${VCSA_DNS_NAME}' (stage2.vcsa.dns_name)"
  VCSA_FQDN="${VCSA_DNS_NAME}.${DOMAIN}"
  VCSA_USER="administrator@${VCSA_SSO_DOMAIN}"
  # VCSA management network = the VLAN that owns the VCSA IP.
  local vcsa_cidr; vcsa_cidr=$(_vlan_cidr_for_ip "$VCSA_IP") \
    || die "No network.vlans CIDR contains VCSA IP ${VCSA_IP}"
  VCSA_PREFIX=$(cidr_prefix "$vcsa_cidr")
  VCSA_GW=$(cidr_gateway "$vcsa_cidr")

  # ---- Cluster ----
  CLUSTER_NAME=$(cfg '.stage2.cluster.name'       'nested-cluster')
  CLUSTER_DC=$(cfg '.stage2.cluster.datacenter'   'nested-dc')
  VDS_NAME=$(cfg '.stage2.cluster.vds_name'       'nested-vds')
  VDS_VERSION=$(cfg '.stage2.cluster.vds_version' '9.0.0')
  VDS_UPLINK_PNIC=$(cfg '.stage2.cluster.uplink_pnic' 'vmnic1')
  VSAN_FTT=$(cfg '.stage2.cluster.vsan.ftt'       '1')
  VSAN_DS=$(cfg '.stage2.cluster.vsan.datastore_name' 'vsanDatastore')
  # vSAN OSA disk group: one 'vsan_cache' + one 'vsan_capacity' disk of DISTINCT
  # sizes (matched by size at claim time). OSA is used deliberately — far
  # lighter on memory than ESA, which suits nested hosts.
  [[ -n "$ESXI_CACHE_GB" && -n "$ESXI_CAP_GB" ]] \
    || die "vSAN OSA needs disks labelled 'vsan_cache' and 'vsan_capacity' under stage2.esxi.disks"
  [[ "$ESXI_CACHE_GB" != "$ESXI_CAP_GB" \
     && "$ESXI_CACHE_GB" != "$ESXI_DISK_BOOT" \
     && "$ESXI_CAP_GB"   != "$ESXI_DISK_BOOT" ]] \
    || die "vSAN OSA needs boot/cache/capacity disks of DISTINCT sizes (boot=${ESXI_DISK_BOOT} cache=${ESXI_CACHE_GB} cap=${ESXI_CAP_GB}); they are matched by size at claim time"

  # ---- Supervisor: names, sizing, storage ----
  SUPERVISOR_NAME=$(cfg '.stage2.supervisor.name' 'supervisor')
  SUPER_CP_SIZE=$(cfg '.stage2.supervisor.control_plane_size' 'tiny')
  SUPERVISOR_SIZE=$(_upper "$SUPER_CP_SIZE")
  SUPERVISOR_VM_COUNT=$(cfg '.stage2.supervisor.control_plane_count' '1')
  CONTENT_LIB=$(cfg '.stage2.supervisor.content_library'   'vks-content-library')
  # Subscribed TKr library URL. Non-empty => SUBSCRIBED library; empty => LOCAL.
  CONTENT_LIB_URL=$(cfg '.stage2.supervisor.content_library_url' 'https://wp-content.broadcom.com/v2/latest/lib.json')
  CONTENT_LIB_ON_DEMAND=$(cfg_bool '.stage2.supervisor.content_library_on_demand' 'true')
  STORAGE_POLICY=$(cfg '.stage2.supervisor.storage_policy' 'vsan-default')
  VKS_STORAGE_POLICY="$STORAGE_POLICY"

  # ---- Supervisor networking: resolve mgmt + workload VLANs → CIDRs ----
  SUPER_MGMT_NET=$(cfg '.stage2.supervisor.mgmt_network' 'mgmt')
  SUPER_WKLD_NET=$(cfg '.stage2.supervisor.workload_network' 'workload0')
  SUPER_MGMT_VLAN_ID=""; SUPER_MGMT_CIDR=""
  SUPER_WKLD_VLAN_ID=""; SUPER_WKLD_CIDR=""
  for ((i=0; i<n_vlans; i++)); do
    local vn; vn=$(cfg ".network.vlans[$i].name")
    if [[ "$vn" == "$SUPER_MGMT_NET" ]]; then
      SUPER_MGMT_VLAN_ID=$(cfg ".network.vlans[$i].id")
      SUPER_MGMT_CIDR=$(cfg ".network.vlans[$i].cidr")
    fi
    if [[ "$vn" == "$SUPER_WKLD_NET" ]]; then
      SUPER_WKLD_VLAN_ID=$(cfg ".network.vlans[$i].id")
      SUPER_WKLD_CIDR=$(cfg ".network.vlans[$i].cidr")
    fi
  done
  [[ -n "$SUPER_MGMT_CIDR" ]] \
    || die "network.vlans has no entry named '${SUPER_MGMT_NET}' (stage2.supervisor.mgmt_network)"
  [[ -n "$SUPER_WKLD_CIDR" ]] \
    || die "network.vlans has no entry named '${SUPER_WKLD_NET}' (stage2.supervisor.workload_network)"

  # DVPG names created by the cluster step (VDS-<vlan name>); the supervisor
  # step resolves these to network MOIDs at apply time (VKS_MGMT_NETWORK1 /
  # VKS_WKLD_NETWORK are set there, since MOIDs need a live vCenter).
  MGMT_PG_NAME="${VDS_NAME}-${SUPER_MGMT_NET}"
  WKLD_PG_NAME="${VDS_NAME}-${SUPER_WKLD_NET}"

  # Gateways in CIDR form (WCP ip_management.gateway_address wants gw/prefix).
  MGMT_GATEWAY_CIDR="$(cidr_gateway "$SUPER_MGMT_CIDR")/$(cidr_prefix "$SUPER_MGMT_CIDR")"
  FLB_WORKLOAD_NW_GATEWAY_CIDR="$(cidr_gateway "$SUPER_WKLD_CIDR")/$(cidr_prefix "$SUPER_WKLD_CIDR")"
  DNS_SERVER="$NATIVE_GW"
  DNS_SEARCHDOMAIN="$DOMAIN"

  # k8s internal service range (address + count form).
  local svc_cidr; svc_cidr=$(cfg '.stage2.supervisor.service_cidr' '10.96.0.0/23')
  K8S_SERVICE_SUBNET="${svc_cidr%%/*}"
  K8S_SERVICE_SUBNET_COUNT=$(_cidr_count "$svc_cidr")

  # IP ranges (start + count) for the FLB / Supervisor networking. These cannot
  # be safely auto-derived (they must avoid the ESXi/VCSA static IPs and the
  # DHCP pool), so they are explicit in input.yaml.
  local rp='.stage2.supervisor.ranges'
  CP_MGMT_START=$(cfg "${rp}.control_plane.start")
  CP_MGMT_COUNT=$(cfg "${rp}.control_plane.count" '5')
  FLB_MANAGEMENT_STARTING_IP=$(cfg "${rp}.flb_management.start")
  FLB_MANAGEMENT_IP_COUNT=$(cfg "${rp}.flb_management.count" '3')
  FLB_NW_STARTING_IP=$(cfg "${rp}.flb_frontend.start")
  FLB_NW_IP_COUNT=$(cfg "${rp}.flb_frontend.count" '10')
  FLB_WORKLOAD_NW_STARTING_IP=$(cfg "${rp}.workload_node.start")
  FLB_WORKLOAD_IP_COUNT=$(cfg "${rp}.workload_node.count" '50')
  FLB_VIP_STARTING_IP=$(cfg "${rp}.vip.start")
  FLB_VIP_IP_COUNT=$(cfg "${rp}.vip.count" '100')

  # ---- govc environment for the UNDERLYING ESXi (password set per-step via
  #      govc_target). Set here so stage_check/verify can display the target. ----
  export GOVC_URL="https://${UNDERLYING_HOST}/sdk"
  export GOVC_USERNAME="${UNDERLYING_USER}"
  export GOVC_INSECURE=true          # self-signed cert on the underlying target
  export GOVC_DATASTORE="${UNDERLYING_DATASTORE}"
  if [[ "$UNDERLYING_TYPE" == "vcenter" ]]; then
    export GOVC_DATACENTER="${UNDERLYING_DATACENTER}"
  else
    export GOVC_DATACENTER=""         # standalone ESXi: implicit "ha-datacenter"
  fi

  export UNDERLYING_TYPE UNDERLYING_HOST UNDERLYING_DATASTORE UNDERLYING_PG UNDERLYING_USER
  export UNDERLYING_DATACENTER UNDERLYING_CLUSTER
  export S2_PROFILE ESXI_OVA ESXI_OVA_NETWORK ESXI_DNS_PREFIX ESXI_CPU ESXI_MEM
  export ESXI_DISK_BOOT ESXI_DISK_TOTAL_GB ESXI_CACHE_GB ESXI_CAP_GB N_NESXI
  export ESXI_MGMT_CIDR ESXI_NETMASK ESXI_GW
  export VCSA_ISO VCSA_ISO_MOUNT VCSA_DNS_NAME VCSA_SSO_DOMAIN VCSA_SIZE VCSA_CPU VCSA_MEM_GB
  export VCSA_IP VCSA_FQDN VCSA_USER VCSA_PREFIX VCSA_GW
  export CLUSTER_NAME CLUSTER_DC VDS_NAME VDS_VERSION VDS_UPLINK_PNIC VSAN_FTT VSAN_DS
  export SUPER_MGMT_NET SUPER_MGMT_VLAN_ID SUPER_MGMT_CIDR
  export SUPER_WKLD_NET SUPER_WKLD_VLAN_ID SUPER_WKLD_CIDR
  export MGMT_PG_NAME WKLD_PG_NAME
  export SUPERVISOR_NAME SUPER_CP_SIZE SUPERVISOR_SIZE SUPERVISOR_VM_COUNT
  export CONTENT_LIB CONTENT_LIB_URL CONTENT_LIB_ON_DEMAND STORAGE_POLICY VKS_STORAGE_POLICY
  export MGMT_GATEWAY_CIDR FLB_WORKLOAD_NW_GATEWAY_CIDR DNS_SERVER DNS_SEARCHDOMAIN NTP_SERVER
  export K8S_SERVICE_SUBNET K8S_SERVICE_SUBNET_COUNT
  export CP_MGMT_START CP_MGMT_COUNT
  export FLB_MANAGEMENT_STARTING_IP FLB_MANAGEMENT_IP_COUNT
  export FLB_NW_STARTING_IP FLB_NW_IP_COUNT
  export FLB_WORKLOAD_NW_STARTING_IP FLB_WORKLOAD_IP_COUNT
  export FLB_VIP_STARTING_IP FLB_VIP_IP_COUNT
  export DOMAIN ARTIFACTS_DIR CERTS_DIR CA_BUNDLE REGISTRY_FQDN NATIVE_GW

  log "Stage 2 model: profile=${S2_PROFILE} target=${UNDERLYING_HOST} nested_esxi=${N_NESXI} vcsa=${VCSA_FQDN}(${VCSA_IP}) vsan=OSA"
}

# Source every step + rollback definition.
_load_steps() {
  local f
  for f in "${STAGE2_DIR}"/steps/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
  done
  for f in "${STAGE2_DIR}"/rollback/*.sh; do
    [[ -e "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

stage_reset_from() {
  local from="$1" hit="" s
  for s in "${STEPS[@]}"; do
    [[ "$s" == "$from" ]] && hit=1
    [[ -n "$hit" ]] && unmark "$s"
  done
  [[ -n "$hit" ]] || die "--from-step '${from}' is not a stage-2 step: ${STEPS[*]}"
  log "Reset checkpoints from '${from}' onward; those steps will re-run."
}

stage_run() {
  _load_steps
  mkdir -p "$LAB_STATE_DIR"; chmod 0750 "$LAB_STATE_DIR"
  local s
  for s in "${STEPS[@]}"; do
    run_step "$s" "step_${s}"
  done
  printf '\n'
  ok "Stage 2 complete. Summary: ${LAB2_INFO_FILE}"
}

stage_rollback() {
  _load_steps
  local step="$1"
  [[ -n "$step" ]] || die "--rollback needs a step name: ${STEPS[*]}"
  if ! declare -F "rollback_${step}" >/dev/null; then
    local s avail=""
    for s in "${STEPS[@]}"; do
      declare -F "rollback_${s}" >/dev/null && avail="${avail:+$avail }${s}"
    done
    die "No rollback defined for step '${step}'. Steps with rollback: ${avail:-none}."
  fi
  CURRENT_STEP="rollback:${step}"
  log "Rolling back step '${step}'"
  "rollback_${step}"
  unmark "$step"
  ok "Rollback of '${step}' complete; checkpoint cleared."
}

stage_check() {
  _load_steps
  log "DRY-RUN plan for stage 2 (no changes will be made):"
  local s state
  for s in "${STEPS[@]}"; do
    if is_done "$s"; then state="done "; else state="TODO "; fi
    printf '   [%s] %s\n' "$state" "$s"
  done
  printf '\n'
  log "Nested ESXi nodes (from dns.records prefix '${ESXI_DNS_PREFIX}'):"
  local i
  for ((i=0; i<N_NESXI; i++)); do
    printf '   %s  %s\n' "${NESXI_IP[i]}" "${NESXI_FQDN[i]}"
  done
  printf '\n'
  log "Target: ${GOVC_URL}  datastore: ${UNDERLYING_DATASTORE}  portgroup: ${UNDERLYING_PG}"
  log "vCenter: ${VCSA_FQDN} (${VCSA_IP})  DC: ${CLUSTER_DC}  cluster: ${CLUSTER_NAME}"
  log "Run for real with: ./run.sh --stage 2"
}
