#!/usr/bin/env bash
# ============================================================================
# lib/ipcalc.sh - pure-bash IPv4 / CIDR math (replaces ansible.utils.ipaddr).
# No external tools. All math is integer; 32-bit values fit bash's 64-bit ints.
#
# Parity with the Ansible filters it replaces:
#   cidr_gateway  == cidr | ipaddr('1')               (the .1 each VLAN owns)
#   cidr_dhcp_*   == ipsubnet(26,3) then ipaddr('1')/ipaddr('-2')  (last /26)
#   reverse_zone  == c.b.a.in-addr.arpa for a /24
#   cidr_contains == /22 supernet containment check
# ============================================================================

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  printf '%s' "$(( (a<<24) + (b<<16) + (c<<8) + d ))"
}
int2ip() {
  local n=$1
  printf '%s.%s.%s.%s' "$(( (n>>24)&255 ))" "$(( (n>>16)&255 ))" "$(( (n>>8)&255 ))" "$(( n&255 ))"
}

cidr_addr()   { printf '%s' "${1%%/*}"; }
cidr_prefix() { local p="${1##*/}"; [[ "$p" == "$1" ]] && p=32; printf '%s' "$p"; }

# 32-bit netmask integer for a prefix length
_maskint() {
  local p=$1
  if (( p <= 0 )); then printf '%s' 0
  else printf '%s' "$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))"; fi
}

cidr_network() {
  local ip m
  ip=$(ip2int "$(cidr_addr "$1")"); m=$(_maskint "$(cidr_prefix "$1")")
  int2ip "$(( ip & m ))"
}
cidr_broadcast() {
  local ip m
  ip=$(ip2int "$(cidr_addr "$1")"); m=$(_maskint "$(cidr_prefix "$1")")
  int2ip "$(( (ip & m) | (0xFFFFFFFF ^ m) ))"
}
cidr_netmask() { int2ip "$(_maskint "$(cidr_prefix "$1")")"; }

# host N counted from the network address (gateway = host 1 = the .1)
cidr_host()    { local net; net=$(ip2int "$(cidr_network "$1")"); int2ip "$(( net + $2 ))"; }
cidr_gateway() { cidr_host "$1" 1; }

# Last /26 within the subnet, usable range (matches ipsubnet(26,3)+ipaddr 1/-2
# on a /24: .193 .. .254). Generic: network + size - 64, then +1 / +62.
_last26_net() {
  local net size p
  net=$(ip2int "$(cidr_network "$1")"); p=$(cidr_prefix "$1")
  size=$(( 1 << (32 - p) ))
  printf '%s' "$(( net + size - 64 ))"
}
cidr_dhcp_start() { int2ip "$(( $(_last26_net "$1") + 1 ))"; }
cidr_dhcp_end()   { int2ip "$(( $(_last26_net "$1") + 62 ))"; }

last_octet() { printf '%s' "${1##*.}"; }

# reverse zone name for a /24: a.b.c.0/24 -> c.b.a.in-addr.arpa
reverse_zone_24() {
  local IFS=. a b c d
  read -r a b c d <<<"$(cidr_addr "$1")"
  printf '%s.%s.%s.in-addr.arpa' "$c" "$b" "$a"
}

# cidr_contains OUTER INNER  - 0 if INNER is fully inside OUTER
cidr_contains() {
  local on ob in ib
  on=$(ip2int "$(cidr_network "$1")"); ob=$(ip2int "$(cidr_broadcast "$1")")
  in=$(ip2int "$(cidr_network "$2")"); ib=$(ip2int "$(cidr_broadcast "$2")")
  (( in >= on && ib <= ob ))
}

# ip_in_cidr IP CIDR  - 0 if IP falls within CIDR
ip_in_cidr() {
  local ip net bc
  ip=$(ip2int "$1"); net=$(ip2int "$(cidr_network "$2")"); bc=$(ip2int "$(cidr_broadcast "$2")")
  (( ip >= net && ip <= bc ))
}
