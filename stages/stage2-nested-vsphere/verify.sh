#!/usr/bin/env bash
# ============================================================================
# verify.sh :: Live assertions for Stage 2.
#   ./run.sh --stage 2 --verify
# ============================================================================

VERIFY_FAIL=0
_t_ok()   { ok "TEST: $*"; }
_t_fail() { err "TEST: $*"; VERIFY_FAIL=$(( VERIFY_FAIL + 1 )); }
_t_warn() { warn "TEST: $*"; }

verify_main() {
  require_govc
  govc_target underlying

  # ---- Underlying ESXi reachable ----
  if govc about -k &>/dev/null; then
    _t_ok "Underlying ESXi at ${UNDERLYING_HOST} reachable via govc"
  else
    _t_fail "Underlying ESXi at ${UNDERLYING_HOST} not reachable"
  fi

  # ---- Nested ESXi VMs exist and are powered on ----
  local i
  for ((i=0; i<N_NESXI; i++)); do
    local name="${NESXI_NAME[$i]}" ip="${NESXI_IP[$i]}"
    if govc_vm_exists "$name"; then
      local state; state=$(govc_vm_power_state "$name")
      if [[ "$state" == "poweredOn" ]]; then
        _t_ok "Nested ESXi VM '${name}' exists and is powered on"
      else
        _t_fail "Nested ESXi VM '${name}' exists but is ${state}"
      fi
    else
      _t_fail "Nested ESXi VM '${name}' not found on underlying host"
    fi

    # ESXi API responding?
    local code
    code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${ip}/ui/" 2>/dev/null || true)
    case "$code" in
      200|302) _t_ok "Nested ESXi ${ip} /ui/ responds (HTTP ${code})" ;;
      *) _t_fail "Nested ESXi ${ip} /ui/ HTTP ${code:-err}" ;;
    esac
  done

  # ---- VCSA VM exists and is powered on ----
  if govc_vm_exists "${VCSA_DNS_NAME}"; then
    local vcsa_state; vcsa_state=$(govc_vm_power_state "${VCSA_DNS_NAME}")
    if [[ "$vcsa_state" == "poweredOn" ]]; then
      _t_ok "VCSA VM '${VCSA_DNS_NAME}' exists and is powered on"
    else
      _t_fail "VCSA VM '${VCSA_DNS_NAME}' exists but is ${vcsa_state}"
    fi
  else
    _t_fail "VCSA VM '${VCSA_DNS_NAME}' not found on underlying host"
  fi

  # ---- vCenter API responding ----
  local vc_code
  vc_code=$(curl -sk -o /dev/null -w '%{http_code}' \
    "https://${VCSA_IP}/api/vcenter/datacenter" \
    -u "${VCSA_USER}:${VCSA_SSO_PASSWORD}" 2>/dev/null || true)
  case "$vc_code" in
    200) _t_ok "vCenter REST API at ${VCSA_IP} healthy (HTTP 200)" ;;
    *)   _t_fail "vCenter REST API at ${VCSA_IP} HTTP ${vc_code:-err}" ;;
  esac

  # ---- Nested cluster: hosts connected ----
  govc_target nested-vc

  local cluster_path="/${CLUSTER_DC}/host/${CLUSTER_NAME}"
  if govc_object_exists "$cluster_path"; then
    _t_ok "Cluster '${CLUSTER_DC}/${CLUSTER_NAME}' exists in vCenter"
    local connected_hosts
    connected_hosts=$(govc find "${cluster_path}" -type h 2>/dev/null | wc -l | tr -d ' ')
    if (( connected_hosts >= N_NESXI )); then
      _t_ok "${connected_hosts} host(s) connected to cluster (expected ${N_NESXI})"
    else
      _t_fail "Only ${connected_hosts}/${N_NESXI} hosts connected to cluster"
    fi
  else
    _t_fail "Cluster '${CLUSTER_DC}/${CLUSTER_NAME}' not found in vCenter"
  fi

  # ---- vSAN datastore visible ----
  if govc find "/${CLUSTER_DC}/datastore" -type s -name "${VSAN_DS}" 2>/dev/null | grep -q .; then
    _t_ok "vSAN datastore '${VSAN_DS}' is visible"
  else
    _t_fail "vSAN datastore '${VSAN_DS}' not found"
  fi

  # ---- Supervisor status ----
  local tok
  tok=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}" 2>/dev/null || true)
  if [[ -n "$tok" ]]; then
    local cluster_moid
    cluster_moid=$(vc_api GET "${VCSA_IP}" "$tok" "/api/vcenter/cluster" \
      | jq -r --arg name "${CLUSTER_NAME}" '.[] | select(.name == $name) | .cluster' \
      2>/dev/null || true)
    if [[ -n "$cluster_moid" ]]; then
      local wcp_status
      wcp_status=$(vc_api GET "${VCSA_IP}" "$tok" \
        "/api/vcenter/namespace-management/clusters/${cluster_moid}" \
        2>/dev/null | jq -r '.config_status // "UNKNOWN"' 2>/dev/null \
        || echo "UNKNOWN")
      if [[ "$wcp_status" == "RUNNING" ]]; then
        _t_ok "Supervisor (WCP) is RUNNING on cluster '${CLUSTER_NAME}'"
      else
        _t_fail "Supervisor status is '${wcp_status}' (expected RUNNING)"
      fi
    else
      _t_fail "Could not find cluster MOID for '${CLUSTER_NAME}' via vCenter API"
    fi
  else
    _t_fail "Could not obtain vCenter API session token (check credentials)"
  fi

  # ---- CA bundle trusted by jumpbox ----
  if [[ -f "$CA_BUNDLE" ]]; then
    _t_ok "Lab CA bundle present: ${CA_BUNDLE}"
  else
    _t_fail "Lab CA bundle missing: ${CA_BUNDLE}"
  fi

  echo ""
  if (( VERIFY_FAIL == 0 )); then
    ok "ALL stage 2 verification checks PASSED."
  else
    die "${VERIFY_FAIL} verification check(s) FAILED (see above)."
  fi
}
