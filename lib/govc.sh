#!/usr/bin/env bash
# ============================================================================
# lib/govc.sh - govc and vCenter REST API helpers for Stage 2.
# Sourced by stages/stage2-nested-vsphere/stage.sh.
# Requires: govc 0.54+, curl, jq.
# ============================================================================

require_govc() {
  command -v govc >/dev/null 2>&1 || die "govc not found. Run ./bootstrap.sh first."
  local ver; ver=$(govc version 2>/dev/null || true)
  log "govc: ${ver}"
}

# ---------------------------------------------------------------------------
# govc_vm_exists <name>
# Returns 0 if a VM with exactly that name exists on the current GOVC_URL target.
# ---------------------------------------------------------------------------
govc_vm_exists() {
  govc find -type m -name "$1" 2>/dev/null | grep -q .
}

# ---------------------------------------------------------------------------
# govc_object_exists <inventory-path>
# Returns 0 if the inventory path exists (datacenter, cluster, DVS, PG, etc.).
# NB: `govc ls` exits 0 for a valid-but-missing path (empty glob), so it gives
# false positives. `object.collect -s <path> name` errors when the managed
# object does not exist, which is the reliable signal.
# ---------------------------------------------------------------------------
govc_object_exists() {
  govc object.collect -k -s "$1" name >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# govc_vm_power_state <name>
# Prints poweredOn | poweredOff | suspended; empty on error.
# ---------------------------------------------------------------------------
govc_vm_power_state() {
  govc vm.info -json "$1" 2>/dev/null \
    | jq -r '.virtualMachines[0].runtime.powerState // empty' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# wait_https <url> [max_seconds]
# Polls until a 2xx HTTP response or timeout (default 1800s / 30 min).
# ---------------------------------------------------------------------------
wait_https() {
  local url="$1" max="${2:-1800}" elapsed=0
  while (( elapsed < max )); do
    local code
    code=$(curl -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    case "$code" in 2*) return 0 ;; esac
    sleep 20; (( elapsed += 20 )) || true
    log "Waiting for ${url} ... ${elapsed}/${max}s (last HTTP ${code:-err})"
  done
  die "Timed out (${max}s) waiting for ${url}"
}

# ---------------------------------------------------------------------------
# vc_session <vcenter-ip> <user> <password>
# Creates a vCenter REST session and prints the session token.
# ---------------------------------------------------------------------------
vc_session() {
  local host="$1" user="$2" pass="$3"
  curl -sk -X POST -u "${user}:${pass}" \
    "https://${host}/api/session" \
    -H "Content-Type: application/json" 2>/dev/null \
    | tr -d '"'
}

# ---------------------------------------------------------------------------
# vc_api <method> <host> <token> <path> [extra-curl-args...]
# Calls the vCenter REST API. Prints response body; dies on non-2xx.
# ---------------------------------------------------------------------------
vc_api() {
  local method="$1" host="$2" token="$3" path="$4"; shift 4
  local tmp_resp tmp_code
  tmp_resp=$(mktemp); tmp_code=$(mktemp)
  curl -sk -X "$method" \
    -H "vmware-api-session-id: ${token}" \
    -H "Content-Type: application/json" \
    -o "$tmp_resp" -w '%{http_code}' \
    "https://${host}${path}" "$@" >"$tmp_code" 2>/dev/null || true
  local code; code=$(cat "$tmp_code"); rm -f "$tmp_code"
  local body; body=$(cat "$tmp_resp"); rm -f "$tmp_resp"
  case "$code" in
    2*) printf '%s' "$body" ;;
    *)  die "vCenter API ${method} ${path} -> HTTP ${code}: ${body}" ;;
  esac
}

