#!/usr/bin/env bats
# dns :: forward/reverse zones + named config renders
load _helper

setup() {
  load_libs; source_step 50-dns.sh; sample_model
  slen '.dns.forwarders' 2; sset '.dns.forwarders[0]' 8.8.8.8; sset '.dns.forwarders[1]' 1.1.1.1
  slen '.dns.records' 2
  sset '.dns.records[0].name' vcsa;   sset '.dns.records[0].ip' 192.168.100.50
  sset '.dns.records[1].name' esxi01; sset '.dns.records[1].ip' 192.168.101.51
}

@test "forward zone has SOA, gateway and pre-created A records" {
  run _dns_forward 2026061701
  [[ "$output" == *"SOA jump01.env1.lab.test."* ]]
  [[ "$output" == *"gw-mgmt"* ]]
  [[ "$output" == *"vcsa"*"192.168.100.50"* ]]
}

@test "reverse zone for vlan100 has the .50 PTR but not the vlan101 record" {
  run _dns_reverse 0 2026061701   # vlan 100
  [[ "$output" == *"50    IN  PTR  vcsa.env1.lab.test."* ]]
  [[ "$output" != *"esxi01"* ]]
}

@test "reverse zone for vlan101 has the esxi01 PTR" {
  run _dns_reverse 1 2026061701   # vlan 101
  [[ "$output" == *"51    IN  PTR  esxi01.env1.lab.test."* ]]
}

@test "named options restrict recursion to the private subnets + forward out" {
  run _dns_options
  [[ "$output" == *"forward only;"* ]]
  [[ "$output" == *"allow-recursion { 127.0.0.1; 192.168.100.0/24; 192.168.101.0/24; 192.168.102.0/24; }"* ]]
  [[ "$output" == *"8.8.8.8;"* ]]
}

@test "redhat layout includes pid-file; debian does not" {
  OS_FAMILY=redhat; run _dns_options; [[ "$output" == *"pid-file"* ]]
  OS_FAMILY=debian; run _dns_options; [[ "$output" != *"pid-file"* ]]
}

@test "zone declarations include forward + per-VLAN reverse zones" {
  run _dns_zones
  [[ "$output" == *'zone "env1.lab.test"'* ]]
  [[ "$output" == *'zone "101.168.192.in-addr.arpa"'* ]]
}

@test "resolved drop-in routes lab domain + reverse zones to BIND" {
  run _resolved_dropin
  [ "$status" -eq 0 ]
  [[ "$output" == *"DNS=192.168.100.1"* ]]
  [[ "$output" == *"Domains=env1.lab.test "* ]]
  [[ "$output" == *"~100.168.192.in-addr.arpa"* ]]
  [[ "$output" == *"~101.168.192.in-addr.arpa"* ]]
  [[ "$output" == *"~102.168.192.in-addr.arpa"* ]]
}
