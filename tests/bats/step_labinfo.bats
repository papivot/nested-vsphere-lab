#!/usr/bin/env bats
# labinfo :: summary sheet render
load _helper

setup() { load_libs; source_step 90-labinfo.sh; sample_model; }

@test "summary lists VLANs, registry URL and CA bundle" {
  run _labinfo_render
  [[ "$output" == *"VLAN 100 (native)"* ]]
  [[ "$output" == *"192.168.100.193 - 192.168.100.254"* ]]
  [[ "$output" == *"https://registry.env1.lab.test/"* ]]
  [[ "$output" == *"registry:2"* ]]
  [[ "$output" == *"/tmp/nlab/ca-bundle.crt"* ]]
}

@test "disabled DHCP is shown as disabled" {
  V_DHCP=(true true false)
  run _labinfo_render
  [[ "$output" == *"DHCP   : disabled"* ]]
}
