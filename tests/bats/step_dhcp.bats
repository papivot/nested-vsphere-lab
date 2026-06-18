#!/usr/bin/env bats
# dhcp :: Kea JSON generator (_dhcp_config)
load _helper

setup() {
  load_libs; source_step 60-dhcp.sh; sample_model
  sset '.dhcp.lease_time' 86400
  slen '.ntp.upstream' 2; sset '.ntp.upstream[0]' 10.0.0.10; sset '.ntp.upstream[1]' pool.ntp.org
  slen '.dhcp.reservations' 1
  sset '.dhcp.reservations[0].vlan' 100
  sset '.dhcp.reservations[0].mac'  00:50:56:aa:bb:cc
  sset '.dhcp.reservations[0].ip'   192.168.100.51
}

@test "produces valid JSON" {
  out=$(_dhcp_config)
  echo "$out" | jq -e . >/dev/null
}

@test "pool is the last /26 and option 26 = jumbo MTU" {
  out=$(_dhcp_config)
  [ "$(echo "$out" | jq -r '.Dhcp4.subnet4[0].pools[0].pool')" = "192.168.100.193 - 192.168.100.254" ]
  [ "$(echo "$out" | jq -r '.Dhcp4.subnet4[0]."option-data"[] | select(.name=="interface-mtu").data')" = "9000" ]
}

@test "dhcp=false VLAN (102) is excluded; only 2 subnets served" {
  V_DHCP=(true true false)
  out=$(_dhcp_config)
  [ "$(echo "$out" | jq -r '.Dhcp4.subnet4 | length')" = "2" ]
  [ "$(echo "$out" | jq -r '.Dhcp4."interfaces-config".interfaces | join(",")')" = "ens224,ens224.101" ]
}

@test "NTP option keeps IP upstreams, drops FQDNs" {
  out=$(_dhcp_config)
  [ "$(echo "$out" | jq -r '.Dhcp4.subnet4[0]."option-data"[] | select(.name=="ntp-servers").data')" = "10.0.0.10" ]
}

@test "reservation is attached to its VLAN only" {
  out=$(_dhcp_config)
  [ "$(echo "$out" | jq -r '.Dhcp4.subnet4[0].reservations[0]."hw-address"')" = "00:50:56:aa:bb:cc" ]
  [ "$(echo "$out" | jq -r '.Dhcp4.subnet4[1].reservations | length')" = "0" ]
}
