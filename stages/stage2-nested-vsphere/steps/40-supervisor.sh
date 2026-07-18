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

# _url_ssl_thumbprint <https-url>  -> SHA-1 thumbprint (AA:BB:..) of the host's
# TLS cert, for content-library subscription over HTTPS. Uses openssl on the
# jumpbox (which has egress). Empty on failure.
_url_ssl_thumbprint() {
  local url="$1" host port
  host=$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#/.*$##; s#:[0-9]+$##')
  port=$(printf '%s' "$url" | sed -nE 's#^[a-z]+://[^/:]+:([0-9]+).*#\1#p'); port="${port:-443}"
  # timeout guards against an unreachable content_library_url host hanging
  # the whole run on openssl's default (long) TCP-connect wait.
  echo | timeout 15 openssl s_client -connect "${host}:${port}" -servername "${host}" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//'
}

# ---------------------------------------------------------------------------
# Content library: SUBSCRIBED (TKr) when content_library_url is set, else LOCAL.
# ---------------------------------------------------------------------------
_create_content_library() {
  # No 2>/dev/null here: vc_api dies with a specific "HTTP <code>: <body>"
  # message on a real failure, and since this call isn't inside a pipeline,
  # that die's `exit` terminates this assignment's subshell before the
  # `|| echo '[]'` fallback ever runs -- discarding stderr would silently
  # swallow the one message that explains why, leaving only run.sh's generic
  # "command failed" from the ERR trap.
  local libs; libs=$(vc_api GET "${VCSA_IP}" "${_WCP_TOK}" "/api/content/library" || echo '[]')
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

  # vSphere 8/9: the body is the LibraryModel directly (no create_spec wrapper —
  # that is the older /rest/ shape) and no client_token (vSphere 9 rejects it as
  # an unsupported property). Subscribed vs local is chosen by content_library_url.
  local body
  if [[ -n "${CONTENT_LIB_URL}" ]]; then
    log "Creating SUBSCRIBED content library '${CONTENT_LIB}' (${CONTENT_LIB_URL}, on_demand=${CONTENT_LIB_ON_DEMAND}) ..."
    # HTTPS subscription URLs need the server's SSL thumbprint (per the API:
    # "ssl_thumbprint required for HTTPS subscription URLs"). Fetch it from the
    # jumpbox (which has egress); include it only if we got one.
    local sslthumb=""
    case "${CONTENT_LIB_URL}" in
      https://*) sslthumb=$(_url_ssl_thumbprint "${CONTENT_LIB_URL}") ;;
    esac
    [[ -n "$sslthumb" ]] && log "  subscription SSL thumbprint: ${sslthumb}"
    body=$(jq -n \
      --arg name "${CONTENT_LIB}" --arg ds "${ds_id}" --arg url "${CONTENT_LIB_URL}" \
      --argjson ondemand "${CONTENT_LIB_ON_DEMAND}" --arg thumb "${sslthumb}" \
      '{ name: $name, type: "SUBSCRIBED",
         storage_backings: [ { type: "DATASTORE", datastore_id: $ds } ],
         subscription_info: (
           { authentication_method: "NONE",
             automatic_sync_enabled: false,
             on_demand: $ondemand,
             subscription_url: $url }
           + (if $thumb != "" then { ssl_thumbprint: $thumb } else {} end)
         ) }')
    vc_api POST "${VCSA_IP}" "${_WCP_TOK}" "/api/content/subscribed-library" \
      -d "$body" >/dev/null \
      || die "Failed to create subscribed content library '${CONTENT_LIB}'"
  else
    log "Creating LOCAL content library '${CONTENT_LIB}' ..."
    body=$(jq -n --arg name "${CONTENT_LIB}" --arg ds "${ds_id}" \
      '{ name: $name, type: "LOCAL",
         storage_backings: [ { type: "DATASTORE", datastore_id: $ds } ],
         description: "Nested lab content library" }')
    vc_api POST "${VCSA_IP}" "${_WCP_TOK}" "/api/content/local-library" \
      -d "$body" >/dev/null \
      || die "Failed to create content library '${CONTENT_LIB}'"
  fi
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

  # WCP references the storage policy by its SPBM ID, not its display name —
  # resolve name -> id and feed the id to the payload (VKS_STORAGE_POLICY).
  local policy_id
  policy_id=$(vc_api GET "${VCSA_IP}" "${_WCP_TOK}" "/api/vcenter/storage/policies" \
    | jq -r --arg n "${STORAGE_POLICY}" '.[] | select(.name == $n) | .policy' | head -1)
  [[ -n "$policy_id" ]] \
    || die "Storage policy '${STORAGE_POLICY}' not found via vCenter API (create it in the cluster step)"
  export VKS_STORAGE_POLICY="$policy_id"
  log "Storage policy '${STORAGE_POLICY}' -> ${policy_id}"

  local body; body=$(mktemp)
  _render_wcp_payload >"$body" || die "Failed to render WCP enable payload"
  jq empty "$body" 2>/dev/null || die "Rendered WCP payload is not valid JSON"

  log "Enabling Supervisor on '${CLUSTER_NAME}' (this takes 15-30 min) ..."
  # vSphere 9.x: POST the enable spec to the SUPERVISORS collection keyed by the
  # cluster MOID with ?action=enable_on_compute_cluster (per the Automation API
  # and papivot/bash-wcpcli9). NB: not .../clusters/{moid} — that path is for
  # status/disable only.
  vc_api POST "${VCSA_IP}" "${_WCP_TOK}" \
    "/api/vcenter/namespace-management/supervisors/${moid}?action=enable_on_compute_cluster" \
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
