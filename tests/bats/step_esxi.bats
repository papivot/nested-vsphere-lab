#!/usr/bin/env bats
# Pure render tests for stage2 esxi step. Run: bats tests/bats/step_esxi.bats
load _helper

setup() {
  command -v envsubst >/dev/null || skip "envsubst not installed"
  load_libs; sample_model2; source_step2 10-esxi.sh
}

@test "esxi import options render valid JSON with per-host guestinfo" {
  run _render_esxi_options
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
  echo "$output" | jq -e '.DiskProvisioning == "thin"'
  echo "$output" | jq -e '[.PropertyMapping[] | select(.Key=="guestinfo.hostname").Value][0]  == "esxi01"'
  echo "$output" | jq -e '[.PropertyMapping[] | select(.Key=="guestinfo.ipaddress").Value][0] == "192.168.100.51"'
  echo "$output" | jq -e '[.PropertyMapping[] | select(.Key=="guestinfo.netmask").Value][0]   == "255.255.255.0"'
  echo "$output" | jq -e '[.PropertyMapping[] | select(.Key=="guestinfo.gateway").Value][0]   == "192.168.100.1"'
}

@test "esxi options map the OVF network to the trunk portgroup, powered off" {
  run _render_esxi_options
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.NetworkMapping[0].Name    == "VM Network"'
  echo "$output" | jq -e '.NetworkMapping[0].Network == "VM Network"'
  echo "$output" | jq -e '.PowerOn == false'
}
