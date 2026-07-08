#!/usr/bin/env bash
# ============================================================================
# supervisor :: Enable vSphere Supervisor (WCP) with the vSphere Foundation
# Load Balancer. Renders the validated Foundation-LB payload
# (templates/enable_flb.json.tmpl, from scratch/enable_on_cc_flb.json) and POSTs
# it to the namespace-management "enable_on_compute_cluster" action.
#
# NOTE: the jumpbox OCI registry is NOT wired into this validated FLB payload
# (the field-tested payload does not include an image registry). The registry
# remains reachable at REGISTRY_FQDN and can be added as the Supervisor image
# registry as a follow-on; see docs/STAGE2-PLAN.md.
# ============================================================================

_WCP_TOK=""
_wcp_tok() {
  _WCP_TOK=$(vc_session "${VCSA_IP}" "${VCSA_USER}" "${VCSA_SSO_PASSWORD}") \
    || die "Could not create vCenter session for Supervisor step"
}

# Path to the committed WCP enable template.
_wcp_template() { printf '%s' "${STAGE2_DIR}/templates/enable_flb.json.tmpl"; }

step_supervisor() {
  _wcp_tok
  _resolve_network_moids     # sets VKS_MGMT_NETWORK1 / VKS_WKLD_NETWORK
  _create_content_library
  _enable_supervisor
  ok "Supervisor is enabled on cluster '${CLUSTER_NAME}'."
}

# ---------------------------------------------------------------------------
# Resolve the mgmt + workload DVPG names to network MOIDs (needed by the WCP
# payload). Exported so _render_wcp_payload (pure) can substitute them.
# ---------------------------------------------------------------------------
_resolve_network_moids() {
  local nets; nets=$(vc_api GET "${VCSA_IP}" "${_WCP_TOK}" "/api/vcenter/network")
  VKS_MGMT_NETWORK1=$(printf '%s' "$nets" \
    | jq -r --arg n "${MGMT_PG_NAME}" '.[] | select(.name == $n) | .network' | head -1)
  VKS_WKLD_NETWORK=$(printf '%s' "$nets" \
    | jq -r --arg n "${WKLD_PG_NAME}" '.[] | select(.name == $n) | .network' | head -1)
  [[ -n "$VKS_MGMT_NETWORK1" ]] || die "mgmt portgroup '${MGMT_PG_NAME}' not found in vCenter"
  [[ -n "$VKS_WKLD_NETWORK"  ]] || die "workload portgroup '${WKLD_PG_NAME}' not found in vCenter"
  export VKS_MGMT_NETWORK1 VKS_WKLD_NETWORK
  ok "Resolved networks: mgmt=${VKS_MGMT_NETWORK1} workload=${VKS_WKLD_NETWORK}"
}

# ---------------------------------------------------------------------------
# _render_wcp_payload  (PURE)
# Render the Foundation-LB enable payload from the committed template. Testable:
# set the model vars and assert the JSON (addresses not CIDRs, workload nets
# present) in step_supervisor.bats.
# ---------------------------------------------------------------------------
_render_wcp_payload() {
  envsubst '${SUPERVISOR_VM_COUNT} ${VKS_MGMT_NETWORK1} ${MGMT_GATEWAY_CIDR}
            ${CP_MGMT_START} ${CP_MGMT_COUNT} ${DNS_SEARCHDOMAIN} ${DNS_SERVER}
            ${NTP_SERVER} ${SUPERVISOR_SIZE} ${VKS_STORAGE_POLICY} ${SUPERVISOR_NAME}
            ${FLB_MANAGEMENT_STARTING_IP} ${FLB_MANAGEMENT_IP_COUNT}
            ${FLB_WORKLOAD_NW_GATEWAY_CIDR} ${FLB_NW_STARTING_IP} ${FLB_NW_IP_COUNT}
            ${VKS_WKLD_NETWORK} ${FLB_VIP_STARTING_IP} ${FLB_VIP_IP_COUNT}
            ${FLB_WORKLOAD_NW_STARTING_IP} ${FLB_WORKLOAD_IP_COUNT}
            ${K8S_SERVICE_SUBNET} ${K8S_SERVICE_SUBNET_COUNT}' \
    < "$(_wcp_template)"
}

