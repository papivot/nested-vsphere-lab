#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh - install the few tools the Bash automation needs.
# Safe to re-run. Detects OS family (Ubuntu/Debian, RHEL-like, Photon).
#   - yq (mikefarah, single static binary) for YAML parsing
#   - jq, openssl, curl, ca-certificates (base utilities)
# Everything else (bind, kea, docker, nftables...) is installed by the stages.
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[bootstrap] %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run bootstrap.sh as root (sudo)."; exit 1; }

. /etc/os-release 2>/dev/null || true
FAMILY="unknown"
case "${ID:-}${ID_LIKE:-}" in
  *photon*) FAMILY=photon ;;
  *rhel*|*centos*|*fedora*|*rocky*|*almalinux*) FAMILY=redhat ;;
  *debian*|*ubuntu*) FAMILY=debian ;;
esac
log "OS family: ${FAMILY}"

install_pkgs() {
  case "$FAMILY" in
    debian) export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y "$@" ;;
    redhat) dnf install -y "$@" || yum install -y "$@" ;;
    photon) tdnf install -y "$@" ;;
    *) log "Unknown OS; please install manually: $*" ;;
  esac
}

log "Installing base utilities (jq, curl, openssl, ca-certificates, tar, gzip)"
install_pkgs jq curl openssl ca-certificates tar gzip || true

# ---- yq (mikefarah) ----
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -qiE 'mikefarah|version v?4'; then
  log "yq already present: $(yq --version)"
else
  log "Installing yq (mikefarah) static binary"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) yqarch=amd64 ;;
    aarch64|arm64) yqarch=arm64 ;;
    *) echo "Unsupported arch for yq: $arch"; exit 1 ;;
  esac
  url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yqarch}"
  if curl -fsSL "$url" -o /usr/local/bin/yq; then
    chmod +x /usr/local/bin/yq
    log "yq installed: $(/usr/local/bin/yq --version)"
  else
    echo "ERROR: could not download yq from ${url} (no internet?). Install yq manually." >&2
    exit 1
  fi
fi

# ---- govc (govmomi CLI) - required for Stage 2 ----
if command -v govc >/dev/null 2>&1 && govc version 2>/dev/null | grep -qE 'govc [0-9]'; then
  log "govc already present: $(govc version)"
else
  log "Installing govc static binary"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) govc_arch=x86_64 ;;
    aarch64|arm64) govc_arch=arm64 ;;
    *) echo "Unsupported arch for govc: $arch"; exit 1 ;;
  esac
  govc_url="https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_${govc_arch}.tar.gz"
  if curl -fsSL "$govc_url" | tar -xz -C /usr/local/bin govc; then
    chmod +x /usr/local/bin/govc
    log "govc installed: $(govc version)"
  else
    echo "ERROR: could not download govc from ${govc_url} (no internet?). Install govc manually." >&2
    exit 1
  fi
fi

log "Done. Next:"
log "  cp input.example.yaml input.yaml && \$EDITOR input.yaml"
log "  cp secrets.example.env secrets.env && \$EDITOR secrets.env   # chmod 600"
log "  ./run.sh --stage 1"
log "  ./run.sh --stage 2   # after Stage 1 is complete"
