#!/usr/bin/env bash
# Shared helper for per-step unit tests. Stubs the YAML layer (cfg/cfg_len/
# cfg_bool) with flat shell vars so render functions can be tested with no yq
# and no host access. bash 3.2 compatible (macOS dev box).

TESTROOT="${BATS_TEST_DIRNAME}/../.."

load_libs() {
  # shellcheck disable=SC1090
  source "$TESTROOT/lib/common.sh"
  # shellcheck disable=SC1090
  source "$TESTROOT/lib/ipcalc.sh"
}

source_step() { # $1 = step filename, e.g. 50-dns.sh
  # shellcheck disable=SC1090
  source "$TESTROOT/stages/stage1-jumpbox/steps/$1"
}

# ---- cfg stub backed by flat variables ----
_k()  { printf 'STUB_%s'    "$(printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/_/g')"; }
_kl() { printf 'STUBLEN_%s' "$(printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/_/g')"; }
cfg()     { local n v; n=$(_k  "$1"); eval "v=\${$n-__U__}"; [ "$v" = "__U__" ] && printf '%s' "${2-}" || printf '%s' "$v"; }
cfg_len() { local n v; n=$(_kl "$1"); eval "v=\${$n-__U__}"; [ "$v" = "__U__" ] && printf '0'        || printf '%s' "$v"; }
cfg_bool(){ local v; v=$(cfg "$1" "${2:-false}"); case "$(printf '%s' "$v" | tr 'A-Z' 'a-z')" in true|yes|1) printf 'true';; *) printf 'false';; esac; }
sset()    { local n; n=$(_k  "$1"); eval "$n=\$2"; }   # set a scalar path
slen()    { local n; n=$(_kl "$1"); eval "$n=\$2"; }   # set a list length

# Standard 3-VLAN model (192.168.100/101/102 .0/24 inside a /22; native=100).
sample_model() {
  PRIVATE_NIC=ens224; PUBLIC_NIC=ens192; JB_HOST=jump01; DOMAIN=env1.lab.test
  MTU_PRIVATE=9000; NATIVE_VLAN=100; SUPERNET=192.168.100.0/22; N_VLANS=3
  V_ID=(100 101 102); V_NAME=(mgmt workload0 workload1)
  V_CIDR=(192.168.100.0/24 192.168.101.0/24 192.168.102.0/24)
  V_GW=(192.168.100.1 192.168.101.1 192.168.102.1)
  V_PREFIX=(24 24 24); V_ISNATIVE=(1 0 0)
  V_IFACE=(ens224 ens224.101 ens224.102)
  V_DSTART=(192.168.100.193 192.168.101.193 192.168.102.193)
  V_DEND=(192.168.100.254 192.168.101.254 192.168.102.254)
  V_REVZONE=(100.168.192.in-addr.arpa 101.168.192.in-addr.arpa 102.168.192.in-addr.arpa)
  V_DHCP=(true true true)
  V_EXTRA=("" "" "")   # secondary IPs per iface (e.g. the registry IP)
  NATIVE_GW=192.168.100.1
  OS_FAMILY=redhat; NAMED_CACHE_DIR=/var/named; ZONES_DIR=/var/named
  CERTS_DIR=/tmp/nlab; CA_MODE=selfsigned; CA_BUNDLE=/tmp/nlab/ca-bundle.crt
  REGISTRY_FQDN=registry.env1.lab.test; REGISTRY_ADDR=192.168.100.10
  REGISTRY_DATA=/data/registry; REGISTRY_AUTH=false; IMAGE_MIRROR=mirror.gcr.io/library; ARTIFACTS_DIR=/data/isos
  LAB_STATE_DIR=/tmp/nlab
}