# ---------------------------------------------------------------------------
# LOCAL content library on the vSAN datastore (for TKr/OVA imports).
# ---------------------------------------------------------------------------
_create_content_library() {
  local libs; libs=$(vc_api GET "${VCSA_IP}" "${_WCP_TOK}" "/api/content/library" 2>/dev/null || echo '[]')
  local id name
  for id in $(printf '%s' "$libs" | jq -r '.[]' 2>/dev/null); do
    name=$(vc_api GET "${VCSA_IP}" "${_WCP_TOK}" "/api/content/library/${id}" 2>/dev/null \
      | jq -r '.name // empty' 2>/dev/null || true)
    if [[ "$name" == "${CONTENT_LIB}" ]]; then
      ok "Content library '${CONTENT_LIB}' already exists (ID: ${id})."
      return
    fi
  done

  local ds_id
  ds_id=$(vc_api GET "${VCSA_IP}" "${_WCP_TOK}" "/api/vcenter/datastore" \
    | jq -r --arg n "${VSAN_DS}" '.[] | select(.name == $n) | .datastore' | head -1) \
    || die "Could not find datastore '${VSAN_DS}' for content library"
  [[ -n "$ds_id" ]] || die "Datastore '${VSAN_DS}' not found via vCenter API"

  log "Creating content library '${CONTENT_LIB}' ..."
  # vSphere 8/9: create a LOCAL library via POST /api/content/local-library.
  # (POST /api/content/library returns 404 — that path only lists/gets.) The
  # body is the LibraryModel directly (no create_spec wrapper — that is the
  # older /rest/ shape). No client_token: vSphere 9 rejects it as an unsupported
  # property on this endpoint.
  local body
  body=$(jq -n --arg name "${CONTENT_LIB}" --arg ds "${ds_id}" \
    '{ name: $name, type: "LOCAL",
       storage_backings: [ { type: "DATASTORE", datastore_id: $ds } ],
       description: "Nested lab content library" }')
  vc_api POST "${VCSA_IP}" "${_WCP_TOK}" \
    "/api/content/local-library" \
    -d "$body" >/dev/null \
    || die "Failed to create content library '${CONTENT_LIB}'"
  ok "Content library '${CONTENT_LIB}' created."
}

# ---------------------------------------------------------------------------
# Enable the Supervisor (WCP) with the Foundation LB payload.
# Idempotent: skip if already RUNNING; join the wait if CONFIGURING.
# ---------------------------------------------------------------------------
_enable_supervisor() {
  local moid; moid=$(_cluster_moid)
  [[ -n "$moid" ]] || die "Could not find cluster MOID for '${CLUSTER_NAME}'"

  local status; status=$(_wcp_status "$moid")
  case "$status" in
    RUNNING)     ok "Supervisor already RUNNING on '${CLUSTER_NAME}'."; return ;;
    CONFIGURING) log "Supervisor already CONFIGURING; joining wait ..."; _wait_supervisor_ready "$moid"; return ;;
    ERROR)       die "Supervisor is in ERROR on '${CLUSTER_NAME}'. Check https://${VCSA_IP}/ui/" ;;
  esac

  local body; body=$(mktemp)
  _render_wcp_payload >"$body" || die "Failed to render WCP enable payload"
  jq empty "$body" 2>/dev/null || die "Rendered WCP payload is not valid JSON"

  log "Enabling Supervisor on '${CLUSTER_NAME}' (this takes 15-30 min) ..."
  # "enable_on_compute_cluster" is the vSphere 9.x Foundation-LB enable action
  # (matches scratch/enable_on_cc_flb.json: enable_on_[c]ompute_[c]luster + flb).
  vc_api POST "${VCSA_IP}" "${_WCP_TOK}" \
    "/api/vcenter/namespace-management/clusters/${moid}?action=enable_on_compute_cluster" \
    -d "@${body}" >/dev/null \
    || die "Supervisor enable request failed. Check https://${VCSA_IP}/ui/"
  rm -f "$body"

  _wait_supervisor_ready "$moid"
}

_cluster_moid() {
  vc_api GET "${VCSA_IP}" "${_WCP_TOK}" "/api/vcenter/cluster" \
    | jq -r --arg n "${CLUSTER_NAME}" '.[] | select(.name == $n) | .cluster' | head -1
}

_wcp_status() {
  vc_api GET "${VCSA_IP}" "${_WCP_TOK}" \
    "/api/vcenter/namespace-management/clusters/$1" 2>/dev/null \
    | jq -r '.config_status // "NOT_CONFIGURED"' 2>/dev/null || echo "NOT_CONFIGURED"
}

_wait_supervisor_ready() {
  local moid="$1" elapsed=0 max=2400
  log "Waiting for Supervisor to reach RUNNING (up to 40 min) ..."
  while (( elapsed < max )); do
    _wcp_tok   # refresh: long wait can expire the session
    local status; status=$(_wcp_status "$moid")
    case "$status" in
      RUNNING) ok "Supervisor is RUNNING."; return ;;
      ERROR)   die "Supervisor reached ERROR. Check https://${VCSA_IP}/ui/" ;;
    esac
    sleep 30; (( elapsed += 30 )) || true
    log "  Supervisor status: ${status} (${elapsed}/${max}s) ..."
  done
  die "Timed out waiting for Supervisor to reach RUNNING."
}
