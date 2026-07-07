#!/usr/bin/env bats
# Pure render tests for stage2 cluster step (vim25 reconfigure specs).
# Run: bats tests/bats/step_cluster.bats
load _helper

setup() { load_libs; sample_model2; source_step2 30-cluster.sh; }

@test "vsan spec is a ClusterConfigSpecEx enabling vSAN" {
  run _render_vsan_spec
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '._typeName == "ClusterConfigSpecEx"'
  echo "$output" | jq -e '.vsanConfig.enabled == true'
}

@test "vsan ESA spec sets vsanEsaEnabled" {
  run _render_vsan_esa_spec
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.vsanConfig.enabled == true'
  echo "$output" | jq -e '.vsanConfig.vsanEsaEnabled == true'
}

@test "ha spec enables das with redundant-net warning suppressed" {
  run _render_ha_spec
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dasConfig.enabled == true'
  echo "$output" | jq -e '.dasConfig.option[0].key == "das.ignoreRedundantNetWarning"'
  echo "$output" | jq -e '.dasConfig.option[0].value._value == "true"'
}
