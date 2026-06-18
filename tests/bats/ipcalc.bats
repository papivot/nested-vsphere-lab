#!/usr/bin/env bats
# Unit tests for the pure-bash CIDR math (the riskiest part of the port).
# Run: bats tests/bats/ipcalc.bats

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/ipcalc.sh"
}

@test "ip2int/int2ip round-trip" {
  run int2ip "$(ip2int 192.168.101.5)"
  [ "$output" = "192.168.101.5" ]
}

@test "cidr_network masks host bits" {
  run cidr_network 192.168.101.5/24
  [ "$output" = "192.168.101.0" ]
}

@test "cidr_broadcast is .255 for a /24" {
  run cidr_broadcast 192.168.101.0/24
  [ "$output" = "192.168.101.255" ]
}

@test "cidr_netmask /24" {
  run cidr_netmask 192.168.101.0/24
  [ "$output" = "255.255.255.0" ]
}

@test "cidr_netmask /22" {
  run cidr_netmask 192.168.100.0/22
  [ "$output" = "255.255.252.0" ]
}

@test "gateway is the .1" {
  run cidr_gateway 192.168.101.0/24
  [ "$output" = "192.168.101.1" ]
}

@test "dhcp pool start = .193 (last /26)" {
  run cidr_dhcp_start 192.168.101.0/24
  [ "$output" = "192.168.101.193" ]
}

@test "dhcp pool end = .254 (last /26)" {
  run cidr_dhcp_end 192.168.101.0/24
  [ "$output" = "192.168.101.254" ]
}

@test "reverse zone name for a /24" {
  run reverse_zone_24 192.168.101.0/24
  [ "$output" = "101.168.192.in-addr.arpa" ]
}

@test "last_octet" {
  run last_octet 192.168.101.254
  [ "$output" = "254" ]
}

@test "cidr_contains: /24 inside /22 (true)" {
  run cidr_contains 192.168.100.0/22 192.168.101.0/24
  [ "$status" -eq 0 ]
}

@test "cidr_contains: /24 outside /22 (false)" {
  run cidr_contains 192.168.100.0/22 192.168.104.0/24
  [ "$status" -ne 0 ]
}

@test "ip_in_cidr: inside" {
  run ip_in_cidr 192.168.101.50 192.168.101.0/24
  [ "$status" -eq 0 ]
}

@test "ip_in_cidr: outside" {
  run ip_in_cidr 192.168.102.50 192.168.101.0/24
  [ "$status" -ne 0 ]
}
