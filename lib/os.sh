#!/usr/bin/env bash
# ============================================================================
# lib/os.sh - OS family detection + per-OS package/service/path maps.
# Mirrors the Ansible per-OS vars files (base_os/dns_bind/dhcp_kea vars/*.yml).
# Supported families: debian (Ubuntu/Debian), redhat (RHEL/Rocky/Alma), photon.
# ============================================================================

detect_os() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  local id="${ID:-}${ID_LIKE:-}"
  case "$id" in
    *photon*)                                  OS_FAMILY=photon ;;
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*) OS_FAMILY=redhat ;;
    *debian*|*ubuntu*)                         OS_FAMILY=debian ;;
    *)                                         OS_FAMILY=unknown ;;
  esac
  OS_PRETTY="${PRETTY_NAME:-$OS_FAMILY}"
  _os_vars
}

_os_vars() {
  case "$OS_FAMILY" in
    debian)
      BASE_PACKAGES=(vlan nftables iptables jq curl openssl ca-certificates bridge-utils chrony bind9-utils)
      NTP_SERVICE=chrony;  NTP_CONF=/etc/chrony/chrony.conf
      CA_TRUST_DIR=/usr/local/share/ca-certificates; CA_TRUST_UPDATE=update-ca-certificates
      BIND_PACKAGES=(bind9 bind9-utils dnsutils); BIND_SERVICE=named; BIND_USER=bind; BIND_GROUP=bind
      BIND_LAYOUT=include
      NAMED_MAIN=/etc/bind/named.conf
      NAMED_OPTIONS=/etc/bind/named.conf.options
      NAMED_LOCAL=/etc/bind/named.conf.local
      NAMED_CACHE_DIR=/var/cache/bind
      ZONES_DIR=/etc/bind/zones
      KEA_PACKAGES=(kea); KEA_SERVICE=kea-dhcp4-server; KEA_CONF=/etc/kea/kea-dhcp4.conf; KEA_BIN=kea-dhcp4
      ;;
    redhat)
      BASE_PACKAGES=(nftables iptables jq curl openssl ca-certificates chrony bind-utils)
      NTP_SERVICE=chronyd; NTP_CONF=/etc/chrony.conf
      CA_TRUST_DIR=/etc/pki/ca-trust/source/anchors; CA_TRUST_UPDATE=update-ca-trust
      BIND_PACKAGES=(bind bind-utils); BIND_SERVICE=named; BIND_USER=named; BIND_GROUP=named
      BIND_LAYOUT=single
      NAMED_CONF=/etc/named.conf
      NAMED_CACHE_DIR=/var/named
      ZONES_DIR=/var/named
      KEA_PACKAGES=(kea); KEA_SERVICE=kea-dhcp4; KEA_CONF=/etc/kea/kea-dhcp4.conf; KEA_BIN=kea-dhcp4
      ;;
    photon)
      BASE_PACKAGES=(nftables iptables jq curl openssl ca-certificates chrony bind-utils)
      NTP_SERVICE=chronyd; NTP_CONF=/etc/chrony.conf
      CA_TRUST_DIR=/etc/pki/ca-trust/source/anchors; CA_TRUST_UPDATE=update-ca-trust
      BIND_PACKAGES=(bind bind-utils); BIND_SERVICE=named; BIND_USER=named; BIND_GROUP=named
      BIND_LAYOUT=single
      NAMED_CONF=/etc/named.conf
      NAMED_CACHE_DIR=/var/named
      ZONES_DIR=/var/named
      KEA_PACKAGES=(kea); KEA_SERVICE=kea-dhcp4; KEA_CONF=/etc/kea/kea-dhcp4.conf; KEA_BIN=kea-dhcp4
      ;;
    *)
      die "Unsupported OS family (ID=${ID:-?}). Supported: Ubuntu/Debian, RHEL-like, Photon."
      ;;
  esac
}

# ---- package manager wrappers ----
pkg_refresh() {
  case "$OS_FAMILY" in
    debian) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null ;;
    *) : ;;
  esac
}
pkg_install() {
  [[ $# -gt 0 ]] || return 0
  case "$OS_FAMILY" in
    debian) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    redhat) dnf install -y "$@" 2>/dev/null || yum install -y "$@" ;;
    photon) tdnf install -y "$@" ;;
  esac
}

# ---- systemd wrappers ----
svc_enable_now()  { systemctl enable --now "$1"; }
svc_enable()      { systemctl enable "$1"; }
svc_restart()     { systemctl restart "$1"; }
svc_reload_units(){ systemctl daemon-reload; }
svc_stop_disable(){ systemctl disable --now "$1" 2>/dev/null || true; }
svc_is_active()   { systemctl is-active --quiet "$1"; }

# ---- Kea helpers (shared by the dhcp step and verify) ----
# The system user the Kea service runs as (Ubuntu/Debian: _kea). Empty if none.
kea_user() {
  if   id _kea >/dev/null 2>&1; then echo _kea
  elif id kea  >/dev/null 2>&1; then echo kea
  fi
}
# Run `kea-dhcp4 -t` AS the service user so AppArmor/DAC match runtime: running
# it as root trips the kea-dhcp4 AppArmor profile (dac_override DENIED).
kea_validate() {
  local u; u=$(kea_user)
  if [[ -n "$u" ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$u" -- "$KEA_BIN" -t "$KEA_CONF"
  else
    "$KEA_BIN" -t "$KEA_CONF"
  fi
}
