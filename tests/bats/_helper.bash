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

source_step2() { # $1 = stage-2 step filename, e.g. 30-cluster.sh
  # shellcheck disable=SC1090
  source "$TESTROOT/stages/stage2-nested-vsphere/steps/$1"
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

# ---- Stage 2 model fixture (exported so envsubst subprocesses see the vars) ----
sample_model2() {
  export STAGE2_DIR="$TESTROOT/stages/stage2-nested-vsphere"
  export DOMAIN=env1.lab.test NATIVE_GW=192.168.100.1 NTP_SERVER=192.168.100.1
  # nested ESXi
  export ESXI_NETMASK=255.255.255.0 ESXI_GW=192.168.100.1 ESXI_ROOT_PASSWORD=labpass
  export VSAN_MODE=osa ESXI_CACHE_GB=24 ESXI_CAP_GB=400
  ESXI_DATA_DISK_GB=(24 400)
  # underlying target (default standalone esxi; tests can flip to vcenter)
  export UNDERLYING_TYPE=esxi UNDERLYING_HOST=10.0.0.5 UNDERLYING_USER=root UNDERLYING_PASSWORD=labpass
  export UNDERLYING_PG="VM Network" UNDERLYING_DATASTORE=datastore1
  export UNDERLYING_DATACENTER=Datacenter UNDERLYING_CLUSTER=Cluster1
  # nested ESXi import options
  export ESXI_OVA_NETWORK="VM Network" ESXI_HOST_NAME=esxi01 ESXI_HOST_IP=192.168.100.51
  export VCSA_SIZE=tiny VCSA_DNS_NAME=vcsa VCSA_FQDN=vcsa.env1.lab.test
  export VCSA_IP=192.168.100.50 VCSA_PREFIX=24 VCSA_GW=192.168.100.1
  export VCSA_SSO_PASSWORD=labpass VCSA_SSO_DOMAIN=vsphere.local
  # Supervisor / Foundation LB template
  export SUPERVISOR_VM_COUNT=1 SUPERVISOR_SIZE=TINY SUPERVISOR_NAME=supervisor
  export VKS_STORAGE_POLICY=vsan-default
  export VKS_MGMT_NETWORK1=dvportgroup-11 VKS_WKLD_NETWORK=dvportgroup-22
  export MGMT_GATEWAY_CIDR=192.168.100.1/24 FLB_WORKLOAD_NW_GATEWAY_CIDR=192.168.101.1/24
  export DNS_SERVER=192.168.100.1 DNS_SEARCHDOMAIN=env1.lab.test
  export CP_MGMT_START=192.168.100.60 CP_MGMT_COUNT=5
  export FLB_MANAGEMENT_STARTING_IP=192.168.100.70 FLB_MANAGEMENT_IP_COUNT=3
  export FLB_NW_STARTING_IP=192.168.101.2 FLB_NW_IP_COUNT=10
  export FLB_WORKLOAD_NW_STARTING_IP=192.168.101.100 FLB_WORKLOAD_IP_COUNT=50
  export FLB_VIP_STARTING_IP=192.168.103.10 FLB_VIP_IP_COUNT=100
  export K8S_SERVICE_SUBNET=10.96.0.0 K8S_SERVICE_SUBNET_COUNT=512
}
