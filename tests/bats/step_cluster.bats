#!/usr/bin/env bats
# Pure render tests for stage2 cluster step (vim25 reconfigure specs).
# Run: bats tests/bats/step_cluster.bats
load _helper

setup() { load_libs; sample_model2; source_step2 30-cluster.sh; }

@test "ha spec enables das with redundant-net warning suppressed" {
  run _render_ha_spec
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dasConfig.enabled == true'
  echo "$output" | jq -e '.dasConfig.option[0].key == "das.ignoreRedundantNetWarning"'
  echo "$output" | jq -e '.dasConfig.option[0].value._value == "true"'
}

@test "base image spec carries the desired version verbatim" {
  run _render_base_image_spec 9.1.0.0.25370933
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == "9.1.0.0.25370933"'
}
