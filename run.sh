#!/usr/bin/env bash
# ============================================================================
# Nested vSphere Lab - uniform entrypoint for all stages (pure Bash).
#
#   ./run.sh --stage 1                          # full run (idempotent)
#   ./run.sh --stage 1 --from-step networking   # resume from a step
#   ./run.sh --stage 1 --check                  # dry-run: show the plan
#   ./run.sh --stage 1 --verify                 # run the test suite only
#   ./run.sh --stage 1 --rollback routing       # scoped per-step rollback
#   ./run.sh --stage 1 --force                  # re-run even completed steps
#
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

usage() { sed -n '2,20p' "$0"; exit "${1:-0}"; }

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

STAGE_DIR="stages/stage1-jumpbox"
[[ "$STAGE" == "1" ]] || { echo "ERROR: only stage 1 is implemented." >&2; exit 2; }
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

# shellcheck source=stages/stage1-jumpbox/stage.sh
source "${STAGE_DIR}/stage.sh"
compute_derived
log "Model: ${N_VLANS} VLAN(s), supernet ${SUPERNET}, private NIC ${PRIVATE_NIC}, public NIC ${PUBLIC_NIC}, registry ${REGISTRY_FQDN} (${REGISTRY_ADDR})"

case "$MODE" in
  run)
    [[ -n "$FROM_STEP" ]] && stage_reset_from "$FROM_STEP"
    stage_run
    ;;
  verify)
    # shellcheck source=stages/stage1-jumpbox/verify.sh
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
