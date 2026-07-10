#!/usr/bin/env bash
# ============================================================================
# Nested vSphere Lab - uniform entrypoint for all stages (pure Bash).
#
#   ./run.sh --stage 1                          # jumpbox: router/DNS/DHCP/CA/registry
#   ./run.sh --stage 2                          # nested vSphere + Supervisor
#   ./run.sh --stage 2 --from-step cluster      # resume from a step
#   ./run.sh --stage 2 --verify                 # run the test suite only
#   ./run.sh --stage 1 --rollback routing       # scoped per-step rollback
#
# See `./run.sh --help` for the full per-stage step list and options.
# Runs locally on the jumpbox as root. Reads one YAML input file; secrets come
# from a gitignored secrets.env (or interactive prompt).
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- defaults ----
INPUT_FILE="input.yaml"
STAGE="1"
FROM_STEP=""
ROLLBACK_STEP=""
MODE="run"            # run | verify | rollback | check
export FORCE="" VERBOSE=""

usage() {
  cat <<'EOF'
Nested vSphere Lab — uniform entrypoint for all stages (pure Bash).

USAGE
  ./run.sh --stage <1|2> [--from-step STEP] [--rollback STEP]
           [--verify] [--check] [--force] [--input FILE] [-v]

OPTIONS
  --stage <1|2>     Which stage to operate on (default: 1).
  --from-step STEP  Resume: re-run STEP and every step after it.
  --rollback STEP   Scoped rollback of one mutating step, then re-run.
  --verify          Run the live test suite only (no changes).
  --check           Dry-run: print the plan + derived model; change nothing.
  --force           Re-run steps already marked complete in the state file.
  --input FILE      Input YAML (default: input.yaml).
  -v, --verbose     Verbose logging.
  -h, --help        Show this help.

STAGE 1 — jumpbox: router/NAT, VLANs, BIND DNS, Kea DHCP, root CA, OCI registry
  steps: preflight base_os certs networking routing dns dhcp registry labinfo
    ./run.sh --stage 1
    ./run.sh --stage 1 --from-step networking
    ./run.sh --stage 1 --rollback routing
    ./run.sh --stage 1 --verify

STAGE 2 — nested vSphere: ESXi + vCenter (VCSA) + Supervisor (vSphere Foundation LB)
  steps: preflight esxi vcenter cluster supervisor labinfo
    preflight   Stage-1 health (CA/DNS/registry), underlying target reachable,
                OVA/ISO present under artifacts.dir, capacity, >=3 ESXi records.
    esxi        Deploy N nested ESXi from the OVA; size CPU/mem + vSAN disks;
                enable nested-HV; power on.
    vcenter     Deploy VCSA via vcsa-deploy; resize the VM to vcsa.cpu/mem_gb
                (hot-add, else power-cycle); wait for the APIs.
    cluster     Datacenter + cluster (DRS); seed the vLCM depot from a host and
                align the cluster image; add hosts; VDS + portgroups; vSAN (OSA)
                + HA; WCP storage policy.
    supervisor  Content library; enable Supervisor with the Foundation LB;
                wait for RUNNING.
    labinfo     Write the access sheet (/etc/nested-lab/lab2-info.txt).
    ./run.sh --stage 2
    ./run.sh --stage 2 --from-step cluster
    ./run.sh --stage 2 --rollback esxi
    ./run.sh --stage 2 --verify

NOTES
  Runs locally on the jumpbox as root. Reads one YAML input file (input.yaml);
  secrets come from a gitignored secrets.env (or an interactive no-echo prompt).
  Logs: logs/stage<N>-<timestamp>.log   State/checkpoints: state/stage<N>.state
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)     INPUT_FILE="$2"; shift 2 ;;
    --stage)     STAGE="$2"; shift 2 ;;
    --from-step) FROM_STEP="$2"; shift 2 ;;
    --rollback)  MODE="rollback"; ROLLBACK_STEP="$2"; shift 2 ;;
    --verify)    MODE="verify"; shift ;;
    --check)     MODE="check"; shift ;;
    --force)     FORCE=1; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)   usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 2 ;;
  esac
done

export INPUT_FILE STAGE

case "$STAGE" in
  1) STAGE_DIR="stages/stage1-jumpbox" ;;
  2) STAGE_DIR="stages/stage2-nested-vsphere" ;;
  *) echo "ERROR: unknown stage '${STAGE}'. Valid: 1, 2." >&2; exit 2 ;;
esac
[[ -d "$STAGE_DIR" ]] || { echo "ERROR: stage dir '$STAGE_DIR' missing." >&2; exit 2; }
[[ -f "$INPUT_FILE" ]] || { echo "ERROR: input '$INPUT_FILE' not found. Copy input.example.yaml and edit it." >&2; exit 2; }

# ---- logging: mirror everything to a timestamped log file ----
mkdir -p logs state
export STATE_FILE="state/stage${STAGE}.state"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="logs/stage${STAGE}-${TS}.log"
exec > >(tee -a "$LOG") 2>&1

# ---- load libraries (order matters: common first) ----
# shellcheck source=lib/common.sh
source lib/common.sh
trap on_err ERR
# shellcheck source=lib/ipcalc.sh
source lib/ipcalc.sh
# shellcheck source=lib/yaml.sh
source lib/yaml.sh
# shellcheck source=lib/os.sh
source lib/os.sh

log "Nested vSphere Lab :: stage ${STAGE} :: mode=${MODE} :: log ${LOG}"
need_root
detect_os
log "Detected OS family: ${OS_FAMILY} (${OS_PRETTY})"
require_yq
load_secrets

# Stage 2 needs the govc helpers.
if [[ "$STAGE" == "2" ]]; then
  # shellcheck source=lib/govc.sh
  source lib/govc.sh
fi

# shellcheck disable=SC1090
source "${STAGE_DIR}/stage.sh"
compute_derived

case "$MODE" in
  run)
    [[ -n "$FROM_STEP" ]] && stage_reset_from "$FROM_STEP"
    stage_run
    ;;
  verify)
    # shellcheck disable=SC1090
    source "${STAGE_DIR}/verify.sh"
    verify_main
    ;;
  rollback)
    stage_rollback "$ROLLBACK_STEP"
    ;;
  check)
    stage_check
    ;;
esac