# ---------------------------------------------------------------------------
# govc_target <underlying|nested-vc|nested-esxi> [esxi-ip]
# Point the GOVC_* environment at one of the three targets Stage 2 talks to.
# Replaces the per-step/per-rollback `export GOVC_*` blocks. Relies on the
# globals set by compute_derived (UNDERLYING_*, VCSA_*, CLUSTER_DC) and the
# secrets loaded by run.sh (UNDERLYING_PASSWORD, VCSA_SSO_PASSWORD,
# ESXI_ROOT_PASSWORD).
# ---------------------------------------------------------------------------
govc_target() {
  local kind="$1" ip="${2:-}"
  export GOVC_INSECURE=true
  case "$kind" in
    underlying)
      export GOVC_URL="https://${UNDERLYING_HOST}/sdk"
      export GOVC_USERNAME="${UNDERLYING_USER}"
      export GOVC_PASSWORD="${UNDERLYING_PASSWORD}"
      export GOVC_DATASTORE="${UNDERLYING_DATASTORE}"
      if [[ "${UNDERLYING_TYPE:-esxi}" == "vcenter" ]]; then
        # Placement context so import.ova/find resolve on a real vCenter.
        export GOVC_DATACENTER="${UNDERLYING_DATACENTER}"
        export GOVC_CLUSTER="${UNDERLYING_CLUSTER}"
        export GOVC_RESOURCE_POOL=""
      else
        export GOVC_DATACENTER=""        # standalone ESXi: implicit "ha-datacenter"
        unset GOVC_CLUSTER GOVC_RESOURCE_POOL 2>/dev/null || true
      fi
      ;;
    nested-vc)
      export GOVC_URL="https://${VCSA_IP}/sdk"
      export GOVC_USERNAME="${VCSA_USER}"
      export GOVC_PASSWORD="${VCSA_SSO_PASSWORD}"
      export GOVC_DATACENTER="${CLUSTER_DC}"
      export GOVC_DATASTORE=""
      ;;
    nested-esxi)
      [[ -n "$ip" ]] || die "govc_target nested-esxi requires an IP"
      export GOVC_URL="https://${ip}/sdk"
      export GOVC_USERNAME="root"
      export GOVC_PASSWORD="${ESXI_ROOT_PASSWORD}"
      export GOVC_DATACENTER=""
      export GOVC_DATASTORE=""
      ;;
    *) die "govc_target: unknown target '${kind}' (underlying|nested-vc|nested-esxi)" ;;
  esac
}

# ---------------------------------------------------------------------------
# wait_for_task <vc-host> <token> <task-moid> [max_seconds]
# Poll a vim25 SOAP-REST task to completion. Ported from the validated
# scratch/create-cluster.sh. Returns 0 on success; dies on error/timeout.
# ---------------------------------------------------------------------------
wait_for_task() {
  local host="$1" token="$2" task="$3" max="${4:-1800}" elapsed=0
  local url="https://${host}/sdk/vim25/9.0.0.0/Task/${task}/info"
  while (( elapsed < max )); do
    local state
    state=$(curl -sk "$url" -H "vmware-api-session-id: ${token}" 2>/dev/null \
      | jq -r '.state // empty' 2>/dev/null || true)
    case "$state" in
      success) return 0 ;;
      error)
        local msg
        msg=$(curl -sk "$url" -H "vmware-api-session-id: ${token}" 2>/dev/null \
          | jq -r '.error.localizedMessage // .error.fault._typeName // "unknown error"' \
          2>/dev/null || true)
        die "vim25 task ${task} failed: ${msg}"
        ;;
    esac
    sleep 5; (( elapsed += 5 )) || true
  done
  die "Timed out (${max}s) waiting for vim25 task ${task}"
}

# ---------------------------------------------------------------------------
# vc_reconfigure_cluster <vc-host> <token> <cluster-moid> <inner-spec-json>
# POST a ReconfigureComputeResource_Task with the given ClusterConfigSpecEx
# body (produced by a step's pure _render_* fn) and print the task MOID.
# The caller passes the result to wait_for_task. modify=true so the spec is
# merged (declarative / idempotent) rather than replacing the whole config.
# ---------------------------------------------------------------------------
vc_reconfigure_cluster() {
  local host="$1" token="$2" cluster_moid="$3" spec="$4"
  local body
  body=$(jq -n --argjson spec "$spec" '{spec: $spec, modify: true}') \
    || die "vc_reconfigure_cluster: invalid spec JSON"
  curl -sk -X POST \
    "https://${host}/sdk/vim25/9.0.0.0/ComputeResource/${cluster_moid}/ReconfigureComputeResource_Task" \
    -H "vmware-api-session-id: ${token}" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null | jq -r '.value // empty'
}

# ---------------------------------------------------------------------------
# depot_base_image_for_build <vc-host> <token> <build>
# Print the vLCM depot base-image version whose build matches <build> (depot
# version strings end in ".<build>", e.g. "9.1.0.0.25370933"). Empty if the
# depot has no matching base image. Soft (never dies) so callers can use it both
# as a gate and a poll predicate. Used by the imageseed gate + the cluster
# image-align.
# ---------------------------------------------------------------------------
depot_base_image_for_build() {
  curl -sk -H "vmware-api-session-id: ${2}" \
    "https://${1}/api/esx/settings/depot-content/base-images" 2>/dev/null \
    | jq -r --arg b ".${3}" \
        '[.[] | select(.version | endswith($b))] | first | .version // empty' \
        2>/dev/null || true
}
