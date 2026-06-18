#!/usr/bin/env bats
# preflight :: pure network-model validation (_pf_model_errors)
load _helper

setup() { load_libs; source_step 00-preflight.sh; sample_model; }

@test "valid model -> no errors" {
  run _pf_model_errors
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "duplicate VLAN IDs detected" {
  V_ID=(100 101 101)
  run _pf_model_errors
  [[ "$output" == *"Duplicate VLAN IDs"* ]]
}

@test "native VLAN not defined detected" {
  NATIVE_VLAN=200
  run _pf_model_errors
  [[ "$output" == *"not among the defined VLANs"* ]]
}

@test "VLAN outside the /22 supernet detected" {
  V_CIDR=(192.168.100.0/24 192.168.101.0/24 192.168.104.0/24)
  run _pf_model_errors
  [[ "$output" == *"not inside supernet"* ]]
}

@test "non-/24 VLAN detected" {
  V_PREFIX=(24 24 25)
  run _pf_model_errors
  [[ "$output" == *"must be a /24"* ]]
}
